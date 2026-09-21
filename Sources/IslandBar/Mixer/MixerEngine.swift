import Accelerate
import CoreAudio
import Foundation

/// One app the mixer should be holding at a level other than full.
struct MixerTarget: Sendable, Equatable {
    var id: String
    /// Every audio process object belonging to the app, sorted. Unsorted lists make the
    /// change check below fail on nearly every poll and rebuild the world each time.
    var processes: [AudioObjectID]
    var gain: Float
}

/// Applies per-app gain by severing an app from the hardware and re-rendering it.
///
/// Core Audio exposes no per-process volume: all six `kAudioProcessProperty*` selectors are
/// read-only. So for each app being held below full volume the engine creates a private
/// process tap with `muteBehavior = .muted` — which removes that app's audio from the
/// hardware mix — and puts every such tap in one private aggregate device whose main
/// sub-device is the default output. A single IO proc then sums the tapped audio back into
/// the device's output buffer, each tap scaled by its own gain.
///
/// Consequences that shaped the design:
/// - A `.muted` tap does nothing until its aggregate is *started*, so muting costs exactly
///   what volume costs. Mute is therefore gain 0, not a second mechanism.
/// - The engine exists only while at least one app is held below full. An untouched install
///   creates no tap, starts no recording session, and lights no indicator.
/// - Re-rendering adds output latency (~16 ms on built-in speakers, much more on Bluetooth),
///   which is why an app at full volume is never tapped.
///
/// This is a second, independent aggregate device alongside the visualizer's. Both were
/// measured running together with no glitching, and the visualizer's `.unmuted` tap still
/// receives full-amplitude buffers for an app this engine has muted — so bars keep animating
/// for a muted app and `ProcessAudioTap` needs no change at all.
final class MixerEngine: @unchecked Sendable {
    /// Called on the main queue when the engine gives up and everything returns to normal.
    var onFailure: (@Sendable (String) -> Void)?
    /// Called on the main queue the first time a tap is refused by TCC.
    var onDenied: (@Sendable () -> Void)?

    private struct Slot {
        var id: String
        var tapID: AudioObjectID
        var tapUID: String
        var processes: [AudioObjectID]
        /// False once retired. The index is never reused, so a stale buffer index can never
        /// be read as a different app.
        var active: Bool
    }

    private let queue: DispatchQueue
    private let registry: AudioProcessRegistry
    private let table = MixerGainTable()

    /// Index in this array is the tap's index in the aggregate's tap list, which the spike
    /// confirmed is also its buffer index in the IO proc's input list.
    private var slots: [Slot] = []
    private var aggregateID = CoreAudioProps.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var outputUID: String?
    private var sampleRate: Double = 48_000
    private var epoch: UInt32 = 0

    private var watchdog: DispatchSourceTimer?
    private var idleTeardown: DispatchWorkItem?
    private var lastCallbacks: UInt32 = 0
    private var stalledTicks = 0
    private var startTicks = 0
    private var zeroEnergySince: [Int: Date] = [:]
    /// Last `rendered` count seen per slot. The counter is cumulative, so only the delta
    /// between ticks says whether a slot is still producing.
    private var lastRendered: [Int: UInt32] = [:]
    private var lastRebuildAt: Date?
    private var denialReported = false

    /// Long enough that mute → unmute → mute does not cost three recording sessions.
    private static let idleGrace: TimeInterval = 3
    private static let watchdogInterval: TimeInterval = 2

    var isRunning: Bool { aggregateID != CoreAudioProps.unknown }

    init(queue: DispatchQueue, registry: AudioProcessRegistry) {
        self.queue = queue
        self.registry = registry
    }

    // MARK: - Reconcile

