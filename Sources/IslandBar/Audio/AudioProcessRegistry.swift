import CoreAudio
import Foundation

struct AudioProcessInfo: Sendable, Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool
}

enum CoreAudioProps {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func get<T>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0
    ) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        let status = AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier, &size, buffer)
        guard status == noErr else { return nil }
        return buffer.pointee
    }

    static func getArray<T>(object: AudioObjectID, selector: AudioObjectPropertySelector) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<T>.size
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        var ioSize = size
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &ioSize, buffer) == noErr else {
            return []
        }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func getString(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var unmanaged: Unmanaged<CFString>?
        var ioSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &ioSize, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}

final class AudioProcessRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.registry")
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    var onProcessListChange: (@Sendable () -> Void)?
    var onDefaultOutputChange: (@Sendable () -> Void)?

    func start() {
        queue.async { [weak self] in
            self?.installListeners()
        }
    }

    func stop() {
        queue.sync {
            removeListeners()
        }
    }

    func snapshot() -> [AudioProcessInfo] {
        let ids: [AudioObjectID] = CoreAudioProps.getArray(
            object: CoreAudioProps.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
        return ids.compactMap { id in
            guard id != CoreAudioProps.unknown else { return nil }
            let pid: pid_t = CoreAudioProps.get(object: id, selector: kAudioProcessPropertyPID) ?? 0
            let bundle = CoreAudioProps.getString(object: id, selector: kAudioProcessPropertyBundleID) ?? ""
            let running: UInt32 = CoreAudioProps.get(object: id, selector: kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: running != 0)
        }
    }

    func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var qualifier = pid
        let id: AudioObjectID? = CoreAudioProps.get(
            object: CoreAudioProps.systemObject,
            selector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            qualifier: &qualifier,
            qualifierSize: UInt32(MemoryLayout<pid_t>.size)
        )
        guard let id, id != CoreAudioProps.unknown else { return nil }
        return id
    }

    func defaultOutputUID() -> String? {
        guard let deviceID: AudioObjectID = CoreAudioProps.get(
            object: CoreAudioProps.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ), deviceID != CoreAudioProps.unknown else {
            return nil
        }
        return CoreAudioProps.getString(object: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func installListeners() {
        removeListeners()

        let processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onProcessListChange?()
        }
        processListListener = processBlock
        var processAddr = CoreAudioProps.address(kAudioHardwarePropertyProcessObjectList)
        _ = AudioObjectAddPropertyListenerBlock(CoreAudioProps.systemObject, &processAddr, queue, processBlock)

        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultOutputChange?()
        }
        defaultOutputListener = outputBlock
        var outputAddr = CoreAudioProps.address(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectAddPropertyListenerBlock(CoreAudioProps.systemObject, &outputAddr, queue, outputBlock)
    }

    private func removeListeners() {
        if let processListListener {
            var addr = CoreAudioProps.address(kAudioHardwarePropertyProcessObjectList)
            _ = AudioObjectRemovePropertyListenerBlock(CoreAudioProps.systemObject, &addr, queue, processListListener)
        }
        if let defaultOutputListener {
            var addr = CoreAudioProps.address(kAudioHardwarePropertyDefaultOutputDevice)
            _ = AudioObjectRemovePropertyListenerBlock(CoreAudioProps.systemObject, &addr, queue, defaultOutputListener)
        }
        processListListener = nil
        defaultOutputListener = nil
    }
}
