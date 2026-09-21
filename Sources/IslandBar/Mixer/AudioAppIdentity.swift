import Darwin
import Foundation

/// The user-facing app behind an audio process.
struct AudioAppIdentity: Sendable, Equatable {
    /// Bundle identifier of the owning app, and the key rows are grouped by.
    var id: String
    var name: String
    /// Location of the `.app`, kept so the icon can be fetched on the main actor.
    var appPath: String
}

/// Resolves a pid to the app a person would name, which is rarely the process that
/// actually opens the audio device. Browsers play through helpers, Safari plays through
/// a WebKit daemon, and app extensions play through an `.appex`.
///
/// Everything here is `libproc` and the filesystem: no CoreAudio, so it costs no IPC to
/// `coreaudiod`, and no TCC-guarded API, so it adds no permission to the app.
final class AudioAppResolver {
    /// Answers are cached per pid because the path of a running process never changes and
    /// each miss costs a `proc_pidpath` plus a bundle read. `nil` is cached too — an
    /// unresolvable pid stays unresolvable, and retrying it every poll is pure waste.
    private var cache: [pid_t: AudioAppIdentity?] = [:]

    /// `responsibility_get_pid_responsible_for_pid` maps a helper to the process that is
    /// accountable for it — the only thing that identifies a WebKit process's owner.
    /// Parent pid cannot: every Safari and WebKit process is reparented to launchd, so
    /// they all report ppid 1.
    ///
    /// It is private SPI, so it is looked up once and kept optional. If it ever disappears
    /// the resolver loses Safari rows and nothing else.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    func identity(for pid: pid_t) -> AudioAppIdentity? {
        if let cached = cache[pid] { return cached }
        let resolved = resolve(pid: pid)
        cache[pid] = resolved
        return resolved
    }

    /// Drops entries whose process has gone. Called with the live pid set each poll so the
    /// cache cannot grow for the life of the app.
    func prune(live: Set<pid_t>) {
        cache = cache.filter { live.contains($0.key) }
    }

    private func resolve(pid: pid_t) -> AudioAppIdentity? {
        if let identity = executableURL(for: pid).flatMap(bundleIdentity(forExecutable:)) {
            return identity
        }
        // WebKit's audio process lives inside `WebKit.framework` and has no `.app` ancestor
        // at all, so the walk above finds nothing and only the responsible process names it.
        guard let responsible = Self.responsiblePID?(pid), responsible != pid, responsible > 0 else {
            return nil
        }
        return executableURL(for: responsible).flatMap(bundleIdentity(forExecutable:))
    }

    private func executableURL(for pid: pid_t) -> URL? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        // Fails with EPERM for hardened processes, which is ordinary rather than exceptional.
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF8.self))
    }

    private func bundleIdentity(forExecutable executable: URL) -> AudioAppIdentity? {
        // The *outermost* `.app` ancestor is the one a person recognises. The innermost is
        // the helper — "Arc Helper.app" rather than "Arc".
        var outermost: URL?
        var url = executable
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" { outermost = url }
        }
        guard let appURL = outermost, let bundle = Bundle(url: appURL),
              let identifier = bundle.bundleIdentifier else {
            return nil
        }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: appURL.path)
        return AudioAppIdentity(id: identifier, name: Self.clean(name), appPath: appURL.path)
    }

    /// Strips Unicode format characters. WhatsApp's display name carries a leading U+200E
    /// left-to-right mark, which renders as an invisible leading space.
    private static func clean(_ name: String) -> String {
        name.unicodeScalars
            .filter { !$0.properties.generalCategory.isFormat }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension Unicode.GeneralCategory {
    var isFormat: Bool { self == .format }
}
