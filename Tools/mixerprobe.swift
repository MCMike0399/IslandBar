#!/usr/bin/env swift
// Prints what the mixer sees: every audio process, which of them hold a live output
// connection, and the app each one resolves to.
//
// The two things worth checking here are documented in PITFALLS.md under "Per-app volume":
// `kAudioProcessPropertyDevices` answers only in the OUTPUT scope (globally it returns an
// empty array for every process, including ones that are audibly playing), and a helper
// process only names its owning app through the responsible-pid SPI.
//
//   swift Tools/mixerprobe.swift
import CoreAudio
import Darwin
import Foundation

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getArray<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.size
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    var ioSize = size
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &ioSize, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return nil }
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

// Same resolution order as Sources/IslandBar/Mixer/AudioAppIdentity.swift.
let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
}()

func executableURL(_ pid: pid_t) -> URL? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
    guard length > 0 else { return nil }
    return URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF8.self))
}

func bundleIdentity(_ executable: URL) -> (id: String, name: String)? {
    var outermost: URL?
    var url = executable
    while url.pathComponents.count > 1 {
        url = url.deletingLastPathComponent()
        if url.pathExtension == "app" { outermost = url }
    }
    guard let appURL = outermost, let bundle = Bundle(url: appURL),
          let identifier = bundle.bundleIdentifier else { return nil }
    let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? FileManager.default.displayName(atPath: appURL.path)
    return (identifier, name.trimmingCharacters(in: .whitespaces))
}

func resolve(_ pid: pid_t) -> (id: String, name: String, viaResponsible: Bool)? {
    if let direct = executableURL(pid).flatMap(bundleIdentity) {
        return (direct.id, direct.name, false)
    }
    guard let responsible = responsiblePID?(pid), responsible != pid, responsible > 0,
          let owner = executableURL(responsible).flatMap(bundleIdentity) else { return nil }
    return (owner.id, owner.name, true)
}

let ids: [AudioObjectID] = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
print("process objects: \(ids.count)")
print(String(repeating: "-", count: 78))

var playing = 0
for id in ids {
    let pid: pid_t = get(id, kAudioProcessPropertyPID) ?? 0
    let raw = getString(id, kAudioProcessPropertyBundleID) ?? "-"
    let outputScope: [AudioObjectID] = getArray(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
    let globalScope: [AudioObjectID] = getArray(id, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeGlobal)
    guard !outputScope.isEmpty else { continue }
    playing += 1
    let running: UInt32 = get(id, kAudioProcessPropertyIsRunningOutput) ?? 0
    let resolved = resolve(pid)
    print("pid=\(pid) bundle=\(raw)")
    print("   devices(output)=\(outputScope) devices(global)=\(globalScope) isRunningOutput=\(running != 0)")
    if let resolved {
        print("   app=\"\(resolved.name)\" id=\(resolved.id)\(resolved.viaResponsible ? "  [via responsible pid]" : "")")
    } else {
        print("   app=UNRESOLVED (the mixer drops this row rather than showing a wrong name)")
    }
}

print(String(repeating: "-", count: 78))
print("holding an output connection: \(playing) of \(ids.count)")
print("devices(global) is empty for every process — that scope is the trap.")
