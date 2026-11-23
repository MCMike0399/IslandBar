import Darwin
import Foundation
import MediaRemoteAdapter

func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func listenerPIDs() -> [pid_t] {
    let ps = Process()
    let pipe = Pipe()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-ww", "-axo", "pid=,ppid=,command="]
    ps.standardOutput = pipe
    try! ps.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    return output.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count == 3, Int32(fields[1]) == getpid(),
              fields[2].contains("MediaRemoteAdapter_MediaRemoteAdapter.bundle/"),
              fields[2].hasSuffix(" loop") else { return nil }
        return Int32(fields[0])
    }
}

if CommandLine.arguments[1] == "eof" {
    let input = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = Array(CommandLine.arguments[2...]) + ["loop"]
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.close()
    wait(1)
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        print("listener stayed alive after its parent closed stdin")
        exit(1)
    }
    print("listener exited after stdin EOF, status=\(process.terminationStatus)")
    exit(process.terminationStatus)
}

let controller = MediaController()
var initialPID: pid_t?
var events = 0
controller.onTrackInfoReceived = { _ in
    events += 1
    if events == 1 {
        // Mimic a host health check during the adapter's old delayed recycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.startListening()
        }
    }
}
controller.onListenerDiagnostic = { print("MediaRemote listener \($0)") }
controller.startListening()
initialPID = listenerPIDs().first
wait(1)
let running = listenerPIDs()
controller.stopListening()
wait(0.5)
let stopped = listenerPIDs()
print("recycle: events=\(events) running=\(running.count) after-stop=\(stopped.count)")
for pid in stopped { kill(pid, SIGKILL) }
exit(events >= 100 && running.count == 1 && initialPID != nil &&
     running.first != initialPID && stopped.isEmpty ? 0 : 1)
