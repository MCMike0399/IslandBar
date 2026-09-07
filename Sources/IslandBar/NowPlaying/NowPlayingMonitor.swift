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
    var reopenVisibleUntil: Date?

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
    private var nilWork: DispatchWorkItem?
    private var playingWork: DispatchWorkItem?
    private var restartAttempt = 0
    private var lastPaletteKey: String?

    init(store: NowPlayingStore) {
        self.store = store
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
    }

    func start() {
        controller.startListening()
        DebugLog.line("NowPlayingMonitor listening")
    }

    func stop() {
        nilWork?.cancel()
        playingWork?.cancel()
        controller.stopListening()
    }

    func play() { controller.play() }
    func pause() { controller.pause() }
    func togglePlayPause() { controller.togglePlayPause() }
    func nextTrack() { controller.nextTrack() }
    func previousTrack() { controller.previousTrack() }

    private func handle(_ info: TrackInfo?) {
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
        let playing: Bool = {
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
                "session bundle=\(next.bundleID) pid=\(next.pid) title=\(next.title) artist=\(next.artist) isPlaying=\(playing)"
            )
        }
        if lastPaletteKey != key {
            lastPaletteKey = key
            store.palette = ArtworkPalette.make(from: next.artwork)
        }

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
