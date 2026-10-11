import Foundation
import CryptoKit

// Verify a release with the installed public key and test rejection without installing it.
let arguments = CommandLine.arguments
if arguments.count != 4 {
    fputs("Usage: swift scripts/verify-update.swift Info.plist signature.txt archive.zip\n", stderr)
    exit(2)
}
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[1])), format: nil) as! [String: Any]
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: info["SUPublicEDKey"] as! String)!)
let signature = Data(base64Encoded: try String(contentsOfFile: arguments[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
precondition(!archive.isEmpty && key.isValidSignature(signature, for: archive), "Release signature rejected.")
var altered = archive
altered[altered.count / 2] ^= 1
precondition(!key.isValidSignature(signature, for: altered), "Corrupted archive accepted.")
precondition(!key.isValidSignature(signature, for: archive.prefix(archive.count / 2)), "Truncated archive accepted.")
let foreignKey = Curve25519.Signing.PrivateKey().publicKey
precondition(!foreignKey.isValidSignature(signature, for: archive), "Foreign key accepted.")
print("Release signature valid; corrupted, truncated and foreign-key archives rejected. No installation performed.")
