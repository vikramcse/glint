import CryptoKit
import Foundation

@testable import GlintLicensing

/// A clock tests can move forwards and backwards.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(days: Double) {
        lock.withLock { current = current.addingTimeInterval(days * 86_400) }
    }

    var provider: @Sendable () -> Date { { [self] in now } }
}

/// Fresh keypair per test plus helpers to mint tokens.
struct TestKeys {
    let signer = LicenseSigner(privateKey: Curve25519.Signing.PrivateKey())
    var verifier: LicenseVerifier { LicenseVerifier(publicKey: signer.publicKey) }

    func payload(
        product: String = LicensePayload.currentProduct,
        major: Int = LicensePayload.currentMajorVersion
    ) -> LicensePayload {
        LicensePayload(
            licenseID: "lic-1", product: product, majorVersion: major,
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
            emailHash: LicensePayload.hashEmail("buyer@example.com")
        )
    }

    func key(product: String = LicensePayload.currentProduct, major: Int = LicensePayload.currentMajorVersion) throws -> String {
        try signer.sign(payload(product: product, major: major))
    }
}

/// Scriptable license server.
final class FakeActivationService: ActivationService, @unchecked Sendable {
    enum Behavior {
        case succeed
        case fail(LicenseError)
    }

    private let lock = NSLock()
    private let signer: LicenseSigner
    private var _activateBehavior: Behavior = .succeed
    private var _validateResult: Result<Bool, LicenseError> = .success(false)
    private var _calls: [String] = []

    init(signer: LicenseSigner) { self.signer = signer }

    var activateBehavior: Behavior {
        get { lock.withLock { _activateBehavior } }
        set { lock.withLock { _activateBehavior = newValue } }
    }

    var validateResult: Result<Bool, LicenseError> {
        get { lock.withLock { _validateResult } }
        set { lock.withLock { _validateResult = newValue } }
    }

    var calls: [String] { lock.withLock { _calls } }

    func activate(key: String, installID: String) async throws -> String {
        lock.withLock { _calls.append("activate") }
        switch activateBehavior {
        case .fail(let error): throw error
        case .succeed:
            let license = try LicenseVerifier(publicKey: signer.publicKey).verify(key, kind: .license)
            return try signer.sign(license.activation(for: installID, at: Date()))
        }
    }

    func deactivate(activationToken: String, installID: String) async throws {
        lock.withLock { _calls.append("deactivate") }
    }

    func isRevoked(activationToken: String) async throws -> Bool {
        lock.withLock { _calls.append("validate") }
        return try validateResult.get()
    }
}
