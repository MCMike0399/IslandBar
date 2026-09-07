import Foundation

enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["ISLANDBAR_DEBUG"] == "1"
    static let forceProcedural = ProcessInfo.processInfo.environment["ISLANDBAR_FORCE_PROCEDURAL"] == "1"

    private static let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.log")
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/IslandBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }()

    static func line(_ message: String) {
        guard enabled else { return }
        queue.async {
            let ts = formatter.string(from: Date())
            guard let data = "[\(ts)] \(message)\n".data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
    }
}
