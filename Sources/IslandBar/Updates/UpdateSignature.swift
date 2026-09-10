import CryptoKit
import Foundation

/// Ed25519 verification of update archives.
///
/// Releases are signed offline with `Tools/update-signing.swift` (see `Scripts/release.sh`);
/// the matching public key is compiled in here. HTTPS protects the transport, this
/// protects against a compromised download host or GitHub account.
enum UpdateSignature {
    /// Base64 raw Ed25519 public key the release script signs with. Rotating it means the
    /// new key must be compiled in and shipped before it is used to sign anything.
    static let publicKeyBase64 = "h4YZOm9tWYGjCWFSYWDNbBrZv9vPcwhKNgx0bCTFN9M="

    /// Previously trusted keys, so a build that shipped before a rotation still installs
    /// releases signed by the successor key. An archive is accepted when any key here
    /// verifies it; the release script still only signs with `publicKeyBase64`.
    static let legacyPublicKeysBase64: [String] = [
        "/XmaQJJDoRnyv8lAJkEN9zVyxrzwpGVMNo/rPcj6nIk=",
    ]

    enum Failure: LocalizedError {
        case badPublicKey
        case unreadableSignature
        case invalid

        var errorDescription: String? {
            switch self {
            case .badPublicKey: "The built-in update key is malformed."
            case .unreadableSignature: "The signature file could not be read."
            case .invalid: "The downloaded update failed signature verification and was discarded."
            }
        }
    }

    static func verify(archive: URL, signatureFile: URL) throws {
        // Debug builds can point at a test key; release archives always use the built-in ones.
        let keys = ProcessInfo.processInfo.environment["ISLANDBAR_UPDATE_PUBLIC_KEY"]
            .map { [$0] } ?? ([publicKeyBase64] + legacyPublicKeysBase64)
        let publicKeys = keys.compactMap { text -> Curve25519.Signing.PublicKey? in
            guard let raw = Data(base64Encoded: text) else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
        guard !publicKeys.isEmpty else { throw Failure.badPublicKey }
        guard let text = try? String(contentsOf: signatureFile, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw Failure.unreadableSignature }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard publicKeys.contains(where: { $0.isValidSignature(signature, for: data) }) else {
            throw Failure.invalid
        }
    }
}
