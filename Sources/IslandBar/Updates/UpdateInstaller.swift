import AppKit
import Foundation

enum UpdateInstallError: LocalizedError {
    case notBundled
    case translocated
    case notWritable(String)
    case download(String)
    case corruptArchive(String)
    case wrongBundle(String)
    case swap(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            "IslandBar is not running from an app bundle, so it cannot update itself."
        case .translocated:
            "macOS is running IslandBar from a temporary location. Move IslandBar.app to your Applications folder and open it from there to enable updates."
        case .notWritable(let path):
            "IslandBar cannot replace itself in \(path). Download the update manually or move IslandBar to a folder you can write to."
        case .download(let detail):
            "The download failed: \(detail)"
        case .corruptArchive(let detail):
            "The downloaded archive is unusable: \(detail)"
        case .wrongBundle(let detail):
            "The downloaded app is not the expected IslandBar build: \(detail)"
        case .swap(let detail):
            "The new version could not be put in place: \(detail)"
        }
    }
}

enum InstallProgress: Sendable {
    case downloading(received: Int64, total: Int64?)
    case verifying
    case installing
}

struct InstalledUpdate: Sendable {
    /// The new bundle, now at the path the old one occupied.
    let appURL: URL
    /// The previous bundle, parked next to the staging area until the relaunch removes it.
    let backupURL: URL
    let stagingDirectory: URL
}

/// Downloads, verifies and swaps in a release. Everything here is off the main actor;
/// the caller only sees `InstallProgress` callbacks and the final result.
struct UpdateInstaller: Sendable {
    let release: UpdateRelease
    let currentApp: URL

    /// Things that make an in-place update impossible; checked before offering one.
    static func installBlocker(for bundleURL: URL) -> UpdateInstallError? {
        guard bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == IslandBarID.bundleID else { return .notBundled }
        if bundleURL.path.contains("/AppTranslocation/") { return .translocated }
        let parent = bundleURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent),
              FileManager.default.isWritableFile(atPath: bundleURL.path) else { return .notWritable(parent) }
        return nil
    }

    func install(progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> InstalledUpdate {
        if let blocker = Self.installBlocker(for: currentApp) { throw blocker }
        let fm = FileManager.default

        // Same volume as the app so the final moves are renames, not copies.
        let replacementDir = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: currentApp, create: true
        )
        let staging = replacementDir.appendingPathComponent("IslandBar-update-\(release.version)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let archive = staging.appendingPathComponent(release.archiveName)
            let signature = staging.appendingPathComponent(release.archiveName + ".sig")
            progress(.downloading(received: 0, total: release.archiveSize))
            try await download(release.archiveURL, to: archive, expectedSize: release.archiveSize) { received, total in
                progress(.downloading(received: received, total: total))
            }
            try Task.checkCancellation()
            try await download(release.signatureURL, to: signature, expectedSize: nil) { _, _ in }
            try Task.checkCancellation()

            progress(.verifying)
            try UpdateSignature.verify(archive: archive, signatureFile: signature)
            let newApp = try extract(archive, into: staging.appendingPathComponent("extracted", isDirectory: true))
            try validate(newApp)
            try Task.checkCancellation()

            progress(.installing)
            let backup = try swap(newApp: newApp, into: currentApp, parkingIn: replacementDir)
            return InstalledUpdate(appURL: currentApp, backupURL: backup, stagingDirectory: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Steps

    private func download(
        _ url: URL, to destination: URL, expectedSize: Int64?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let (bytes, response) = try await UpdateFeed.session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.download("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        let total: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : expectedSize
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateInstallError.download("cannot create \(destination.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 16)
        var received: Int64 = 0
        var lastReport = ContinuousClock.now
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if ContinuousClock.now - lastReport > .milliseconds(80) {
                    lastReport = .now
                    progress(received, total)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        if let total, total != received {
            throw UpdateInstallError.download("expected \(total) bytes, got \(received)")
        }
        progress(received, total ?? received)
    }

    private func extract(_ archive: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        } catch {
            throw UpdateInstallError.corruptArchive(error.localizedDescription)
        }
        let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else {
            throw UpdateInstallError.corruptArchive("archive does not contain exactly one .app")
        }
        // URLSession does not quarantine, but be explicit so Gatekeeper never sees a stale flag.
        _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private func validate(_ app: URL) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else {
            throw UpdateInstallError.wrongBundle("missing Info.plist")
        }
        guard bundle.bundleIdentifier == IslandBarID.bundleID else {
            throw UpdateInstallError.wrongBundle("bundle identifier \(bundle.bundleIdentifier ?? "nil")")
        }
        let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard shipped == release.version else {
            throw UpdateInstallError.wrongBundle("version \(shipped?.description ?? "?") instead of \(release.version)")
        }
        do {
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateInstallError.wrongBundle("code signature is damaged (\(error.localizedDescription))")
        }
    }

    /// Moves the running bundle aside and renames the new one into its place.
    /// The running process keeps working from the moved bundle until it exits.
    private func swap(newApp: URL, into destination: URL, parkingIn parkDir: URL) throws -> URL {
        let fm = FileManager.default
        let backup = parkDir.appendingPathComponent("IslandBar-previous-\(AppVersion.current).app")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: destination, to: backup)
        } catch {
            throw UpdateInstallError.swap(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: newApp, to: destination)
        } catch {
            try? fm.moveItem(at: backup, to: destination)
            throw UpdateInstallError.swap(error.localizedDescription)
        }
        return backup
    }

    struct ToolFailure: LocalizedError {
        let tool: String
        let status: Int32
        let output: String
        var errorDescription: String? {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) exited \(status)" + (trimmed.isEmpty ? "" : ": \(trimmed)")
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ToolFailure(tool: (tool as NSString).lastPathComponent, status: process.terminationStatus, output: output)
        }
        return output
    }
}
