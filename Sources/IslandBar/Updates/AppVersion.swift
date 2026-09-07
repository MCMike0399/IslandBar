import Foundation

/// Semantic-ish version: dotted integers with an optional pre-release suffix.
/// `v1.2.3`, `1.2`, `1.2.3-beta.1` and `1.2.3+45` all parse; build metadata is ignored.
struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let numbers: [Int]
    let prerelease: String?

    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        if let plus = body.firstIndex(of: "+") { body = String(body[..<plus]) }
        var prerelease: String?
        if let dash = body.firstIndex(of: "-") {
            prerelease = String(body[body.index(after: dash)...])
            body = String(body[..<dash])
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        self.numbers = numbers
        self.prerelease = prerelease.flatMap { $0.isEmpty ? nil : $0 }
    }

    var description: String {
        let base = numbers.map(String.init).joined(separator: ".")
        return prerelease.map { "\(base)-\($0)" } ?? base
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<width {
            let l = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let r = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if l != r { return l < r }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true   // 1.0.0-beta < 1.0.0
        case (nil, .some): return false
        case let (.some(l), .some(r)): return l.compare(r, options: .numeric) == .orderedAscending
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    /// `CFBundleShortVersionString` of the running app, `0.0.0` when unbundled.
    static let current: AppVersion = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
    }()

    static let currentBuild: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }()
}
