import AppKit
import CoreAudio
import Foundation

/// Lock-free SPSC ring of 4096 floats. Writer = Core Audio IO proc; reader = analysis queue.
final class FloatRingBuffer: @unchecked Sendable {
    private let mask = 4095
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var readIndex = 0

    init() {
        storage = .allocate(capacity: 4096)
        storage.initialize(repeating: 0, count: 4096)
    }

    deinit {
        storage.deinitialize(count: 4096)
        storage.deallocate()
    }

    func reset() {
        writeIndex = 0
        readIndex = 0
    }

    /// Realtime-safe: no allocation, no locks.
    func writeMixedMono(samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        var w = writeIndex
        let r = readIndex
        let ch = max(channels, 1)
        for i in 0..<frames {
            let next = (w + 1) & mask
            if next == r { break }
            let sample: Float
            if ch == 1 {
                sample = samples[i]
            } else {
                sample = 0.5 * (samples[i * ch] + samples[i * ch + 1])
            }
            storage[w] = sample
            w = next
        }
        writeIndex = w
    }

    func read(_ dest: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        var n = 0
        var r = readIndex
        let w = writeIndex
        while n < maxCount && r != w {
            dest[n] = storage[r]
            r = (r + 1) & mask
            n += 1
        }
        readIndex = r
        return n
    }
}

final class ProcessAudioTap: @unchecked Sendable {
    let ring = FloatRingBuffer()
    private var tapID: AudioObjectID = CoreAudioProps.unknown
    private var aggregateID: AudioObjectID = CoreAudioProps.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var ioCallbacks: Int = 0
    private(set) var isRunning = false
    private var asbd = AudioStreamBasicDescription()

    var sampleRate: Double { asbd.mSampleRate == 0 ? 48_000 : asbd.mSampleRate }
    var callbackCount: Int { ioCallbacks }

    /// Whether the aggregate device's IO engine reports itself running. A tap can be
    /// created successfully and still never deliver a buffer; this separates "the engine
    /// is stopped" from "the engine runs but the tap produces nothing".
    var isEngineRunning: Bool {
        guard aggregateID != CoreAudioProps.unknown else { return false }
        let running: UInt32? = CoreAudioProps.get(object: aggregateID, selector: kAudioDevicePropertyDeviceIsRunning)
        return running == 1
    }

    func start(targets: [AudioObjectID], outputUID: String) -> OSStatus {
        stop()
        guard !targets.isEmpty else { return kAudioHardwareIllegalOperationError }

        let description = CATapDescription(stereoMixdownOfProcesses: targets)
        description.name = "IslandBar"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID()
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { return tapStatus }
        tapID = tap

        var formatAddr = CoreAudioProps.address(kAudioTapPropertyFormat)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &formatSize, &asbd)

        // A fresh UID per tap. Reusing one UID across creations (an earlier version of
        // `renewTap` tried this) hands back a tap that coreaudiod still holds from the
        // previous incarnation: the IO proc runs and the format looks right, but no audio
        // is ever delivered into it.
        let tapUID = description.uuid.uuidString
        let aggUID = UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "IslandBar",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var agg = AudioObjectID()
        let aggStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &agg)
        guard aggStatus == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = CoreAudioProps.unknown
            return aggStatus
        }
        aggregateID = agg

        ring.reset()
        ioCallbacks = 0
        let ring = self.ring
        let callbackCell = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        callbackCell.initialize(to: 0)
        ioCallbackCell?.deinitialize(count: 1)
        ioCallbackCell?.deallocate()
        ioCallbackCell = callbackCell

        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for buf in abl {
                guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
                let channels = max(Int(buf.mNumberChannels), 1)
                let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frames > 0 else { continue }
                ring.writeMixedMono(
                    samples: data.assumingMemoryBound(to: Float.self),
                    frames: frames,
                    channels: channels
                )
            }
            callbackCell.pointee &+= 1
        }
        guard ioStatus == noErr, let procID else {
            stop()
            return ioStatus
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            stop()
            return startStatus
        }
        isRunning = true
        return noErr
    }

    private var ioCallbackCell: UnsafeMutablePointer<Int>?

    var ioCallbackCount: Int { ioCallbackCell?.pointee ?? 0 }

    func stop() {
        isRunning = false
        if let ioProcID, aggregateID != CoreAudioProps.unknown {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != CoreAudioProps.unknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = CoreAudioProps.unknown
        if tapID != CoreAudioProps.unknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = CoreAudioProps.unknown
        ioCallbackCell?.deinitialize(count: 1)
        ioCallbackCell?.deallocate()
        ioCallbackCell = nil
        ring.reset()
    }
}

