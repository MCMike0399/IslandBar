import AppKit
import Foundation
import MediaRemoteAdapter

/// What a browser tab is playing, recovered from the browser itself when its Now Playing
/// payload has no title (Arc's mini player publishes an empty title and no artwork).
struct BrowserMedia: Equatable {
    /// Stable identity of the media (video id for YouTube, otherwise the page URL).
    let key: String
    var title: String
    var artist: String
    var artwork: NSImage?
    let pageURL: URL
    let site: String
}

struct BrowserTab: Sendable {
    let title: String
    let url: URL
    let isActive: Bool
}

/// Browsers whose tabs can be read over Apple Events. Firefox has no tab scripting.
enum ScriptableBrowser: Sendable {
    case chromium(bundleID: String)
    case safari(bundleID: String)

    static func from(bundleID: String) -> ScriptableBrowser? {
        switch bundleID {
        case "company.thebrowser.Browser", "company.thebrowser.dia",
             "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
             "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
             "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
             "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera",
             "com.operasoftware.OperaGX":
            return .chromium(bundleID: bundleID)
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari(bundleID: bundleID)
        default:
            return nil
        }
    }

    var bundleID: String {
        switch self {
        case .chromium(let id), .safari(let id): id
        }
    }

    /// Emits one record per tab: URL, title and whether it is the window's active tab. Tab
    /// lists are fetched as whole-window properties, so a window costs three Apple Events
    /// regardless of how many tabs it has. Front window comes first.
    var source: String {
        let (active, title) = switch self {
        case .chromium: ("active tab", "title")
        case .safari: ("current tab", "name")
        }
        return """
        set fs to (ASCII character 31)
        set rs to (ASCII character 30)
        set out to ""
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                repeat with w in windows
                    set activeURL to ""
                    try
                        set activeURL to URL of \(active) of w
                    end try
                    set urls to {}
                    set titles to {}
                    try
                        set urls to URL of tabs of w
                        set titles to \(title) of tabs of w
                    end try
                    repeat with i from 1 to (count of urls)
                        set u to item i of urls
                        if u is not missing value and u is not "" then
                            set flag to "0"
                            if u is activeURL then set flag to "1"
                            set out to out & u & fs & (item i of titles) & fs & flag & rs
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        return out
        """
    }
}

struct BrowserScriptError: Error {
    let code: Int
    let message: String
    /// errAEEventNotPermitted: the user declined the Automation prompt (or it was never shown).
    var isPermissionDenied: Bool { code == -1743 }
    /// procNotFound / connectionInvalid: the browser quit mid-poll.
    var isBrowserGone: Bool { code == -600 || code == -609 }
}

/// Runs the tab script in an `osascript` child on a private serial queue. `NSAppleScript`
/// is main-thread-only and a hung browser would stall the pill; a child process can simply
/// be killed. TCC attributes the Automation prompt to the responsible parent, IslandBar.
enum BrowserTabScript {
    private static let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.browser-tabs", qos: .utility)
    /// Longer than the script's own 3 s Apple Event timeout so that path wins when the
    /// browser is merely slow; this one only catches a wedged osascript.
    private static let killAfter: TimeInterval = 6

    static func tabs(of browser: ScriptableBrowser) async throws -> [BrowserTab] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try run(browser))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func run(_ browser: ScriptableBrowser) throws -> [BrowserTab] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", browser.source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killAfter, execute: killer)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else {
            // osascript prints "…: message (-1743)"; the trailing code is what we branch on.
            let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = message.range(of: #"\((-?\d+)\)$"#, options: .regularExpression)
                .flatMap { Int(message[$0].dropFirst().dropLast()) } ?? Int(process.terminationStatus)
            throw BrowserScriptError(code: code, message: message.isEmpty ? "osascript exited \(process.terminationStatus)" : message)
        }
        let text = String(decoding: output, as: UTF8.self)
        return text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let url = URL(string: String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            return BrowserTab(title: String(fields[1]), url: url, isActive: fields[2].hasPrefix("1"))
        }
    }
}

/// Recognises pages that play media and cleans their tab titles.
enum MediaSite {
    struct Match {
        let key: String
        let site: String
        let youtubeID: String?
    }

