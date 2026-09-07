import CryptoKit
import Foundation

/// Ed25519 verification of update archives.
///
/// Releases are signed offline with `Tools/update-signing.swift` (see `Scripts/release.sh`);
/// the matching public key is compiled in here. HTTPS protects the transport, this
/// protects against a compromised download host or GitHub account.
enum UpdateSignature {
    /// Base64 raw Ed25519 public key. Rotating it requires shipping a new build by hand.
    static let publicKeyBase64 = "/XmaQJJDoRnyv8lAJkEN9zVyxrzwpGVMNo/rPcj6nIk="

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
        // Debug builds can point at a test key; release archives always use the built-in one.
        let keyText = ProcessInfo.processInfo.environment["ISLANDBAR_UPDATE_PUBLIC_KEY"] ?? publicKeyBase64
        guard let raw = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { throw Failure.badPublicKey }
        guard let text = try? String(contentsOf: signatureFile, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw Failure.unreadableSignature }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: data) else { throw Failure.invalid }
    }
}