struct NowPlayingSession: Sendable, Equatable {
    var bundleID: String
    var pid: pid_t
    var title: String
    var artist: String
    var appName: String
    var paletteKey: String
}

/// What the running tap is attached to. Replacing one of these with another means a
/// teardown + create, which macOS logs as a new recording session — so the controller
/// keeps whatever it has for the whole playing session and only narrows once.
enum TapSource: Equatable, Sendable {
    /// Nothing is being captured: no session, not playing, procedural, or tap unavailable.
    case none
    /// Tapping the processes matched to the Now Playing app.
    case matched
    /// Tapping every process that outputs audio except IslandBar itself.
    case globalOutput

    var isTapping: Bool { self != .none }
}

/// Owns target selection, tap lifetime, procedural fallback, and the bar pump.
final class TapController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.tap")
    private let registry: AudioProcessRegistry
    private let tap = ProcessAudioTap()
    private let analyzer: SpectrumAnalyzer
    private let procedural: ProceduralDriver
    private let shared: SharedBarState
    private let pump: BarLevelPump

    private var session: NowPlayingSession?
    private var isPlaying = false
    private var prefs = PreferencesSnapshot(showPillBackground: true, analysisSource: .automatic)
    private var phase: TapSource = .none
    private var ioWatchWork: DispatchWorkItem?
    private var selectWork: DispatchWorkItem?
    private var lastTargetIDs: [AudioObjectID] = []
    private var permissionDenied = false

    // MARK: Tap stability
    //
    // A process tap is not free to create: macOS opens a recording session on the default
    // output device for it, which happens on the default output device's route and is
    // reported to TCC. The first version of this controller rebuilt the tap whenever its
    // idea of "what to tap" changed — silence, a track change, any app starting or
    // stopping audio — and macOS answered with a recording-session event (and a TCC
    // query) about once every two minutes, plus a system warning that IslandBar was
    // "asking to record" too often. The rules below exist to make a tap last the whole
    // playing session instead.

    /// A rebuild before this much time has passed is refused, whatever the reason.
    private static let minTapResidency: CFAbsoluteTime = 15
    /// Backoff per rebuild within one playing session, capped.
    private static let rebuildBackoff: [CFAbsoluteTime] = [20, 45, 90, 180, 300]
    /// A tap on a dead or silent target is only replaced after it has been silent this long.
    private static let targetLossGrace: CFAbsoluteTime = 3
    /// How long after the tap starts a narrowing pass (global → matched) may happen.
    private static let narrowingWindow: CFAbsoluteTime = 20
    /// After a genuine permission error, wait this long before trying a tap again.
    private static let permissionRetry: CFAbsoluteTime = 300

    private var tapStartedAt: CFAbsoluteTime = 0
    private var rebuildsThisSession = 0
    private var nextRebuildAt: CFAbsoluteTime = 0
    private var targetLostSince: CFAbsoluteTime?
    private var lastSessionPID: pid_t?
    private var canNarrowUntil: CFAbsoluteTime = 0
    private var lastPermissionFailureAt: CFAbsoluteTime = 0
    private var denialReported = false

    var onPermissionDenied: (@Sendable () -> Void)?
    var onUsingProcedural: (@Sendable (Bool) -> Void)?
    var onTapEvent: (@Sendable (String) -> Void)?

    init(
        registry: AudioProcessRegistry,
        shared: SharedBarState,
        onLevels: @escaping @Sendable (BarLevels, Float, Bool) -> Void
    ) {
        self.registry = registry
        self.shared = shared
        self.analyzer = SpectrumAnalyzer(ring: tap.ring, shared: shared)
        self.procedural = ProceduralDriver(shared: shared)
        self.pump = BarLevelPump(shared: shared, onLevels: onLevels)

        registry.onProcessListChange = { [weak self] in
            guard let self else { return }
            self.queue.async { self.handleProcessListChange() }
        }
        registry.onDefaultOutputChange = { [weak self] in
            guard let self else { return }
            self.queue.async { self.rebuildIfNeeded(reason: "default-output") }
        }
    }

    func start() {
        registry.start()
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.rebuildIfNeeded(reason: "wake") }
        }
    }

    func stop() {
        queue.sync {
            cancelTimers()
            analyzer.stop()
            procedural.stop()
            tap.stop()
            pump.stop()
            phase = .none
        }
        registry.stop()
    }

    func apply(session: NowPlayingSession?, isPlaying: Bool, preferences: PreferencesSnapshot) {
        queue.async { [weak self] in
            self?.applyLocked(session: session, isPlaying: isPlaying, preferences: preferences)
        }
    }

    private func applyLocked(session: NowPlayingSession?, isPlaying: Bool, preferences: PreferencesSnapshot) {
        let sessionChanged = session != self.session
        let playChanged = isPlaying != self.isPlaying
        self.session = session
        self.isPlaying = isPlaying
        self.prefs = preferences

        if session == nil {
            cancelTimers()
            tearDownAudio(reason: "session-ended")
            pump.rest()
            shared.publish(bars: BarLevels.rest.values, rmsDb: -120, fromTap: false)
            return
        }

        // A pause is not a reason to throw the tap away: recreating it is what macOS
        // reports as a fresh recording session. Stop the work that consumes audio and
        // leave the tap itself alone until the session really ends.
        if !isPlaying {
            targetLostSince = nil
            analyzer.stop()
            procedural.stop()
            pump.rest()
            return
        }

        if !pump.isRunning { pump.start() }
        if playChanged || sessionChanged || !phase.isTapping {
            targetLostSince = nil
            renewTap(reason: playChanged ? "playing" : "session-change")
        }
    }

    private func handleProcessListChange() {
        guard isPlaying, session != nil else { return }
        // Only a tap that is not attached to what the session needs cares about the
        // process list; a healthy tap ignores it, because every rebuild is a recording
        // session as far as macOS is concerned. When no tap exists at all (`phase ==
        // .none`) the paths that decided that already scheduled their own retry, and a
        // pending retry means there is nothing to add.
        guard selectWork == nil, phase.isTapping else { return }
        guard phase != .matched || resolveTargets() != lastTargetIDs else { return }
        scheduleReselect(after: 0.5)
    }

    private func rebuildIfNeeded(reason: String) {
        guard isPlaying, session != nil else { return }
        renewTap(reason: reason)
    }

    /// Decides whether the running tap can stay, and starts one only when it cannot.
    /// This is the single place a process tap is created.
    private func renewTap(reason: String) {
        selectWork?.cancel()
        guard isPlaying, let session else { return }

        if DebugLog.forceProcedural || prefs.analysisSource == .proceduralOnly {
            enterProcedural(reason: "forced-procedural (\(reason))")
            return
        }
        if permissionDenied {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastPermissionFailureAt >= Self.permissionRetry else {
                enterProcedural(reason: "permission-denied (\(reason))")
                return
            }
            permissionDenied = false
            DebugLog.line("retrying the process tap after a permission failure")
        }

        let now = CFAbsoluteTimeGetCurrent()
        let matched = resolveTargets()
        let sessionPIDChanged = lastSessionPID != nil && lastSessionPID != session.pid

        var wantMatched = prefs.analysisSource == .automatic && !matched.isEmpty
        if case .globalOutput = phase, now > canNarrowUntil {
            // The one narrowing pass: the match was not known when the tap was created.
            wantMatched = wantMatched && now - tapStartedAt >= 3
        }

        if phase.isTapping, tap.isRunning {
            // Whatever this call decides about the tap, the analyzer has to be draining
            // it. A pause stops the analyzer and deliberately leaves the tap up, and
            // `installTap` is the only other thing that starts one — so every early
            // return below used to leave a live tap feeding nothing: `shared` kept the
            // last levels the analyzer published and the bars froze for the rest of the
            // session. It hid behind the crash on the pause path, because the relaunch
            // that followed built a fresh tap.
            if !analyzer.isRunning { attachAnalyzer() }
            let stale = !currentTargetsAreAlive()
            if stale {
                targetLostSince = targetLostSince ?? now
            } else {
                targetLostSince = nil
            }
            let current = lastTargetIDs
            let needRebuild = sessionPIDChanged
                ? current != matched
                : (stale && now - (targetLostSince ?? now) >= Self.targetLossGrace)
            if !needRebuild {
                // Nothing to do: keep this tap and just poll again later.
                scheduleReselect(after: Self.pollInterval(for: phase))
                return
            }
            guard now - tapStartedAt >= Self.minTapResidency, now >= nextRebuildAt else {
                scheduleReselect(after: 3)
                return
            }
        }

        let targets: [AudioObjectID]
        let source: TapSource
        if wantMatched {
            targets = matched
            source = .matched
        } else if prefs.analysisSource == .proceduralOnly {
            enterProcedural(reason: "procedural-only (\(reason))")
            return
        } else {
            let outputs = Self.outputTargets(registry.snapshot(), excluding: ProcessInfo.processInfo.processIdentifier)
            guard !outputs.isEmpty else {
                enterProcedural(reason: "no-targets (\(reason))")
                scheduleReselect(after: 5)
                return
            }
            targets = outputs
            source = .globalOutput
        }

        guard !targets.isEmpty else {
            enterProcedural(reason: "no-targets (\(reason))")
            scheduleReselect(after: 5)
            return
        }
        installTap(targets: targets, source: source, reason: reason)
    }

    /// Point the analyzer at the running tap and start draining it. Runs on the tap
    /// queue, which owns `analyzer.isRunning` along with `start()`/`stop()`.
    ///
    /// The ring is dropped first because its writer stalls when full rather than
    /// overwriting (`writeMixedMono` breaks when it catches the reader): a tap that kept
    /// running through a pause left ~85 ms of audio frozen at the moment of the pause,
    /// and replaying that on resume is a stutter, not history.
    private func attachAnalyzer() {
        analyzer.sampleRate = tap.sampleRate
        tap.ring.reset()
        analyzer.start()
    }

    private static func pollInterval(for source: TapSource) -> CFAbsoluteTime {
        source == .matched ? 10 : 5
    }

    /// Processes the session's app would use right now, sorted so the comparison against
    /// the running tap's target list is order-independent.
    private func resolveTargets() -> [AudioObjectID] {
        guard let session else { return [] }
        return Self.matchTargets(session: session, processes: registry.snapshot(), registry: registry)
    }

    /// Whether the processes the running tap is attached to are still producing audio.
    private func currentTargetsAreAlive() -> Bool {
        guard !lastTargetIDs.isEmpty else { return false }
        let live = Set(registry.snapshot().lazy.filter(\.isRunningOutput).map(\.objectID))
        return lastTargetIDs.contains { live.contains($0) }
    }

    private func installTap(targets: [AudioObjectID], source: TapSource, reason: String) {
        guard let uid = registry.defaultOutputUID() else {
            enterProcedural(reason: "no-output-uid")
            return
        }
        procedural.stop()
        analyzer.stop()
        let status = tap.start(targets: targets, outputUID: uid)
        if status != noErr {
            // Only a real TCC failure should stop us from capturing: everything else
            // (a device changeover mid-flight, coreaudiod restarting) is worth retrying,
            // and latching those permanently left the app in procedural mode for good.
            let denied = status == kAudioHardwareIllegalOperationError
            permissionDenied = denied
            if denied {
                lastPermissionFailureAt = CFAbsoluteTimeGetCurrent()
                if !denialReported {
                    denialReported = true
                    onPermissionDenied?()
                }
            }
            DebugLog.line("tap start failed status=\(status) permissionDenied=\(denied)")
            enterProcedural(reason: "tap-error \(status)")
            if !denied { scheduleReselect(after: 5) }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        phase = source
        lastTargetIDs = targets
        tapStartedAt = now
        lastSessionPID = session?.pid
        targetLostSince = nil
        canNarrowUntil = now + Self.narrowingWindow
        nextRebuildAt = now + Self.backoffAfterRebuild(rebuildsThisSession)
        rebuildsThisSession += 1

        attachAnalyzer()
        onUsingProcedural?(false)
        onTapEvent?("tap source=\(source) targets=\(targets) reason=\(reason) pid=\(session?.pid ?? 0)")
        DebugLog.line(
            "tap created source=\(source) targets=\(targets) reason=\(reason) rebuild=\(rebuildsThisSession)"
        )

        ioWatchWork?.cancel()
        let startCount = tap.ioCallbackCount
        let startSampleRate = tap.sampleRate
        let watch = DispatchWorkItem { [weak self] in
            guard let self, self.tap.isRunning else { return }
            let callbacks = self.tap.ioCallbackCount - startCount
            if callbacks == 0 {
                DebugLog.line("IO callback missing within 2s; falling back to procedural")
                self.enterProcedural(reason: "io-timeout")
            } else {
                DebugLog.line(
                    "tap IO alive: \(callbacks) callbacks in 2s sampleRate=\(startSampleRate) "
                        + "engineRunning=\(self.tap.isEngineRunning) samplesRead=\(self.analyzer.samplesRead)"
                )
            }
        }
        ioWatchWork = watch
        queue.asyncAfter(deadline: .now() + 2, execute: watch)
        scheduleReselect(after: Self.pollInterval(for: source))
    }

    /// Backoff before the *next* rebuild in this session. The first rebuild is cheap
    /// because a track change legitimately needs new targets; later ones back off so a
    /// restive target list cannot spin the aggregate device up and down.
    private static func backoffAfterRebuild(_ rebuilds: Int) -> CFAbsoluteTime {
        guard rebuilds > 0 else { return 0 }
        return rebuildBackoff[min(rebuilds - 1, rebuildBackoff.count - 1)]
    }

    private func enterProcedural(reason: String) {
        analyzer.stop()
        tap.stop()
        lastTargetIDs = []
        phase = .none
        procedural.start()
        if !pump.isRunning { pump.start() }
        onUsingProcedural?(true)
        DebugLog.line("procedural driver active reason=\(reason)")
        onTapEvent?("procedural reason=\(reason)")

        // Procedural is not necessarily final: a denied grant can be turned back on, and
        // a failed device handover can settle. Retry slowly rather than waiting for a
        // relaunch (a latched denial still waits out `permissionRetry` inside `renewTap`).
        if isPlaying,
           prefs.analysisSource == .automatic,
           !DebugLog.forceProcedural {
            scheduleReselect(after: 60)
        }
    }

    private func tearDownAudio(reason: String) {
        ioWatchWork?.cancel()
        selectWork?.cancel()
        let hadTap = phase.isTapping || tap.isRunning
        analyzer.stop()
        procedural.stop()
        if hadTap {
            DebugLog.line("tap torn down reason=\(reason) rebuilds=\(rebuildsThisSession)")
            onTapEvent?("tap torn down reason=\(reason)")
        }
        tap.stop()
        lastTargetIDs = []
        phase = .none
        rebuildsThisSession = 0
        nextRebuildAt = 0
        tapStartedAt = 0
        lastSessionPID = nil
        targetLostSince = nil
        onUsingProcedural?(false)
    }

    private func scheduleReselect(after seconds: Double) {
        selectWork?.cancel()
        guard isPlaying, session != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.renewTap(reason: "poll")
        }
        selectWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimers() {
        ioWatchWork?.cancel()
        selectWork?.cancel()
        ioWatchWork = nil
        selectWork = nil
    }

    /// Target lists are always sorted so that comparing them against the running tap's
    /// targets is order-independent. An unordered list made that check fail on almost
    /// every poll, and every rebuild of the aggregate device made coreaudiod reconfigure
    /// the output and glitch all audio.
    private static func matchTargets(
        session: NowPlayingSession,
        processes: [AudioProcessInfo],
        registry: AudioProcessRegistry
    ) -> [AudioObjectID] {
        var ids = Set<AudioObjectID>()
        if let direct = registry.objectID(forPID: session.pid) {
            ids.insert(direct)
        }
        for proc in processes where AudioProcessRegistry.matches(session: session, process: proc) {
            ids.insert(proc.objectID)
        }
        return ids.sorted()
    }

    private static func outputTargets(_ processes: [AudioProcessInfo], excluding selfPID: pid_t) -> [AudioObjectID] {
        processes
            .filter { $0.isRunningOutput && $0.pid != selfPID }
            .map(\.objectID)
            .sorted()
    }
}
