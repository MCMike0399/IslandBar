import Foundation

/// One published GitHub release that ships an installable archive.
struct UpdateRelease: Equatable, Sendable {
    let version: AppVersion
    let tagName: String
    let title: String
    let notes: String
    let publishedAt: Date?
    let pageURL: URL
    let archiveURL: URL
    let archiveName: String
    let archiveSize: Int64?
    let signatureURL: URL
}

enum UpdateFeedError: LocalizedError, Equatable {
    case rateLimited
    case badStatus(Int)
    case malformed
    case missingArchive
    case missingSignature

    var errorDescription: String? {
        switch self {
        case .rateLimited: "GitHub is rate-limiting update checks from this network. Try again in an hour."
        case .badStatus(let code): "The update server answered with HTTP \(code)."
        case .malformed: "The update feed could not be read."
        case .missingArchive: "The latest release has no IslandBar archive attached."
        case .missingSignature: "The latest release is missing its signature file, so it cannot be verified."
        }
    }
}

/// Reads the newest non-draft, non-prerelease GitHub release.
///
/// `ISLANDBAR_UPDATE_FEED_URL` overrides the feed (a `file://` URL works) so the whole
/// download-verify-install path can be exercised without publishing anything.
struct UpdateFeed: Sendable {
    static let repository = "MCMike0399/IslandBar"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    static var latestURL: URL {
        if let raw = ProcessInfo.processInfo.environment["ISLANDBAR_UPDATE_FEED_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60
        config.httpAdditionalHeaders = [
            "User-Agent": "IslandBar/\(AppVersion.current) (macOS)",
        ]
        return URLSession(configuration: config)
    }()

    /// `nil` means the repository has no releases yet.
    func fetchLatest() async throws -> UpdateRelease? {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 404: return nil
            case 403, 429: throw UpdateFeedError.rateLimited
            default: throw UpdateFeedError.badStatus(http.statusCode)
            }
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> UpdateRelease? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw UpdateFeedError.malformed
        }
        if payload.draft == true || payload.prerelease == true { return nil }
        guard let version = AppVersion(payload.tagName) else { throw UpdateFeedError.malformed }
        guard let archive = payload.assets.first(where: {
            $0.name.hasPrefix("IslandBar") && $0.name.hasSuffix(".zip")
        }) else { throw UpdateFeedError.missingArchive }
        guard let signature = payload.assets.first(where: { $0.name == archive.name + ".sig" }) else {
            throw UpdateFeedError.missingSignature
        }
        let notes = payload.body?.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UpdateRelease(
            version: version,
            tagName: payload.tagName,
            title: payload.name?.isEmpty == false ? payload.name! : "IslandBar \(version)",
            notes: notes,
            publishedAt: payload.publishedAt,
            pageURL: payload.htmlURL ?? releasesPage,
            archiveURL: archive.browserDownloadURL,
            archiveName: archive.name,
            archiveSize: archive.size,
            signatureURL: signature.browserDownloadURL
        )
    }

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let size: Int64?
            enum CodingKeys: String, CodingKey {
                case name, size
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let htmlURL: URL?
        let publishedAt: Date?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case name, body, draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }
}