    /// The only entry point. Everything below runs on the mixer queue.
    func apply(_ targets: [MixerTarget]) {
        let wanted = targets.filter { $0.gain < 0.999 }

        guard isRunning else {
            guard !wanted.isEmpty else { return }
            idleTeardown?.cancel()
            idleTeardown = nil
            build(wanted)
            // build() is synchronous here, so this is authoritative. Without it a failed
            // build leaves the card showing levels it no longer controls.
            if !isRunning {
                DispatchQueue.main.async { [onFailure] in onFailure?("build-failed") }
            }
            return
        }

        // Hot path first: with the same apps and the same process sets, a fader drag is a
        // handful of Float stores and touches Core Audio not at all.
        for target in wanted {
            guard let index = slots.firstIndex(where: { $0.id == target.id && $0.active }) else { continue }
            table.setTarget(slot: index, target.gain)
            if slots[index].processes != target.processes {
                widen(slot: index, to: target.processes)
            }
        }

        // Retire before appending: retiring never reshapes the buffer list, appending does,
        // and doing them in this order keeps each Set a ±1 change the IO proc can detect.
        //
        // This runs even when nothing is wanted any more. Leaving it to the idle teardown
        // instead would hold an app at its old level for the whole grace period, so dragging
        // a fader back to full would take three seconds to be heard.
        let wantedIDs = Set(wanted.map(\.id))
        for index in slots.indices where slots[index].active && !wantedIDs.contains(slots[index].id) {
            retire(slot: index)
        }

        for target in wanted where !slots.contains(where: { $0.id == target.id && $0.active }) {
            append(target)
        }

        // Keep the engine alive briefly after the last app returns to full, so
        // mute → unmute → mute does not cost three recording sessions.
        if slots.contains(where: \.active) {
            idleTeardown?.cancel()
            idleTeardown = nil
        } else {
            scheduleIdleTeardown()
        }
    }

    func stop() {
        teardown(reason: "terminate")
    }

    // MARK: - Engine lifecycle

    private func build(_ targets: [MixerTarget]) {
        guard let uid = registry.defaultOutputUID() else {
            DebugLog.line("mixer build skipped reason=no-output-uid")
            return
        }
        var built: [Slot] = []
        for target in targets.prefix(MixerGainTable.capacity) {
            guard let slot = makeTap(for: target) else {
                built.forEach { _ = AudioHardwareDestroyProcessTap($0.tapID) }
                return
            }
            built.append(slot)
        }
        guard !built.isEmpty else { return }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "IslandBar Mixer",
            // A fresh UID every build. Reusing one hands back a device coreaudiod still
            // holds from the previous incarnation, which looks healthy and delivers nothing.
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: built.map {
                [kAudioSubTapUIDKey: $0.tapUID, kAudioSubTapDriftCompensationKey: true]
            },
            // `kAudioAggregateDeviceTapAutoStartKey` is deliberately absent, unlike the
            // visualizer's aggregate. It makes `AudioDeviceStart` wait for the first tapped
            // process to produce audio, which would defer the device start and with it the
            // mute — a mute click would do nothing until the app next happened to play.
        ]

