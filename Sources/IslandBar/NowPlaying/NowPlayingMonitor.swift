import AppKit
import Foundation
import MediaRemoteAdapter
import Observation

@MainActor
protocol MediaTransport: AnyObject {
    func play()
    func pause()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
}

struct Session {
    var bundleID: String
    var pid: pid_t
    var title: String
    var artist: String
    var appName: String
    var artwork: NSImage?
    var paletteKey: String

    var tapSession: NowPlayingSession {
        NowPlayingSession(
            bundleID: bundleID,
            pid: pid,
            title: title,
            artist: artist,
            appName: appName,
            paletteKey: paletteKey
        )
    }
}

@MainActor
@Observable
final class NowPlayingStore {
    var session: Session?
    var isPlaying = false
    var barLevels = BarLevels.rest
    var palette = ArtworkPalette.fallback
    var audioPermissionDenied = false
    var usingProcedural = false

    @ObservationIgnored
    var transport: MediaTransport?

    func play() {
        isPlaying = true
        transport?.play()
    }

    func pause() {
        isPlaying = false
        transport?.pause()
    }

    func togglePlayPause() {
        isPlaying.toggle()
        DebugLog.line("optimistic isPlaying=\(isPlaying)")
        transport?.togglePlayPause()
    }

    func nextTrack() {
        transport?.nextTrack()
    }

    func previousTrack() {
        transport?.previousTrack()
    }
}

@MainActor
final class NowPlayingMonitor: MediaTransport {
    private let controller = MediaController()
    private let store: NowPlayingStore
    private let registry: AudioProcessRegistry
    private var nilWork: DispatchWorkItem?
    private var playingWork: DispatchWorkItem?
    private var restartAttempt = 0
    private var lastPaletteKey: String?

    /// Playback state as MediaRemote last reported it, before any Core Audio override.
    private var reportedPlaying = false
    /// True while `isPlaying` is held up by the app's audio output rather than MediaRemote.
    private var outputOverride = false
    private var outputQuietSince: Date?
    private var outputPoll: DispatchSourceTimer?

    private var healthTimer: DispatchSourceTimer?
    private var lastEventAt = Date()
    private var lastProbeAt = Date.distantPast
    private var probeInFlight = false

    /// Chromium keeps its output stream open briefly after a pause; wait this long
    /// before dropping an overridden "playing" state.
    private static let outputQuietGrace: TimeInterval = 3
    private static let healthInterval: TimeInterval = 10
    private static let probeInterval: TimeInterval = 30

    init(store: NowPlayingStore, registry: AudioProcessRegistry) {
        self.store = store
        self.registry = registry
        store.transport = self
        controller.onTrackInfoReceived = { [weak self] info in
            Task { @MainActor in
                self?.handle(info)
            }
        }
        controller.onListenerTerminated = { [weak self] in
            Task { @MainActor in
                self?.scheduleRestart()
            }
        }
        controller.onDecodingError = { error, data in
            DebugLog.line("track info decode failed: \(error) bytes=\(data.count)")
        }
    }

    func start() {
        controller.startListening()
        DebugLog.line("NowPlayingMonitor listening")
        startHealthCheck()
    }

    func stop() {
        nilWork?.cancel()
        playingWork?.cancel()
        healthTimer?.cancel()
        healthTimer = nil
        stopOutputPoll()
        controller.stopListening()
    }

    func play() { controller.play() }
    func pause() { controller.pause() }
    func togglePlayPause() { controller.togglePlayPause() }
    func nextTrack() { controller.nextTrack() }
    func previousTrack() { controller.previousTrack() }

    private func handle(_ info: TrackInfo?) {
        lastEventAt = Date()
        restartAttempt = 0

        guard let info else {
            playingWork?.cancel()
            nilWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.store.session != nil {
                    DebugLog.line("session=nil applied after 2s debounce")
                }
                self.store.session = nil
                self.store.isPlaying = false
                self.store.palette = .fallback
                self.lastPaletteKey = nil
                self.reportedPlaying = false
                self.outputOverride = false
                self.stopOutputPoll()
            }
            nilWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            DebugLog.line("session nil event (debouncing 2s)")
            return
        }

        nilWork?.cancel()
        nilWork = nil

