// Ed25519 signing for IslandBar update archives. Runs with the Command Line Tools:
//
//   swift Tools/update-signing.swift keygen <private-key-file>
//       Creates a new key (mode 0600) and prints the base64 public key to embed in
//       Sources/IslandBar/Updates/UpdateSignature.swift.
//   swift Tools/update-signing.swift pubkey <private-key-file>
//       Prints the base64 public key for an existing private key.
//   swift Tools/update-signing.swift sign <private-key-file> <archive>
//       Prints the base64 signature of the archive bytes.
//   swift Tools/update-signing.swift verify <public-key-base64> <archive> <signature-file>
//       Exits 0 when the signature is valid.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadPrivateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("cannot read Ed25519 private key at \(path)") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: update-signing.swift keygen|pubkey|sign|verify …")
}

switch command {
case "keygen":
    guard args.count == 2 else { fail("usage: keygen <private-key-file>") }
    let path = args[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("refusing to overwrite \(path)") }
    let key = Curve25519.Signing.PrivateKey()
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let ok = FileManager.default.createFile(
        atPath: path,
        contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
        attributes: [.posixPermissions: 0o600]
    )
    guard ok else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "pubkey":
    guard args.count == 2 else { fail("usage: pubkey <private-key-file>") }
    print(loadPrivateKey(args[1]).publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 3 else { fail("usage: sign <private-key-file> <archive>") }
    let key = loadPrivateKey(args[1])
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())

case "verify":
    guard args.count == 4 else { fail("usage: verify <public-key-base64> <archive> <signature-file>") }
    guard let raw = Data(base64Encoded: args[1]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("bad public key") }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
    guard let sigText = try? String(contentsOfFile: args[3], encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("cannot read signature \(args[3])") }
    guard publicKey.isValidSignature(signature, for: data) else { fail("INVALID signature") }
    print("valid")

default:
    fail("unknown command \(command)")
}
