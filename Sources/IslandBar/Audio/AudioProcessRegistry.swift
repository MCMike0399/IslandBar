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
    /// Bundle IDs by (object ID, pid). Each lookup is a string round-trip to
    /// coreaudiod and the answer never changes while the process lives.
    private let bundleCacheLock = NSLock()
    private var bundleCache: [AudioObjectID: (pid: pid_t, bundleID: String)] = [:]

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
        let live = Set(ids)
        return ids.compactMap { id in
            guard id != CoreAudioProps.unknown else { return nil }
            let pid: pid_t = CoreAudioProps.get(object: id, selector: kAudioProcessPropertyPID) ?? 0
            let bundle = bundleID(for: id, pid: pid, live: live)
            let running: UInt32 = CoreAudioProps.get(object: id, selector: kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: running != 0)
        }
    }

    private func bundleID(for id: AudioObjectID, pid: pid_t, live: Set<AudioObjectID>) -> String {
        bundleCacheLock.lock()
        defer { bundleCacheLock.unlock() }
        if let cached = bundleCache[id], cached.pid == pid {
            return cached.bundleID
        }
        let bundle = CoreAudioProps.getString(object: id, selector: kAudioProcessPropertyBundleID) ?? ""
        bundleCache = bundleCache.filter { live.contains($0.key) }
        bundleCache[id] = (pid: pid, bundleID: bundle)
        return bundle
    }

    /// True when `process` belongs to the app that owns `session`: same pid, same bundle ID,
    /// or same three-component bundle prefix compared case-insensitively. Chromium browsers
    /// play audio from a helper whose bundle differs only in case and suffix
    /// (`company.thebrowser.Browser` vs `company.thebrowser.browser.helper`).
    static func matches(session: NowPlayingSession, process: AudioProcessInfo) -> Bool {
        func prefix3(_ bid: String) -> String {
            bid.lowercased().split(separator: ".").prefix(3).joined(separator: ".")
        }
        if process.pid == session.pid { return true }
        if !session.bundleID.isEmpty, process.bundleID.caseInsensitiveCompare(session.bundleID) == .orderedSame {
            return true
        }
        let sessionPrefix = prefix3(session.bundleID)
        return !sessionPrefix.isEmpty && prefix3(process.bundleID) == sessionPrefix
    }

    /// Whether any process of the session's app is currently producing output.
    func isOutputActive(for session: NowPlayingSession) -> Bool {
        snapshot().contains { $0.isRunningOutput && Self.matches(session: session, process: $0) }
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
