import Foundation
import GlintCore
import Testing

@testable import GlintLicensing

@MainActor
@Suite("License manager")
struct LicenseManagerTests {
    let keys = TestKeys()
    let clock = TestClock()
    let store = InMemorySecureStore()

    func manager(service: (any ActivationService)? = nil) -> LicenseManager {
        LicenseManager(verifier: keys.verifier, store: store, activationService: service, now: clock.provider)
    }

    @Test func firstLaunchStartsTrial() {
        let manager = manager()
        #expect(manager.state == .none)
        #expect(manager.entitlements.canStartTrial)
        #expect(manager.startTrialIfNeeded())
        #expect(manager.entitlements.trialDaysLeft == 14)
        #expect(manager.entitlements.isPro)
        #expect(!manager.startTrialIfNeeded())
    }

    @Test func expiredTrialFallsBackToFree() {
        let manager = manager()
        manager.startTrialIfNeeded()
        clock.advance(days: 15)
        manager.refresh()
        #expect(manager.state == .trialExpired)
        #expect(manager.entitlements.snapshot == .free)
    }

    @Test func devFallbackAcceptsSignedKeyWithoutServer() async throws {
        let manager = manager()
        var changes: [Entitlements] = []
        manager.onChange = { changes.append($0) }
        try await manager.activate(key: try keys.key())
        #expect(manager.entitlements.isLicensed)
        #expect(manager.entitlements.snapshot == .pro)
        #expect(changes.last?.isPro == true)

        let relaunched = self.manager()
        #expect(relaunched.entitlements.isLicensed)
    }

    @Test func invalidKeyLeavesStateAndReportsError() async {
        let manager = manager()
        manager.startTrialIfNeeded()
        await #expect(throws: LicenseError.invalidKey) { try await manager.activate(key: "nope") }
        #expect(manager.lastError == .invalidKey)
        #expect(manager.entitlements.isTrial)
    }

    @Test func serverActivationStoresBoundToken() async throws {
        let service = FakeActivationService(signer: keys.signer)
        let manager = manager(service: service)
        try await manager.activate(key: try keys.key())
        #expect(service.calls == ["activate"])
        #expect(manager.entitlements.license?.kind == .activation)
        #expect(manager.entitlements.license?.installID == manager.installID)
    }

    @Test func storedKeyWithoutActivationIsRejectedOnceServerExists() async throws {
        try await manager().activate(key: try keys.key())
        let withServer = manager(service: FakeActivationService(signer: keys.signer))
        #expect(!withServer.entitlements.isLicensed)
    }

    @Test func seatLimitReached() async throws {
        let service = FakeActivationService(signer: keys.signer)
        service.activateBehavior = .fail(.seatLimitReached)
        let manager = manager(service: service)
        await #expect(throws: LicenseError.seatLimitReached) { try await manager.activate(key: try keys.key()) }
        #expect(manager.state == .seatLimitReached)
        #expect(!manager.entitlements.isPro)

        service.activateBehavior = .succeed
        try await manager.activate(key: try keys.key())
        #expect(manager.entitlements.isLicensed)
    }

    @Test func seatLimitDuringTrialKeepsTrial() async throws {
        let service = FakeActivationService(signer: keys.signer)
        service.activateBehavior = .fail(.seatLimitReached)
        let manager = manager(service: service)
        manager.startTrialIfNeeded()
        await #expect(throws: LicenseError.seatLimitReached) { try await manager.activate(key: try keys.key()) }
        #expect(manager.entitlements.isTrial)
        #expect(manager.lastError == .seatLimitReached)
    }

    @Test func revalidationIsWeeklyAndDetectsRevocation() async throws {
        let service = FakeActivationService(signer: keys.signer)
        let manager = manager(service: service)
        try await manager.activate(key: try keys.key())

        clock.advance(days: 3)
        await manager.revalidateIfNeeded()
        #expect(service.calls == ["activate"])

        clock.advance(days: 5)
        service.validateResult = .success(true)
        await manager.revalidateIfNeeded()
        #expect(service.calls == ["activate", "validate"])
        #expect(manager.state == .revoked)
        #expect(manager.entitlements.snapshot == .free)
    }

    @Test func offlineRevalidationIsIgnored() async throws {
        let service = FakeActivationService(signer: keys.signer)
        service.validateResult = .failure(.network)
        let manager = manager(service: service)
        try await manager.activate(key: try keys.key())
        clock.advance(days: 30)
        await manager.revalidateIfNeeded()
        #expect(manager.entitlements.isLicensed)
        await manager.revalidateIfNeeded()
        #expect(service.calls.filter { $0 == "validate" }.count == 2)
    }

    @Test func revokedKeyFromServerSetsRevoked() async throws {
        let service = FakeActivationService(signer: keys.signer)
        service.activateBehavior = .fail(.revoked)
        let manager = manager(service: service)
        await #expect(throws: LicenseError.revoked) { try await manager.activate(key: try keys.key()) }
        #expect(manager.state == .revoked)
    }

    @Test func deactivateFreesSeatAndReturnsToTrial() async throws {
        let service = FakeActivationService(signer: keys.signer)
        let manager = manager(service: service)
        manager.startTrialIfNeeded()
        try await manager.activate(key: try keys.key())
        #expect(manager.entitlements.canDeactivate)
        try await manager.deactivate()
        #expect(service.calls == ["activate", "deactivate"])
        #expect(manager.entitlements.isTrial)
    }

    @Test func deepLinkActivates() async throws {
        let manager = manager()
        let key = try keys.key()
        var components = URLComponents()
        components.scheme = "glint"
        components.host = "activate"
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        let url = try #require(components.url)
        #expect(await manager.handle(url: url))
        #expect(manager.entitlements.isLicensed)
        #expect(await !manager.handle(url: try #require(URL(string: "glint://search?q=x"))))
    }

    @Test(
        arguments: [
            ("glint://activate?key=GLINT1-abc.def", "GLINT1-abc.def"),
            ("GLINT://Activate?key=K", "K"),
            ("glint://activate", nil),
            ("glint://activate?key=", nil),
            ("https://activate?key=K", nil),
            ("glint://open?key=K", nil),
        ] as [(String, String?)])
    func parsesDeepLinks(url: String, expected: String?) throws {
        #expect(LicenseManager.activationKey(from: try #require(URL(string: url))) == expected)
    }

    @Test func installIDIsStable() {
        let manager = manager()
        #expect(manager.installID == manager.installID)
        #expect(UUID(uuidString: manager.installID) != nil)
    }
}

@Suite("Entitlements")
struct EntitlementsTests {
    static let payload = LicensePayload(licenseID: "l", issuedAt: Date(), emailHash: "h")

    @Test(arguments: [
        (LicenseState.none, false),
        (.trial(daysLeft: 3, endsAt: Date()), true),
        (.trialExpired, false),
        (.active(payload), true),
        (.revoked, false),
        (.seatLimitReached, false),
    ])
    func mapsStateToGate(state: LicenseState, isPro: Bool) {
        let entitlements = Entitlements(state: state)
        #expect(entitlements.isPro == isPro)
        #expect(entitlements.snapshot == (isPro ? .pro : .free))
        #expect(entitlements.allows(.videoSearch) == isPro)
        #expect(entitlements.allows(MediaKind.audio) == isPro)
        #expect(entitlements.allows(MediaKind.image))
        #expect(entitlements.canDeactivate == (state == .active(Self.payload)))
        #expect(entitlements.showsUpgrade == !entitlements.isLicensed)
        #expect(entitlements.canStartTrial == (state == LicenseState.none))
    }
}
