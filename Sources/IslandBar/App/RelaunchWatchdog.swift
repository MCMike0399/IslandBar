import AppKit
import Foundation

/// Relaunches the app if it exits without going through `NSApplication.terminate`.
///
/// A detached `/bin/sh` waits for this pid to disappear and then reopens the bundle.
/// A clean quit disarms it first, so only crashes and kills trigger a relaunch.
/// Relaunch timestamps are recorded so a crash loop (5 in 10 minutes) stops re-arming.
@MainActor
final class RelaunchWatchdog {
    static let maxRelaunches = 5
    static let window: TimeInterval = 600

    private var process: Process?

    private static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IslandBar", isDirectory: true)
    }

    private static var stampFile: URL {
        stateDirectory.appendingPathComponent("relaunches.log")
    }

    /// Recent relaunch timestamps, pruned to the crash-loop window.
    static func recentRelaunches(now: Date = Date()) -> [Date] {
        guard let text = try? String(contentsOf: stampFile, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .compactMap { TimeInterval($0) }
            .map { Date(timeIntervalSince1970: $0) }
            .filter { now.timeIntervalSince($0) < window }
    }

    func arm() {
        guard ProcessInfo.processInfo.environment["ISLANDBAR_NO_WATCHDOG"] != "1" else {
            DebugLog.line("watchdog disabled by ISLANDBAR_NO_WATCHDOG")
            return
        }
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            DebugLog.line("watchdog not armed: not running from an app bundle")
            return
        }

        let recent = Self.recentRelaunches()
        if let last = recent.last, Date().timeIntervalSince(last) < 15 {
            DebugLog.line("relaunched by watchdog (\(recent.count) relaunches in the last 10 min)")
        }
        if recent.count >= Self.maxRelaunches {
            DebugLog.line("watchdog not armed: crash loop (\(recent.count) relaunches in 10 min)")
            return
        }

        try? FileManager.default.createDirectory(at: Self.stateDirectory, withIntermediateDirectories: true)
        if !recent.isEmpty {
            let pruned = recent.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: "\n") + "\n"
            try? pruned.write(to: Self.stampFile, atomically: true, encoding: .utf8)
        }

        // $1 pid, $2 bundle path, $3 stamp file, $4 "1" to relaunch with debug logging.
        let script = """
        trap '' HUP
        while kill -0 "$1" 2>/dev/null; do sleep 2; done
        sleep 1
        date +%s >> "$3"
        if [ "$4" = "1" ]; then
            exec /usr/bin/open --env ISLANDBAR_DEBUG=1 "$2"
        fi
        exec /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "islandbar-watchdog",
            String(ProcessInfo.processInfo.processIdentifier),
            bundlePath,
            Self.stampFile.path,
            DebugLog.enabled ? "1" : "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
            DebugLog.line("watchdog armed pid=\(process.processIdentifier)")
        } catch {
            DebugLog.line("watchdog failed to start: \(error)")
        }
    }

    func disarm() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
        DebugLog.line("watchdog disarmed")
    }
}
