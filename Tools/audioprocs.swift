#!/usr/bin/env swift
import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
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

func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else {
        return nil
    }
    return buffer.pointee
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &unmanaged) == noErr, let unmanaged else {
        return nil
    }
    return unmanaged.takeRetainedValue() as String
}

let ids: [AudioObjectID] = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
print("process objects: \(ids.count)")
for id in ids {
    let pid: pid_t = get(id, kAudioProcessPropertyPID) ?? 0
    let bundle = getString(id, kAudioProcessPropertyBundleID) ?? ""
    let running: UInt32 = get(id, kAudioProcessPropertyIsRunningOutput) ?? 0
    print("id=\(id) pid=\(pid) bundle=\(bundle) isRunningOutput=\(running != 0)")
}
