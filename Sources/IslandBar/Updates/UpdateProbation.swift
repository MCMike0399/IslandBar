import Foundation

/// The handshake between a freshly installed update and the helper that launched it.
///
/// v0.5.0 crashed at launch on every Mac but the one that built it, and an app that cannot
/// start cannot run its updater, so every copy that took it stayed broken until someone
/// reinstalled it by hand. The relaunch helper used to open the new version, wait eight
/// seconds and delete the old one without ever asking whether the new one came up.
///
/// Now the new version is on probation. Every launch writes its version to `healthyMarker`
/// once it has been up for `healthyAfter` seconds; the helper waits up to `deadline` for that
/// exact version to appear there. If it does not — a crash at launch, a hang — the helper puts
/// the previous bundle back, reopens it, and leaves `rollbackRecord` behind. The restored
/// version reads the record, skips the version that failed (a later release is still offered)
/// and tells the user. See `UpdateController.relaunch` for the helper itself.
enum UpdateProbation {
    /// Long enough to get past `applicationDidFinishLaunching` and everything it starts —
    /// v0.5.0 died inside it — and short enough not to keep the old copy around for long.
    static let healthyAfter: TimeInterval = 5

    /// How long the helper waits for the marker. Generous, because a Mac that is busy right
    /// after an update can take a while to launch anything. `ISLANDBAR_UPDATE_PROBATION`
    /// shortens it for the harness, honoured only together with a feed override.
    static var deadline: Int {
        let env = ProcessInfo.processInfo.environment
        if env["ISLANDBAR_UPDATE_FEED_URL"] != nil,
           let raw = env["ISLANDBAR_UPDATE_PROBATION"], let seconds = Int(raw), seconds > 0 {
            return seconds
        }
        return 60
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IslandBar", isDirectory: true)
    }

    /// Holds the version of the last launch that stayed up `healthyAfter` seconds.
    static var healthyMarker: URL { directory.appendingPathComponent("launched-ok") }

    /// Written by the helper after a rollback: "<failed version> <restored version>".
    static var rollbackRecord: URL { directory.appendingPathComponent("rolled-back") }

    /// Everything the relaunch helper did, appended per update.
    static var helperLog: URL { directory.appendingPathComponent("update-helper.log") }

    /// Called once per launch; writes the marker after `healthyAfter` seconds of being up.
    @MainActor
    static func scheduleHealthyMarker() {
        DispatchQueue.main.asyncAfter(deadline: .now() + healthyAfter) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try AppVersion.current.description.write(to: healthyMarker, atomically: true, encoding: .utf8)
                DebugLog.line("updates: launch healthy (\(AppVersion.current))")
            } catch {
                DebugLog.line("updates: could not write the launch-health marker: \(error)")
            }
        }
    }

    /// The rollback the helper performed before this launch, if any, consumed on read.
    static func takeRollback() -> (failed: AppVersion, restored: AppVersion)? {
        guard let text = try? String(contentsOf: rollbackRecord, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: rollbackRecord)
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, let failed = AppVersion(parts[0]), let restored = AppVersion(parts[1]) else {
            return nil
        }
        return (failed, restored)
    }
}