        let payload = info.payload
        let key = "\(payload.title ?? "")\u{1e}\(payload.artist ?? "")\u{1e}\(payload.album ?? "")"
        let reported: Bool = {
            if let flag = payload.isPlaying { return flag }
            return (payload.playbackRate ?? 0) > 0
        }()
        let next = Session(
            bundleID: payload.bundleIdentifier ?? "",
            pid: payload.PID ?? 0,
            title: payload.title ?? "",
            artist: payload.artist ?? "",
            appName: payload.applicationName ?? payload.bundleIdentifier ?? "Unknown",
            artwork: payload.artwork,
            paletteKey: key
        )

        let sessionChanged = store.session?.paletteKey != next.paletteKey
            || store.session?.bundleID != next.bundleID
            || store.session?.pid != next.pid
        store.session = next
        if sessionChanged {
            DebugLog.line(
                "session bundle=\(next.bundleID) pid=\(next.pid) title=\(next.title) artist=\(next.artist) isPlaying=\(reported)"
            )
        }
        if lastPaletteKey != key {
            lastPaletteKey = key
            store.palette = ArtworkPalette.make(from: next.artwork)
        }

        reportedPlaying = reported
        let playing = effectivePlaying(for: next.tapSession, reported: reported)
        applyPlaying(playing)
    }

    /// MediaRemote's flag, unless it says paused while the app is still producing audio
    /// (Arc's mini player reports a paused tab while another one plays).
    private func effectivePlaying(for session: NowPlayingSession, reported: Bool) -> Bool {
        if reported {
            outputOverride = false
            stopOutputPoll()
            return true
        }
        if registry.isOutputActive(for: session) {
            if !outputOverride {
                DebugLog.line("isPlaying override: MediaRemote paused but \(session.bundleID) is running output")
            }
            outputOverride = true
            outputQuietSince = nil
            startOutputPoll()
            return true
        }
        outputOverride = false
        stopOutputPoll()
        return false
    }

    private func applyPlaying(_ playing: Bool) {
        if playing != store.isPlaying {
            playingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.store.isPlaying = playing
                DebugLog.line("isPlaying=\(playing) applied after 250ms")
            }
            playingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            playingWork?.cancel()
            playingWork = nil
        }
    }

    // MARK: Core Audio output poll (only while overriding MediaRemote)

    private func startOutputPoll() {
        guard outputPoll == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.pollOutput()
        }
        timer.resume()
        outputPoll = timer
    }

    private func stopOutputPoll() {
        outputPoll?.cancel()
        outputPoll = nil
        outputQuietSince = nil
    }

    private func pollOutput() {
        guard outputOverride, !reportedPlaying, let session = store.session?.tapSession else {
            stopOutputPoll()
            return
        }
        if registry.isOutputActive(for: session) {
            outputQuietSince = nil
            return
        }
        let since = outputQuietSince ?? Date()
        outputQuietSince = since
        if Date().timeIntervalSince(since) >= Self.outputQuietGrace {
            DebugLog.line("isPlaying override ended: \(session.bundleID) stopped output")
            outputOverride = false
            stopOutputPoll()
            applyPlaying(false)
        }
    }

    // MARK: Listener health

    private func startHealthCheck() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.healthInterval, repeating: Self.healthInterval)
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealth() {
        if !controller.isListening {
            DebugLog.line("listener not running; restarting")
            controller.startListening()
            return
        }
        // While idle, re-read MediaRemote directly now and then in case a notification
        // was missed; a positive answer resyncs the store, a negative one is ignored.
        guard store.session == nil, !probeInFlight,
              Date().timeIntervalSince(lastEventAt) >= Self.probeInterval,
              Date().timeIntervalSince(lastProbeAt) >= Self.probeInterval
        else { return }
        lastProbeAt = Date()
        probeInFlight = true
        controller.getTrackInfo { [weak self] info in
            Task { @MainActor in
                guard let self else { return }
                self.probeInFlight = false
                guard let info else { return }
                DebugLog.line("probe found a session the listener missed; resyncing")
                self.handle(info)
            }
        }
    }

    private func scheduleRestart() {
        let delays = [1.0, 2.0, 5.0]
        let delay = restartAttempt < delays.count ? delays[restartAttempt] : 30.0
        restartAttempt += 1
        DebugLog.line("listener terminated; restart in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.controller.startListening()
        }
    }
}
