import AppKit
import CoreAudio
import Foundation
import Observation

/// One device the Mac can send audio to, as the card lists it.
struct OutputDevice: Identifiable, Equatable, Sendable {
    var id: AudioObjectID
    var name: String
    /// SF Symbol picked from the device's transport type, so the list reads as
    /// "AirPods / MacBook speakers / the monitor" rather than three identical rows.
    var symbol: String
}

/// The system half of the card: the default output device, its volume, its mute, and the
/// list of devices you can switch to.
///
/// This is deliberately separate from `AudioMixer`. The mixer is IslandBar's own invention
/// — per-app levels macOS does not have — and it costs a process tap and a TCC grant to
/// run. Everything here is ordinary, unprivileged CoreAudio on the device the system is
/// already using, so the card has something useful to show even when nothing is playing
/// and even when the tap has been refused.
@MainActor
@Observable
final class SystemAudioController {
    private(set) var devices: [OutputDevice] = []
    private(set) var device: OutputDevice?
    /// 0...1, exactly the scalar the system slider uses. No perceptual curve is applied:
    /// this fader has to land in the same place as the one in the menu bar.
    private(set) var volume: Float = 0
    private(set) var isMuted = false
    /// False for outputs that expose no volume control at all (many HDMI and some USB
    /// DACs). The slider then shows the level and refuses the drag rather than pretending.
    private(set) var canSetVolume = false

    /// Drives the Sound card's inline device list. It lives here rather than in SwiftUI
    /// because the popover's height is computed outside the view tree, and the list
    /// changes that height.
    /// Deliberately a plain stored property with no `didSet`: a property observer on an
    /// `@Observable` stored property is the kind of construct whose instrumentation is easy
    /// to get subtly wrong, and this one is read from a SwiftUI body that must re-run the
    /// instant it flips. `toggleOutputPicker()` does the side effect instead.
    var isPickingOutput = false

    @ObservationIgnored private var deviceID = CoreAudioProps.unknown
    @ObservationIgnored private var control: VolumeControl = .unavailable
    @ObservationIgnored private var canMute = false
    @ObservationIgnored private var listeners: [Listener] = []
    /// Ignore the device's own change notifications briefly after we write, so a drag is
    /// never fought by the value coming back rounded.
    @ObservationIgnored private var lastLocalWrite = Date.distantPast
    /// Where the fader was before a soft mute, for outputs with no hardware mute.
    @ObservationIgnored private var preMuteVolume: Float = 0.5
    @ObservationIgnored private var started = false

