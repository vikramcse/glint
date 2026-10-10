// glint-license — developer tool for issuing and checking Glint license keys.
//
//   glint-license keygen
//   glint-license issue --email buyer@example.com [--seats 2] [--license-id ID] [--private-key PATH]
//   glint-license activate --key GLINT1-… --install-id UUID [--private-key PATH]
//   glint-license verify --key GLINT1-… [--install-id UUID] [--public-key BASE64]
//
// The default private key path is `secrets/license-dev-private.key` (gitignored). The
// production key lives only on the license server.

import CryptoKit
import Foundation
import GlintLicensing

enum ToolError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): message
        }
    }
}

let usage = """
    usage:
      glint-license keygen
      glint-license issue --email EMAIL [--seats N] [--license-id ID] [--private-key PATH]
      glint-license activate --key KEY --install-id UUID [--private-key PATH]
      glint-license verify --key KEY [--install-id UUID] [--public-key BASE64]
    """

func options(from arguments: ArraySlice<String>) throws -> [String: String] {
    var result: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let flag = iterator.next() {
        guard flag.hasPrefix("--"), let value = iterator.next() else {
            throw ToolError.usage("unexpected argument \(flag)\n\(usage)")
        }
        result[String(flag.dropFirst(2))] = value
    }
    return result
}

func require(_ name: String, in options: [String: String]) throws -> String {
    guard let value = options[name], !value.isEmpty else { throw ToolError.usage("missing --\(name)\n\(usage)") }
    return value
}

func signer(_ options: [String: String]) throws -> LicenseSigner {
    let path = options["private-key"] ?? "secrets/license-dev-private.key"
    let base64 = try String(contentsOfFile: path, encoding: .utf8)
    return try LicenseSigner(privateKeyBase64: base64)
}

func printJSON(_ payload: LicensePayload) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(payload), as: UTF8.self))
}

func run(_ arguments: [String]) throws {
    guard let command = arguments.dropFirst().first else { throw ToolError.usage(usage) }
    let opts = try options(from: arguments.dropFirst(2))
    switch command {
    case "keygen":
        let key = Curve25519.Signing.PrivateKey()
        print("private: \(key.rawRepresentation.base64EncodedString())")
        print("public:  \(key.publicKey.rawRepresentation.base64EncodedString())")
    case "issue":
        let email = try require("email", in: opts)
        let seats = Int(opts["seats"] ?? "") ?? LicensePayload.defaultSeats
        let payload = LicensePayload(
            licenseID: opts["license-id"] ?? UUID().uuidString.lowercased(),
            seats: seats,
            issuedAt: Date(),
            emailHash: LicensePayload.hashEmail(email)
        )
        print(try signer(opts).sign(payload))
    case "activate":
        let key = try require("key", in: opts)
        let installID = try require("install-id", in: opts)
        let signer = try signer(opts)
        let license = try LicenseVerifier(publicKey: signer.publicKey).verify(key, kind: .license)
        print(try signer.sign(license.activation(for: installID, at: Date())))
    case "verify":
        let key = try require("key", in: opts)
        let verifier = try opts["public-key"].map(LicenseVerifier.init(publicKeyBase64:)) ?? LicenseVerifier.production()
        let clock = ContinuousClock()
        let start = clock.now
        let payload = try verifier.verify(key, installID: opts["install-id"])
        let elapsed = clock.now - start
        try printJSON(payload)
        print("verified in \(elapsed)")
    default:
        throw ToolError.usage(usage)
    }
}

do {
    try run(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