        var agg = AudioObjectID()
        let aggStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &agg)
        guard aggStatus == noErr else {
            DebugLog.line("mixer aggregate failed status=\(aggStatus)")
            built.forEach { _ = AudioHardwareDestroyProcessTap($0.tapID) }
            return
        }
        aggregateID = agg
        outputUID = uid
        slots = built

        sampleRate = built.first.flatMap { tapSampleRate($0.tapID) } ?? 48_000
        table.setSampleRate(sampleRate)
        table.resetCounters()
        epoch &+= 1
        for (index, slot) in built.enumerated() {
            let gain = targets.first { $0.id == slot.id }?.gain ?? 1
            table.stage(slot: index, target: gain, current: 0, epoch: epoch)
        }

        // Checked after the aggregate exists but before the device is started, because the
        // taps only begin muting once it starts. Failing here costs the user no audio.
        guard outputIsRenderable(aggregateID) else {
            DebugLog.line("mixer output layout unsupported aggregate=\(aggregateID)")
            teardown(reason: "output-layout")
            DispatchQueue.main.async { [onFailure] in onFailure?("output-layout") }
            return
        }

        guard installIOProc() else {
            teardown(reason: "io-proc-failed")
            return
        }
        table.publish(epoch: epoch)

        lastCallbacks = 0
        stalledTicks = 0
        startTicks = 0
        zeroEnergySince = [:]
        lastRendered = [:]
        startWatchdog()
        DebugLog.line(
            "mixer engine started aggregate=\(aggregateID) slots=\(slots.count) output=\(uid) rate=\(Int(sampleRate))"
        )
    }

    private func installIOProc() -> Bool {
        let slotsPointer = table.slotPointer
        let metaPointer = table.metaPointer
        let rampPointer = table.rampFramesPointer

        var procID: AudioDeviceIOProcID?
        // Realtime block. No allocation, no locks, no Swift collections, no logging, no ARC:
        // it captures raw pointers rather than `self` or the table. A mistake here is an
        // audible click in someone's music rather than a flat bar.
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInputData, _, outOutputData, _ in
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outABL.count > 0, let outData = outABL[0].mData else { return }
            // Stride comes from the device, not from an assumption. A multichannel output
            // (HDMI, an AVR, an interface) presents one interleaved buffer with more than
            // two channels, and writing it at stride 2 would smear the pair across it.
            let outChannels = Int(outABL[0].mNumberChannels)
            guard outChannels >= 2 else { return }
            let outBytes = Int(outABL[0].mDataByteSize)
            let outFrames = outBytes / (MemoryLayout<Float>.size * outChannels)
            guard outFrames > 0 else { return }
            let output = outData.assumingMemoryBound(to: Float.self)

            // The HAL hands over a zeroed buffer today, but every tap accumulates into it,
            // so anything left behind would play at full volume. Zeroing is nearly free.
            memset(outData, 0, outBytes)

            let published = metaPointer[0]
            let rampFrames = Float(max(rampPointer.pointee, 1))
            let inputABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            // Re-read the buffer count every cycle and never cache an index: appending to a
            // live aggregate's tap list reshapes this list underneath a running IO proc.
            let count = min(inputABL.count, MixerGainTable.capacity)

            var index = 0
            while index < count {
                let slot = slotsPointer + index
                // An epoch mismatch means this slot's buffer index is in doubt, so it
                // renders silence for a cycle rather than another app's audio.
                if slot.pointee.epoch == published {
                    let source = inputABL[index]
                    if let sourceData = source.mData, source.mDataByteSize > 0, source.mNumberChannels == 2 {
                        let frames = min(Int(source.mDataByteSize) / (MemoryLayout<Float>.size * 2), outFrames)
                        if frames > 0 {
                            let input = sourceData.assumingMemoryBound(to: Float.self)
                            let target = slot.pointee.target
                            var gain = slot.pointee.current
                            // Cap how far the gain may travel in one cycle so the ramp
                            // always takes ~8 ms however the buffers are sized.
                            let maxDelta = Float(frames) / rampFrames
                            var step = min(max(target - gain, -maxDelta), maxDelta) / Float(frames)
                            vDSP_vrampmuladd2(
                                input, input + 1, 2,
                                &gain, &step,
                                output, output + 1, vDSP_Stride(outChannels),
                                vDSP_Length(frames)
                            )
                            // vDSP leaves the advanced gain in `gain`, so the ramp carries
                            // across callbacks. Snap rather than comparing against target.
                            slot.pointee.current = abs(target - gain) < 0.0005 ? target : min(max(gain, 0), 1)
                            slot.pointee.rendered &+= 1
                        }
                    }
                }
                index &+= 1
            }

            // Each gain is clamped to 0...1, but the *sum* of several taps can exceed full
            // scale, and the HAL does not clamp for us.
            var peak: Float = 0
            vDSP_maxmgv(output, 1, &peak, vDSP_Length(outFrames * outChannels))
            if peak > 1 {
                metaPointer[2] &+= 1
                var low: Float = -1
                var high: Float = 1
                vDSP_vclip(output, 1, &low, &high, output, 1, vDSP_Length(outFrames * outChannels))
            }
            metaPointer[1] &+= 1
        }
        guard status == noErr, let procID else {
            DebugLog.line("mixer io proc failed status=\(status)")
            return false
        }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            DebugLog.line("mixer device start failed status=\(startStatus)")
            return false
        }
        return true
    }

    private func teardown(reason: String) {
        idleTeardown?.cancel()
        idleTeardown = nil
        watchdog?.cancel()
        watchdog = nil
        guard aggregateID != CoreAudioProps.unknown || !slots.isEmpty else { return }

        // Order matters: stop and destroy the IO proc, then the device, then the taps.
        // Reversed, a tap outlives the device that is reading it.
        if let ioProcID, aggregateID != CoreAudioProps.unknown {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != CoreAudioProps.unknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = CoreAudioProps.unknown
        for slot in slots {
            _ = AudioHardwareDestroyProcessTap(slot.tapID)
        }
        let clipped = table.clipped
        slots = []
        outputUID = nil
        zeroEnergySince = [:]
        lastRendered = [:]
        DebugLog.line("mixer engine stopped reason=\(reason) clipped=\(clipped)")
    }

    private func scheduleIdleTeardown() {
        guard isRunning, idleTeardown == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.idleTeardown != nil else { return }
            self.idleTeardown = nil
            self.teardown(reason: "idle")
        }
        idleTeardown = work
        queue.asyncAfter(deadline: .now() + Self.idleGrace, execute: work)
    }

    // MARK: - Membership

    private func makeTap(for target: MixerTarget) -> Slot? {
        let description = CATapDescription(stereoMixdownOfProcesses: target.processes)
        description.name = "IslandBar Mixer"
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID = AudioObjectID()
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            // Only a real TCC refusal is permanent; anything else is worth another poll.
            if status == kAudioHardwareIllegalOperationError {
                DebugLog.line("mixer denied stage=create-tap app=\(target.id)")
                if !denialReported {
                    denialReported = true
                    DispatchQueue.main.async { [onDenied] in onDenied?() }
                }
            } else {
                DebugLog.line("mixer tap failed app=\(target.id) status=\(status)")
            }
            return nil
        }
        DebugLog.line("mixer tap created app=\(target.id) targets=\(target.processes)")
        return Slot(
            id: target.id,
            tapID: tapID,
            tapUID: description.uuid.uuidString,
            processes: target.processes,
            active: true
        )
    }

    /// Appends one tap to the live aggregate. Exactly one Set, changing the tap count by
    /// exactly +1, so the IO proc can see the reshape in its buffer count.
    private func append(_ target: MixerTarget) {
        guard slots.count < MixerGainTable.capacity else {
            // Retired slots are only reclaimed by a teardown, so a rebuild helps only when
            // some are retired. With every slot live there is nothing to reclaim and a
            // rebuild would just tear the engine down every few seconds to no effect.
            guard slots.contains(where: { !$0.active }) else {
                DebugLog.line("mixer at capacity app=\(target.id) dropped slots=\(slots.count)")
                return
            }
            DebugLog.line("mixer slots exhausted app=\(target.id); rebuilding to reclaim")
            rebuild(reason: "slots-exhausted")
            return
        }
        guard let slot = makeTap(for: target) else { return }
        let index = slots.count

        // Stage before the Set. For a cycle or two the IO proc sees the new buffer layout
        // with the old published epoch, so every slot renders silence — which is a ~20 ms
        // gap, rather than app A's gain applied to app B's audio.
        epoch &+= 1
        table.stage(slot: index, target: target.gain, current: 0, epoch: epoch)
        for (existing, other) in slots.enumerated() where other.active {
            table.restamp(slot: existing, epoch: epoch)
        }

        let status = setTapList(slots.map(\.tapUID) + [slot.tapUID])
        guard status == noErr else {
            _ = AudioHardwareDestroyProcessTap(slot.tapID)
            // The Set failed, so the tap list — and the IO proc's buffer layout — is
            // unchanged and the existing indices are still valid. Publish the epoch they
            // were restamped into rather than leaving them in one that never goes live,
            // which would silence every held app. The staged index never joined the list,
            // so it is stamped out of every epoch first.
            table.retire(slot: index)
            table.publish(epoch: epoch)
            DebugLog.line("mixer taplist append failed app=\(target.id) status=\(status)")
            rebuild(reason: "taplist-set-failed")
            return
        }
        slots.append(slot)
        table.publish(epoch: epoch)
        DebugLog.line("mixer taplist appended app=\(target.id) slot=\(index) status=\(status)")
    }

    /// Returns an app to normal without reshaping the buffer list: the tap stays in the
    /// aggregate and is simply told to stop muting.
    ///
    /// The two writes are ordered and both are required. Dropping the gain first means the
    /// re-rendered copy is already silent when the original returns to the hardware; doing
    /// it the other way round leaves both audible for a moment, which comb-filters — that
    /// was measured at 56% of baseline with a suckout at the test tone.
    private func retire(slot index: Int) {
        guard index >= 0, index < slots.count, slots[index].active else { return }
        table.retire(slot: index)
        let status = setMuteBehavior(slots[index].tapID, muted: false)
        slots[index].active = false
        zeroEnergySince[index] = nil
        lastRendered[index] = nil
        DebugLog.line("mixer slot retired app=\(slots[index].id) slot=\(index) status=\(status)")
        guard status == noErr else {
            // The tap is still muting an app the user has returned to full, and its gain is
            // now zero, so nothing is re-rendering it either: it would be silent for good.
            // Only destroying the tap reliably releases it, so drop the whole engine and
            // tell the card, rather than leave one app inaudible with no way back.
            DebugLog.line("mixer unmute failed app=\(slots[index].id) slot=\(index) status=\(status)")
            teardown(reason: "retire-failed")
            DispatchQueue.main.async { [onFailure] in onFailure?("retire-failed") }
            return
        }
    }

    /// Widens a live tap's process set in place, for an app that spawned another helper.
    /// No new tap, and so no new recording session.
    private func widen(slot index: Int, to processes: [AudioObjectID]) {
        guard index >= 0, index < slots.count, !processes.isEmpty else { return }
        // A process object that has since died makes Core Audio reject the whole write, so
        // only ones still in the system's list are sent.
        let live = Set(
            CoreAudioProps.getArray(
                object: CoreAudioProps.systemObject,
                selector: kAudioHardwarePropertyProcessObjectList
            ) as [AudioObjectID]
        )
        let valid = processes.filter { live.contains($0) }.sorted()
        guard !valid.isEmpty else { return }
        guard let description = tapDescription(slots[index].tapID) else { return }
        description.processes = valid
        let status = setTapDescription(slots[index].tapID, description)
        if status == noErr {
            slots[index].processes = valid
            DebugLog.line("mixer slot widened app=\(slots[index].id) slot=\(index) targets=\(valid)")
        } else {
            DebugLog.line("mixer widen failed app=\(slots[index].id) slot=\(index) status=\(status)")
        }
    }

    private func rebuild(reason: String) {
        // Rate-limited because a rebuild is a fresh recording session and a brief gap for
        // every app currently being held down.
        if let last = lastRebuildAt, Date().timeIntervalSince(last) < 5 { return }
        lastRebuildAt = Date()
        // Read each gain by the slot's own index; a retired slot's target is already zero
        // and it is dropped here anyway.
        var targets: [MixerTarget] = []
        for (index, slot) in slots.enumerated() where slot.active {
            targets.append(MixerTarget(id: slot.id, processes: slot.processes, gain: table.target(slot: index)))
        }
        DebugLog.line("mixer rebuild reason=\(reason) slots=\(targets.count)")
        teardown(reason: "rebuild")
        guard !targets.isEmpty else { return }
        build(targets)
        // build() is synchronous on this queue, so isRunning is authoritative here. Without
        // this the engine can end up torn down with the card still showing faders that
        // control nothing, and nothing scheduled to try again.
        guard !isRunning else { return }
        DebugLog.line("mixer rebuild failed reason=\(reason)")
        DispatchQueue.main.async { [onFailure] in onFailure?("rebuild-failed") }
    }

    // MARK: - Watchdogs

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard isRunning else { return }
        let callbacks = table.callbacks

        // A tap can be created, an aggregate built and a device started, and still never
        // deliver a buffer. Without this the app would simply be silent with nothing to
        // explain it, which is exactly why `.muted` is acceptable at all.
        if callbacks == 0 {
            startTicks += 1
            if startTicks >= 1 {
                teardown(reason: "no-io")
                DispatchQueue.main.async { [onFailure] in onFailure?("no-io") }
            }
            return
        }
        startTicks = 0

        // A vanished output device stops the aggregate's IO, which looks exactly like a
        // stall. Check it first: otherwise unplugging headphones discards every level the
        // user set, where rebuilding onto the new device preserves them.
        if let current = registry.defaultOutputUID(), current != outputUID {
            rebuild(reason: "output-device-changed")
            return
        }

        if callbacks == lastCallbacks {
            stalledTicks += 1
            if stalledTicks >= 1 {
                teardown(reason: "stall")
                DispatchQueue.main.async { [onFailure] in onFailure?("stall") }
                return
            }
        } else {
            stalledTicks = 0
        }
        lastCallbacks = callbacks

        checkZeroEnergy()
    }

    /// Covers taps that start returning nothing but keep the IO proc running: the app is
    /// muted by the tap and re-rendered from an empty buffer, so it is simply silent.
    private func checkZeroEnergy() {
        let now = Date()
        for index in slots.indices where slots[index].active {
            let rendered = table.rendered(slot: index)
            let producing = rendered != (lastRendered[index] ?? 0)
            lastRendered[index] = rendered
            let stillPlaying = slots[index].processes.contains { !registry.outputDevices(for: $0).isEmpty }
            guard stillPlaying, !producing else {
                zeroEnergySince[index] = nil
                continue
            }
            let since = zeroEnergySince[index] ?? now
            zeroEnergySince[index] = since
            if now.timeIntervalSince(since) > 8 {
                rebuild(reason: "zero-energy")
                return
            }
        }
    }

    // MARK: - Core Audio property helpers

    /// Whether the IO proc can actually write this device: one interleaved buffer with at
    /// least two channels. A de-interleaved device presents several single-channel buffers
    /// instead, which the block does not handle — and because the taps mute the moment the
    /// device starts, discovering that inside the IO proc would mean silence, not fallback.
    private func outputIsRenderable(_ device: AudioObjectID) -> Bool {
        var addr = CoreAudioProps.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.count == 1 && abl[0].mNumberChannels >= 2
    }

    private func tapSampleRate(_ tapID: AudioObjectID) -> Double? {
        var addr = CoreAudioProps.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else {
            return nil
        }
        return asbd.mSampleRate
    }

    private func tapDescription(_ tapID: AudioObjectID) -> CATapDescription? {
        var addr = CoreAudioProps.address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
        var boxed: Unmanaged<CATapDescription>?
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &boxed) == noErr else { return nil }
        return boxed?.takeRetainedValue()
    }

    private func setTapDescription(_ tapID: AudioObjectID, _ description: CATapDescription) -> OSStatus {
        var addr = CoreAudioProps.address(kAudioTapPropertyDescription)
        var boxed: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        return AudioObjectSetPropertyData(
            tapID, &addr, 0, nil,
            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &boxed
        )
    }

    private func setMuteBehavior(_ tapID: AudioObjectID, muted: Bool) -> OSStatus {
        guard let description = tapDescription(tapID) else { return kAudioHardwareUnspecifiedError }
        description.muteBehavior = muted ? .muted : .unmuted
        return setTapDescription(tapID, description)
    }

    /// The live property takes a flat array of tap UIDs, unlike
    /// `kAudioAggregateDeviceTapListKey` in the creation dictionary, which takes a
    /// dictionary per sub-tap. Passing the dictionary form here silently does nothing.
    private func setTapList(_ uids: [String]) -> OSStatus {
        var addr = CoreAudioProps.address(kAudioAggregateDevicePropertyTapList)
        var value = uids as CFArray
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                aggregateID, &addr, 0, nil,
                UInt32(MemoryLayout<CFArray>.size), pointer
            )
        }
    }
}