    private static let localWriteGrace: TimeInterval = 0.25
    /// IslandBar's own private aggregate devices are named from this. They are real output
    /// devices as far as this process is concerned, and offering one as an output would
    /// route the Mac's audio into IslandBar.
    private static let ownDeviceNamePrefix = "IslandBar"

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        addListener(object: CoreAudioProps.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice, change: .defaultDevice)
        addListener(object: CoreAudioProps.systemObject, selector: kAudioHardwarePropertyDevices, change: .deviceList)
        bindDefaultDevice()
        DebugLog.line("system audio bound device=\(device?.name ?? "none") volume=\(volume) canSet=\(canSetVolume)")
    }

    func stop() {
        guard started else { return }
        started = false
        removeListeners { _ in true }
    }

    /// Re-reads on open: while the card is closed nothing here is drawn, and a device that
    /// changed behind our back (a sleep, a handoff) should not show a stale level.
    func setPopoverOpen(_ open: Bool) {
        guard started else { return }
        if open {
            bindDefaultDevice()
        } else {
            isPickingOutput = false
        }
    }

    // MARK: - Intent

    func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        let clamped = min(max(value, 0), 1)
        lastLocalWrite = Date()
        volume = clamped
        // Moving the fader off zero unmutes, the way the system slider does.
        if clamped > 0, isMuted { writeMute(false) }
        writeVolume(clamped)
    }

    func toggleMute() {
        if canMute {
            writeMute(!isMuted)
            return
        }
        // No hardware mute on this output: park the fader at zero and remember where it was.
        guard canSetVolume else { return }
        if isMuted {
            isMuted = false
            setVolume(preMuteVolume)
        } else {
            preMuteVolume = max(volume, 0.05)
            setVolume(0)
            isMuted = true
        }
    }

    /// Opens or closes the output list, refreshing the devices on the way in so a
    /// headset plugged in since the card opened is there.
    func toggleOutputPicker() {
        if !isPickingOutput { refreshDevices() }
        isPickingOutput.toggle()
    }

    func select(_ device: OutputDevice) {
        isPickingOutput = false
        guard device.id != deviceID else { return }
        var address = CoreAudioProps.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device.id
        let status = AudioObjectSetPropertyData(
            CoreAudioProps.systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &id
        )
        DebugLog.line("output device -> \(device.name) status=\(status)")
        guard status == noErr else { return }
        // Adopt what we asked for rather than reading the property straight back:
        // `coreaudiod` applies the change asynchronously, so an immediate read still
        // returns the *old* device and the card would show the wrong name for a beat.
        // The listener confirms it a moment later either way.
        bind(to: device.id)
    }

    // MARK: - Binding

    private func bindDefaultDevice() {
        bind(to: CoreAudioProps.get(
            object: CoreAudioProps.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) ?? CoreAudioProps.unknown)
    }

    private func bind(to next: AudioObjectID) {
        if next != deviceID {
            let previous = deviceID
            removeListeners { $0.object == previous }
            deviceID = next
            if next != CoreAudioProps.unknown {
                // Element main *and* the first two channels: a device that has no master
                // volume publishes its changes per channel, and a listener on main would
                // never hear them.
                for element in [kAudioObjectPropertyElementMain, 1, 2] {
                    addListener(
                        object: next,
                        selector: kAudioDevicePropertyVolumeScalar,
                        scope: kAudioObjectPropertyScopeOutput,
                        element: AudioObjectPropertyElement(element),
                        change: .level
                    )
                }
                addListener(
                    object: next,
                    selector: kAudioDevicePropertyMute,
                    scope: kAudioObjectPropertyScopeOutput,
                    change: .level
                )
            }
        }

        control = Self.resolveVolumeControl(deviceID)
        canMute = Self.isSettable(deviceID, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        canSetVolume = control != .unavailable
        refreshDevices()
        refreshLevel(force: true)
    }

    private func refreshDevices() {
        let ids: [AudioObjectID] = CoreAudioProps.getArray(
            object: CoreAudioProps.systemObject,
            selector: kAudioHardwarePropertyDevices
        )
        var found: [OutputDevice] = []
        for id in ids {
            guard Self.hasOutputStreams(id) else { continue }
            let name = CoreAudioProps.getString(object: id, selector: kAudioObjectPropertyName) ?? "Output"
            guard !name.hasPrefix(Self.ownDeviceNamePrefix) else { continue }
            found.append(OutputDevice(id: id, name: name, symbol: Self.symbol(for: id)))
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        devices = found
        device = found.first { $0.id == deviceID } ?? Self.describe(deviceID)
    }

    private func refreshLevel(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastLocalWrite) > Self.localWriteGrace else { return }
        volume = readVolume()
        isMuted = canMute ? readMute() : (canSetVolume && volume <= 0.0001)
    }

    private enum Change: Sendable {
        case defaultDevice
        case deviceList
        case level
    }

    private func handle(_ change: Change) {
        switch change {
        case .defaultDevice: bindDefaultDevice()
        case .deviceList: refreshDevices()
        case .level: refreshLevel()
        }
    }

    // MARK: - Volume plumbing

    /// Which element(s) actually carry this device's volume. Master is the common case;
    /// plenty of devices expose only per-channel volume and no master element at all.
    private enum VolumeControl: Equatable {
        case main
        case channels([AudioObjectPropertyElement])
        case unavailable
    }

    private static func resolveVolumeControl(_ device: AudioObjectID) -> VolumeControl {
        guard device != CoreAudioProps.unknown else { return .unavailable }
        if isSettable(device, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return .main
        }
        var stereo: (UInt32, UInt32) = (1, 2)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout.size(ofValue: stereo))
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &stereo) != noErr {
            stereo = (1, 2)
        }
        let usable = [stereo.0, stereo.1].filter {
            isSettable(device, kAudioDevicePropertyVolumeScalar, element: $0)
        }
        return usable.isEmpty ? .unavailable : .channels(usable)
    }

    private func readVolume() -> Float {
        switch control {
        case .main:
            return scalar(element: kAudioObjectPropertyElementMain) ?? 0
        case .channels(let elements):
            // The louder channel, so a balance that is not centred still reads as "this
            // loud" rather than as the quiet side's level.
            return elements.compactMap { scalar(element: $0) }.max() ?? 0
        case .unavailable:
            return 0
        }
    }

    private func writeVolume(_ value: Float) {
        let elements: [AudioObjectPropertyElement] = switch control {
        case .main: [kAudioObjectPropertyElementMain]
        case .channels(let elements): elements
        case .unavailable: []
        }
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var scalar = Float32(value)
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &scalar
            )
        }
    }

    private func scalar(element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return Float(value)
    }

    private func readMute() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private func writeMute(_ muted: Bool) {
        guard canMute else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        lastLocalWrite = Date()
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    // MARK: - Device plumbing

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isSettable(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Bool {
        guard device != CoreAudioProps.unknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func describe(_ device: AudioObjectID) -> OutputDevice? {
        guard device != CoreAudioProps.unknown else { return nil }
        let name = CoreAudioProps.getString(object: device, selector: kAudioObjectPropertyName) ?? "Output"
        return OutputDevice(id: device, name: name, symbol: symbol(for: device))
    }

    private static func symbol(for device: AudioObjectID) -> String {
        let transport: UInt32? = CoreAudioProps.get(
            object: device,
            selector: kAudioDevicePropertyTransportType
        )
        return switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI: "hifispeaker.fill"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: "waveform"
        default: "speaker.wave.2.fill"
        }
    }

    // MARK: - Listeners

    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private func addListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        change: Change
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handle(change) }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else {
            return
        }
        listeners.append(Listener(object: object, address: address, block: block))
    }

    private func removeListeners(where predicate: (Listener) -> Bool) {
        var kept: [Listener] = []
        for listener in listeners {
            guard predicate(listener) else {
                kept.append(listener)
                continue
            }
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        listeners = kept
    }
}