    static func match(_ url: URL) -> Match? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            components?.queryItems?.first(where: { $0.name == name })?.value
        }
        func pathID(after prefix: String) -> String? {
            guard path.hasPrefix(prefix) else { return nil }
            let rest = path.dropFirst(prefix.count)
            let id = rest.split(separator: "/").first.map(String.init) ?? ""
            return id.isEmpty ? nil : id
        }

        if host == "youtu.be" {
            guard let id = pathID(after: "/") else { return nil }
            return Match(key: "youtube:\(id)", site: "YouTube", youtubeID: id)
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let site = host.hasPrefix("music.") ? "YouTube Music" : "YouTube"
            let id: String? = path == "/watch"
                ? query("v")
                : (pathID(after: "/shorts/") ?? pathID(after: "/live/") ?? pathID(after: "/embed/"))
            guard let id, !id.isEmpty else { return nil }
            return Match(key: "youtube:\(id)", site: site, youtubeID: id)
        }

        let sites: [(suffix: String, name: String, pathPrefix: String?)] = [
            ("twitch.tv", "Twitch", nil),
            ("soundcloud.com", "SoundCloud", nil),
            ("open.spotify.com", "Spotify", nil),
            ("vimeo.com", "Vimeo", nil),
            ("bandcamp.com", "Bandcamp", nil),
            ("music.apple.com", "Apple Music", nil),
            ("tidal.com", "TIDAL", nil),
            ("deezer.com", "Deezer", nil),
            ("netflix.com", "Netflix", "/watch"),
            ("primevideo.com", "Prime Video", nil),
            ("disneyplus.com", "Disney+", "/video"),
            ("max.com", "Max", nil),
            ("hbomax.com", "Max", nil),
            ("plex.tv", "Plex", nil),
            ("nebula.tv", "Nebula", nil),
            ("dailymotion.com", "Dailymotion", "/video"),
        ]
        for site in sites where host == site.suffix || host.hasSuffix("." + site.suffix) {
            if let prefix = site.pathPrefix, !path.hasPrefix(prefix) { continue }
            guard path.count > 1 else { continue }
            return Match(key: "\(host)\(path)", site: site.name, youtubeID: nil)
        }
        return nil
    }

    /// "(3) Some Video - YouTube" → "Some Video".
    static func cleanTitle(_ raw: String, site: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = title.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        for separator in [" - ", " | ", " · ", " — ", " – "] {
            for name in [site, "YouTube", "YouTube Music"] {
                let suffix = separator + name
                if title.lowercased().hasSuffix(suffix.lowercased()) {
                    title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return title
    }
}

/// Polls a browser's tabs while its Now Playing session lacks a title, picks the tab that
/// is most likely playing, and fills in title / channel / thumbnail (YouTube via oEmbed).
@MainActor
final class BrowserMediaResolver {
    static let pollInterval: TimeInterval = 4
    /// While paused nothing changes quickly; poll less so a paused tab costs almost nothing.
    static let pausedPollInterval: TimeInterval = 12
    /// A denied Automation prompt is retried after this long, in case the user flipped the
    /// switch in System Settings without using the menu item.
    static let deniedRetryInterval: TimeInterval = 60
    static let enrichmentCacheLimit = 24

    var onChange: (() -> Void)?
    var onAccessDenied: ((String) -> Void)?

    private(set) var current: BrowserMedia?
    private(set) var browser: ScriptableBrowser?

    private var timer: DispatchSourceTimer?
    private var pollInFlight = false
    /// After a Now Playing event the browser may have switched media: re-pick from the
    /// active tab instead of sticking with the previous choice.
    private var preferActiveTab = true
    private var deniedBundleIDs: [String: Date] = [:]
    private var currentInterval: TimeInterval = 0
    private var enriched: [String: BrowserMedia] = [:]
    private var enrichmentInFlight: Set<String> = []
    private var consecutiveFailures = 0

    /// Start (or keep) following `bundleID`. Called on every title-less Now Playing event.
    func track(bundleID: String, playing: Bool) {
        guard let candidate = ScriptableBrowser.from(bundleID: bundleID) else {
            stop()
            return
        }
        preferActiveTab = true
        if browser?.bundleID != bundleID {
            browser = candidate
            current = nil
            consecutiveFailures = 0
            DebugLog.line("browser media: following \(bundleID)")
        }
        if let deniedAt = deniedBundleIDs[bundleID] {
            guard Date().timeIntervalSince(deniedAt) >= Self.deniedRetryInterval else { return }
            deniedBundleIDs[bundleID] = nil
        }
        let interval = playing ? Self.pollInterval : Self.pausedPollInterval
        if timer == nil || interval != currentInterval {
            timer?.cancel()
            currentInterval = interval
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    /// The user asked to re-enable tab access: forget denials and poll again right away.
    func retryAccess() {
        deniedBundleIDs.removeAll()
        if let browser { track(bundleID: browser.bundleID, playing: true) }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        currentInterval = 0
        if browser != nil { DebugLog.line("browser media: stopped following \(browser!.bundleID)") }
        browser = nil
        if current != nil {
            current = nil
            onChange?()
        }
    }

    private func poll() {
        guard let browser, !pollInFlight else { return }
        pollInFlight = true
        Task { @MainActor in
            defer { pollInFlight = false }
            do {
                let tabs = try await BrowserTabScript.tabs(of: browser)
                consecutiveFailures = 0
                guard self.browser?.bundleID == browser.bundleID else { return }
                select(from: tabs)
            } catch let error as BrowserScriptError {
                if error.isPermissionDenied {
                    DebugLog.line("browser media: Apple Events denied for \(browser.bundleID)")
                    deniedBundleIDs[browser.bundleID] = Date()
                    timer?.cancel()
                    timer = nil
                    onAccessDenied?(browser.bundleID)
                } else if error.isBrowserGone {
                    stop()
                } else {
                    consecutiveFailures += 1
                    DebugLog.line("browser media: script failed (\(error.code)) \(error.message)")
                    if consecutiveFailures >= 5 { stop() }
                }
            } catch {
                DebugLog.line("browser media: \(error)")
            }
        }
    }

    private func select(from tabs: [BrowserTab]) {
        let candidates = tabs.compactMap { tab -> (BrowserTab, MediaSite.Match)? in
            MediaSite.match(tab.url).map { (tab, $0) }
        }
        guard !candidates.isEmpty else {
            if current != nil {
                DebugLog.line("browser media: no media tab left")
                current = nil
                onChange?()
            }
            return
        }
        let chosen: (BrowserTab, MediaSite.Match)
        if candidates.count == 1 {
            chosen = candidates[0]
        } else if preferActiveTab, let active = candidates.first(where: { $0.0.isActive }) {
            chosen = active
        } else if let current, let sticky = candidates.first(where: { $0.1.key == current.key }) {
            chosen = sticky
        } else if let active = candidates.first(where: { $0.0.isActive }) {
            chosen = active
        } else {
            chosen = candidates[0]
        }
        preferActiveTab = false

        let (tab, match) = chosen
        if let known = enriched[match.key] {
            publish(known)
            return
        }
        let media = BrowserMedia(
            key: match.key,
            title: MediaSite.cleanTitle(tab.title, site: match.site),
            artist: match.site,
            artwork: nil,
            pageURL: tab.url,
            site: match.site
        )
        publish(media)
        if let id = match.youtubeID { enrichYouTube(id: id, base: media) }
    }

    private func publish(_ media: BrowserMedia) {
        guard media != current else { return }
        let changedItem = media.key != current?.key
        current = media
        if changedItem {
            DebugLog.line("browser media: \(media.site) “\(media.title)” \(media.pageURL.absoluteString)")
        } else {
            DebugLog.line("browser media: enriched artist=\(media.artist) artwork=\(media.artwork != nil)")
        }
        onChange?()
    }

    /// YouTube's oEmbed endpoint gives the clean title and channel name without an API key;
    /// the thumbnail comes from the predictable i.ytimg.com URL.
    private func enrichYouTube(id: String, base: BrowserMedia) {
        guard !enrichmentInFlight.contains(base.key) else { return }
        enrichmentInFlight.insert(base.key)
        Task { @MainActor in
            defer { enrichmentInFlight.remove(base.key) }
            var media = base
            let watchURL = "https://www.youtube.com/watch?v=\(id)"
            if let info = await Self.fetchOEmbed(for: watchURL) {
                if !info.title.isEmpty { media.title = info.title }
                if !info.author.isEmpty { media.artist = info.author }
            }
            if let data = await Self.fetchThumbnail(videoID: id), let image = NSImage(data: data) {
                media.artwork = image
            }
            if enriched.count >= Self.enrichmentCacheLimit {
                enriched = enriched.filter { $0.key == current?.key }
            }
            enriched[base.key] = media
            if current?.key == base.key { publish(media) }
        }
    }

    private struct OEmbed: Decodable {
        let title: String
        let author: String
        enum CodingKeys: String, CodingKey {
            case title
            case author = "author_name"
        }
    }

    private nonisolated static func fetchOEmbed(for watchURL: String) async -> OEmbed? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: watchURL), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(OEmbed.self, from: data)
    }

    private nonisolated static func fetchThumbnail(videoID: String) async -> Data? {
        // maxresdefault only exists for HD uploads; mqdefault always does and has no letterbox bars.
        for name in ["maxresdefault", "mqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 2_000 else { continue }
            return data
        }
        return nil
    }
}

extension TrackInfo.Payload {
    /// The same event with title, artist, album and artwork removed (debug fallback testing).
    func strippingMetadata() -> TrackInfo.Payload {
        TrackInfo.Payload(
            isPlaying: isPlaying,
            durationMicros: durationMicros,
            elapsedTimeMicros: elapsedTimeMicros,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            timestampEpochMicros: timestampEpochMicros,
            PID: PID,
            shuffleMode: shuffleMode,
            repeatMode: repeatMode,
            playbackRate: playbackRate
        )
    }
}
