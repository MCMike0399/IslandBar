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
                guard let data = buf.mData else { continue }
                let channels = max(Int(buf.mNumberChannels), 1)
                let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * channels)
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

enum TapPhase: String, Sendable {
    case matched
    case allOutput
    case procedural
    case idle
}

/// Owns target selection, tap lifetime, procedural fallback, and the 30 Hz bar pump.
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
    private var phase: TapPhase = .idle
    private var stopWork: DispatchWorkItem?
    private var ioWatchWork: DispatchWorkItem?
    private var selectWork: DispatchWorkItem?
    private var silenceSince: CFAbsoluteTime?
    private var allOutputSince: CFAbsoluteTime?
    private var lastTargetIDs: [AudioObjectID] = []
    private var permissionDenied = false

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
            phase = .idle
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
            pump.stop()
            shared.publish(bars: BarLevels.rest.values, rmsDb: -120, fromTap: false)
            return
        }

        if !isPlaying {
            stopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.tearDownAudio(reason: "paused")
            }
            stopWork = work
            queue.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }

        stopWork?.cancel()
        stopWork = nil
        pump.start()
        if playChanged || sessionChanged || phase == .idle {
            silenceSince = nil
            allOutputSince = nil
            phase = .idle
            selectAndStart(reason: sessionChanged ? "session-change" : "playing")
        }
    }

    private func handleProcessListChange() {
        guard isPlaying, session != nil else { return }
        if phase != .matched {
            selectAndStart(reason: "process-list")
        }
    }

    private func rebuildIfNeeded(reason: String) {
        guard isPlaying, session != nil else { return }
        selectAndStart(reason: reason)
    }

    private func selectAndStart(reason: String) {
        selectWork?.cancel()
        guard isPlaying, let session else { return }

        if DebugLog.forceProcedural || prefs.analysisSource == .proceduralOnly || permissionDenied {
            enterProcedural(reason: "forced-or-denied (\(reason))")
            return
        }

        let processes = registry.snapshot()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let matched = Self.matchTargets(session: session, processes: processes, registry: registry)

        let now = CFAbsoluteTimeGetCurrent()
        let rms = shared.snapshot().rmsDb
        let silent = rms < -60

        var nextPhase = phase
        var targets: [AudioObjectID] = []

        switch prefs.analysisSource {
        case .proceduralOnly:
            enterProcedural(reason: reason)
            return
        case .allSystemOutput:
            targets = processes.filter { $0.isRunningOutput && $0.pid != selfPID }.map(\.objectID)
            nextPhase = .allOutput
        case .automatic:
            if phase == .procedural {
                // Keep polling (1)→(2) every 5s while procedural.
                if !matched.isEmpty {
                    targets = matched
                    nextPhase = .matched
                    silenceSince = silent ? (silenceSince ?? now) : nil
                } else {
                    targets = processes.filter { $0.isRunningOutput && $0.pid != selfPID }.map(\.objectID)
                    nextPhase = .allOutput
                }
            } else if matched.isEmpty {
                targets = processes.filter { $0.isRunningOutput && $0.pid != selfPID }.map(\.objectID)
                nextPhase = .allOutput
                allOutputSince = allOutputSince ?? now
            } else if phase == .allOutput {
                if let since = allOutputSince, now - since >= 3, silent {
                    enterProcedural(reason: "silent-after-all-output")
                    scheduleReselect(after: 5)
                    return
                }
                targets = processes.filter { $0.isRunningOutput && $0.pid != selfPID }.map(\.objectID)
                nextPhase = .allOutput
            } else {
                if silent {
                    silenceSince = silenceSince ?? now
                } else {
                    silenceSince = nil
                }
                if let since = silenceSince, now - since >= 1.5 {
                    targets = processes.filter { $0.isRunningOutput && $0.pid != selfPID }.map(\.objectID)
                    nextPhase = .allOutput
                    allOutputSince = now
                } else {
                    targets = matched
                    nextPhase = .matched
                }
            }
        }

        if targets.isEmpty {
            enterProcedural(reason: "no-targets (\(reason))")
            scheduleReselect(after: phase == .procedural ? 5 : 1.5)
            return
        }

        if nextPhase == phase, targets == lastTargetIDs, tap.isRunning {
            scheduleReselect(after: 1.5)
            return
        }

        startTap(targets: targets, phase: nextPhase, reason: reason)
    }

    private func startTap(targets: [AudioObjectID], phase: TapPhase, reason: String) {
        guard let uid = registry.defaultOutputUID() else {
            enterProcedural(reason: "no-output-uid")
            return
        }
        procedural.stop()
        analyzer.stop()
        let status = tap.start(targets: targets, outputUID: uid)
        if status != noErr {
            permissionDenied = true
            onPermissionDenied?()
            DebugLog.line("audioPermissionDenied=true status=\(status)")
            enterProcedural(reason: "tap-error \(status)")
            return
        }
        self.phase = phase
        lastTargetIDs = targets
        analyzer.sampleRate = tap.sampleRate
        analyzer.start()
        onUsingProcedural?(false)
        onTapEvent?("tap created phase=\(phase.rawValue) targets=\(targets) reason=\(reason) pid=\(session?.pid ?? 0)")
        DebugLog.line("tap created phase=\(phase.rawValue) targets=\(targets) reason=\(reason)")

        ioWatchWork?.cancel()
        let startCount = tap.ioCallbackCount
        let watch = DispatchWorkItem { [weak self] in
            guard let self, self.tap.isRunning else { return }
            if self.tap.ioCallbackCount == startCount {
                DebugLog.line("IO callback missing within 2s; falling back to procedural")
                self.enterProcedural(reason: "io-timeout")
            }
        }
        ioWatchWork = watch
        queue.asyncAfter(deadline: .now() + 2, execute: watch)
        scheduleReselect(after: 1.5)
    }

    private func enterProcedural(reason: String) {
        analyzer.stop()
        tap.stop()
        lastTargetIDs = []
        phase = .procedural
        procedural.start()
        pump.start()
        onUsingProcedural?(true)
        DebugLog.line("procedural driver active reason=\(reason)")
        onTapEvent?("procedural reason=\(reason)")
        if isPlaying, prefs.analysisSource == .automatic, !permissionDenied, !DebugLog.forceProcedural {
            scheduleReselect(after: 5)
        }
    }

    private func tearDownAudio(reason: String) {
        ioWatchWork?.cancel()
        selectWork?.cancel()
        analyzer.stop()
        procedural.stop()
        if tap.isRunning {
            tap.stop()
            DebugLog.line("tap torn down reason=\(reason)")
            onTapEvent?("tap torn down reason=\(reason)")
        }
        lastTargetIDs = []
        phase = .idle
        onUsingProcedural?(false)
    }

    private func scheduleReselect(after seconds: Double) {
        selectWork?.cancel()
        guard isPlaying, session != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.selectAndStart(reason: "poll")
        }
        selectWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimers() {
        stopWork?.cancel()
        ioWatchWork?.cancel()
        selectWork?.cancel()
        stopWork = nil
        ioWatchWork = nil
        selectWork = nil
    }

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
        return Array(ids)
    }
}
