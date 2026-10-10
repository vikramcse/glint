import Foundation
import Testing

@testable import GlintLicensing

@Suite("License verification")
struct LicenseVerifierTests {
    let keys = TestKeys()

    @Test func validKeyRoundTrips() throws {
        let key = try keys.key()
        #expect(key.hasPrefix("GLINT1-"))
        let payload = try keys.verifier.verify(key, kind: .license)
        #expect(payload == keys.payload())
        #expect(payload.seats == 2)
        #expect(payload.emailHash.count == 64)
    }

    @Test func toleratesWhitespaceFromEmail() throws {
        let key = try keys.key()
        let wrapped = "  " + key.prefix(40) + "\n" + key.dropFirst(40) + " \n"
        #expect(try keys.verifier.verify(wrapped) == keys.payload())
    }

    @Test func rejectsTamperedPayload() throws {
        let key = try keys.key()
        let parts = try #require(LicenseTokenCodec.split(key))
        var payload = try LicenseTokenCodec.decodePayload(parts.payload)
        payload.seats = 100
        let forged = LicenseTokenCodec.token(payload: try LicenseTokenCodec.encodePayload(payload), signature: parts.signature)
        #expect(throws: LicenseError.tampered) { try keys.verifier.verify(forged) }
    }

    @Test func rejectsKeyFromAnotherSigner() throws {
        let other = TestKeys()
        #expect(throws: LicenseError.tampered) { try keys.verifier.verify(try other.key()) }
    }

    @Test(arguments: ["", "hello", "GLINT1-", "GLINT1-abc", "GLINT1-a.b.c", "GLINT2-abc.def"])
    func rejectsMalformedKeys(_ text: String) {
        #expect(throws: LicenseError.invalidKey) { try keys.verifier.verify(text) }
    }

    @Test func rejectsWrongProduct() throws {
        #expect(throws: LicenseError.wrongProduct) { try keys.verifier.verify(try keys.key(product: "other-app")) }
    }

    @Test func rejectsWrongMajorVersion() throws {
        #expect(throws: LicenseError.wrongVersion) { try keys.verifier.verify(try keys.key(major: 2)) }
    }

    @Test func rejectsWrongKind() throws {
        #expect(throws: LicenseError.invalidKey) { try keys.verifier.verify(try keys.key(), kind: .activation) }
    }

    @Test func activationIsBoundToInstall() throws {
        let activation = try keys.signer.sign(keys.payload().activation(for: "install-A", at: Date()))
        #expect(try keys.verifier.verify(activation, kind: .activation, installID: "install-A").installID == "install-A")
        #expect(throws: LicenseError.wrongDevice) {
            try keys.verifier.verify(activation, installID: "install-B")
        }
    }

    @Test func productionKeyLoadsAndVerifiesQuickly() throws {
        let verifier = try LicenseVerifier.production()
        #expect(throws: LicenseError.tampered) { try verifier.verify(try keys.key()) }

        let key = try keys.key()
        let fast = keys.verifier
        _ = try fast.verify(key)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<100 { _ = try fast.verify(key) }
        let perCall = (clock.now - start) / 100
        #expect(perCall < .milliseconds(1))
    }

    @Test func emailHashNormalizes() {
        #expect(LicensePayload.hashEmail(" Buyer@Example.COM ") == LicensePayload.hashEmail("buyer@example.com"))
    }

    @Test func base64URLRoundTrips() throws {
        for length in 0..<10 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 77 + 250) })
            let encoded = data.base64URLEncodedString()
            #expect(!encoded.contains("=") && !encoded.contains("+") && !encoded.contains("/"))
            #expect(Data(base64URLEncoded: encoded) == data)
        }
    }
}

@Suite("Trial clock")
struct TrialClockTests {
    @Test func notStartedUntilStarted() throws {
        let trial = TrialClock(store: InMemorySecureStore(), now: TestClock().provider)
        #expect(try trial.status() == .notStarted)
        #expect(try trial.startIfNeeded())
        #expect(try !trial.startIfNeeded())
    }

    @Test func runsFourteenDaysThenExpires() throws {
        let clock = TestClock()
        let trial = TrialClock(store: InMemorySecureStore(), now: clock.provider)
        try trial.startIfNeeded()
        guard case .active(let daysLeft, let endsAt) = try trial.status() else {
            Issue.record("expected active trial")
            return
        }
        #expect(daysLeft == 14)
        #expect(endsAt == clock.now.addingTimeInterval(TrialClock.length))
        clock.advance(days: 13.5)
        #expect(try trial.status() == .active(daysLeft: 1, endsAt: endsAt))
        clock.advance(days: 0.6)
        #expect(try trial.status() == .expired)
    }

    @Test func clockRollbackDoesNotExtendTrial() throws {
        let clock = TestClock()
        let store = InMemorySecureStore()
        let trial = TrialClock(store: store, now: clock.provider)
        try trial.startIfNeeded()
        clock.advance(days: 10)
        _ = try trial.status()
        clock.advance(days: -9)
        guard case .active(let daysLeft, _) = try trial.status() else {
            Issue.record("expected active trial")
            return
        }
        #expect(daysLeft == 4)
        // Back to the real date and past the end: the trial ends on schedule.
        clock.advance(days: 14)
        #expect(try trial.status() == .expired)
    }
}
