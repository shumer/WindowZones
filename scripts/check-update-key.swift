import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
guard let encoded = environment["SPARKLE_PRIVATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let secret = Data(base64Encoded: encoded), [32, 96].contains(secret.count) else {
    fail("Sparkle private key must be a 32-byte seed or a 96-byte legacy key.")
}
// Sparkle 2.10 common_cli/Secret.swift defines both supported export formats.
let publicData: Data
if secret.count == 32 {
    publicData = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
} else {
    publicData = secret.suffix(32)
}
if let expected = environment["SU_PUBLIC_ED_KEY"], !expected.isEmpty,
   Data(base64Encoded: expected) != publicData {
    fail("Sparkle public key does not match the configured key.")
}
let toolDirectory = environment["SPARKLE_BIN_DIR"] ?? ".build/artifacts/sparkle/Sparkle/bin"
let tool = URL(fileURLWithPath: toolDirectory).appendingPathComponent("sign_update")
guard FileManager.default.isExecutableFile(atPath: tool.path) else {
    fail("Sparkle sign_update is missing. Resolve Swift package dependencies first.")
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("windowzones-key-check-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let challenge = Data(("WindowZones key verification " + UUID().uuidString).utf8)
let challengeFile = directory.appendingPathComponent("challenge.bin")
try challenge.write(to: challengeFile)
let process = Process()
let input = Pipe()
let output = Pipe()
process.executableURL = tool
process.arguments = ["--ed-key-file", "-", "-p", challengeFile.path]
process.standardInput = input
process.standardOutput = output
// Suppress tool errors because malformed key errors can contain secret text.
process.standardError = FileHandle.nullDevice
try process.run()
try input.fileHandleForWriting.write(contentsOf: Data((encoded + "\n").utf8))
try input.fileHandleForWriting.close()
let signedOutput = output.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
guard process.terminationStatus == 0,
      let text = String(data: signedOutput, encoding: .utf8),
      let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      try Curve25519.Signing.PublicKey(rawRepresentation: publicData).isValidSignature(signature, for: challenge) else {
    fail("Sparkle could not sign and verify the challenge with this key.")
}
if CommandLine.arguments.contains("--print-public-key") {
    print(publicData.base64EncodedString())
} else {
    print("Sparkle update key verified.")
}
