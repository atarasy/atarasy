import XCTest
import AuthenticationServices
@testable import AtarasyCore

func capturedCeremony(_ name: String) throws -> MemberCeremony {
    let url = Bundle.module.url(forResource: "member-auth-responses", withExtension: "json", subdirectory: "Fixtures")!
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let cases = root["cases"] as! [String: [String: Any]]
    return try JSONDecoder().decode(MemberCeremony.self, from: JSONSerialization.data(withJSONObject: cases[name]!["value"]!))
}
@MainActor final class NativePasskeyTests: XCTestCase {
    let environment = try! MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!)
    func testCanonicalByteRoundtripAndRefusal() throws {
        let bytes = Data(0...255)
        XCTAssertEqual(try PasskeyBytes.decode(PasskeyBytes.encode(bytes)), bytes)
        for invalid in ["", "AA=", "AA\n", "A+", "A/", "A", "AB", " "] {
            XCTAssertThrowsError(try PasskeyBytes.decode(invalid), invalid)
        }
        XCTAssertThrowsError(try PasskeyBytes.decode("AAAA", maximum: 2))
        XCTAssertThrowsError(try PasskeyBytes.decode("AA", maximum: Int.max))
    }
    func testCapturedRegistrationCreatesActualPlatformRequest() throws {
        let ceremony = try capturedCeremony("registration-options")
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .registration, now: 1000)
        let request = try XCTUnwrap(options.request() as? ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest)
        XCTAssertEqual(request.relyingPartyIdentifier, "unit.example")
        XCTAssertEqual(request.challenge, options.challenge)
        XCTAssertEqual(request.userID, options.userID)
        XCTAssertEqual(request.name, "member-Wz8TECGA")
        XCTAssertEqual(request.userVerificationPreference, .required)
        XCTAssertEqual(request.attestationPreference, .none)
    }
    func testCapturedAssertionCreatesActualPlatformRequest() throws {
        let options = try NativePasskeyOptions(ceremony: capturedCeremony("login-options"), environment: environment, kind: .assertion, now: 1000)
        let request = try XCTUnwrap(options.request() as? ASAuthorizationPlatformPublicKeyCredentialAssertionRequest)
        XCTAssertEqual(request.relyingPartyIdentifier, "unit.example")
        XCTAssertEqual(request.challenge.count, 32)
        XCTAssertEqual(request.userVerificationPreference, .required)
        XCTAssertTrue(request.allowedCredentials.isEmpty)
    }
    func testExpiredForeignAndNoncanonicalChallengeRefusedBeforePresentation() throws {
        let ceremony = try capturedCeremony("login-options")
        XCTAssertThrowsError(try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .assertion, now: 2000))
        let other = try MemberEnvironment(name: "test", origin: URL(string: "https://elsewhere.example")!)
        XCTAssertThrowsError(try NativePasskeyOptions(ceremony: ceremony, environment: other, kind: .assertion, now: 1000))
        for change in [["challenge": MemberJSON.string(String(repeating: "A", count: 42) + "B")], ["userVerification": .string("preferred")], ["allowCredentials": .array([.object([:])])]] {
            var p = ceremony.publicKey; p.merge(change) { _,new in new }
            let altered = MemberCeremony(id: ceremony.id, expiresAt: ceremony.expiresAt, publicKey: p)
            XCTAssertThrowsError(try NativePasskeyOptions(ceremony: altered, environment: environment, kind: .assertion, now: 1000))
        }
    }
    func testRegistrationPolicyAndHandleCannotBeWeakened() throws {
        let ceremony = try capturedCeremony("registration-options")
        let changes: [[String: MemberJSON]] = [
            ["user": .object(["id": .string("AA="), "name": .string("member")])],
            ["excludeCredentials": .array([.object([:])])],
            ["attestation": .string("direct")],
            ["pubKeyCredParams": .array([.object(["type": .string("public-key"), "alg": .integer(-257)])])],
            ["authenticatorSelection": .object(["residentKey": .string("preferred"), "userVerification": .string("required")])]
        ]
        for change in changes {
            var p = ceremony.publicKey; p.merge(change) { _,new in new }
            XCTAssertThrowsError(try NativePasskeyOptions(ceremony: MemberCeremony(id: ceremony.id, expiresAt: 2000, publicKey: p), environment: environment, kind: .registration, now: 1000))
        }
    }
    func testMissingWindowDoesNotPresentSystemUI() async throws {
        let adapter = NativePasskeyAuthoriser(environment: environment, anchor: { nil }, now: { 1000 })
        do { _ = try await adapter.authorise(capturedCeremony("login-options"), kind: .assertion); XCTFail() }
        catch { XCTAssertEqual(error as? NativePasskeyFailure, .unavailable) }
    }
}

@MainActor private final class AccountService: MemberAccountService {
    var calls: [String] = []
    var failure: MemberFailure?
    var holdLogin = false
    var waiting: CheckedContinuation<MemberSessionInfo, Error>?
    var holdObserved: CheckedContinuation<Void, Never>?
    func waitForHeldLogin() async {
        if waiting != nil { return }
        await withCheckedContinuation { holdObserved = $0 }
    }
    let info = MemberSessionInfo(id: "session", household: "server-household", presenters: ["merchant"], expiresAt: 5000)
    func registrationOptions(invitation: String) async throws -> MemberCeremony { calls.append("registration-options"); return try capturedCeremony("registration-options") }
    func loginOptions() async throws -> MemberCeremony { calls.append("login-options"); return try capturedCeremony("login-options") }
    func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws { calls.append("register"); if let failure { throw failure } }
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo {
        calls.append("login")
        if holdLogin { return try await withCheckedThrowingContinuation { waiting = $0; holdObserved?.resume(); holdObserved = nil } }
        if let failure { throw failure }; return info
    }
    func restore(household: String) async throws -> MemberSessionInfo? { calls.append("restore:" + household); if let failure { throw failure }; return info }
    func offers(presenter: String) async throws -> [MemberOfferSummary] { [] }
    func logout() async throws -> MemberLogoutOutcome { calls.append("logout"); if let failure { throw failure }; return .revoked }
}
@MainActor private final class AccountPasskeys: MemberPasskeyAuthorising {
    var fail: NativePasskeyFailure?
    var kinds: [NativePasskeyOptions.Kind] = []
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        kinds.append(kind); if let fail { throw fail }
        return .assertion(id: "test", clientDataJSON: "test", authenticatorData: "test", signature: "test", userHandle: "test")
    }
}
@MainActor final class MemberAccountTests: XCTestCase {
    func testRegistrationDoesNotCreateSessionAndLoginUsesServerHousehold() async {
        let service = AccountService(), passkeys = AccountPasskeys()
        let model = MemberAccount(service: service, passkeys: passkeys)
        await model.enrol(invitation: "test invitation")
        XCTAssertNil(model.session); XCTAssertTrue(model.notice.contains("registered"))
        await model.signIn()
        XCTAssertEqual(model.session?.household, "server-household")
        XCTAssertEqual(service.calls, ["registration-options", "register", "login-options", "login"])
        XCTAssertEqual(passkeys.kinds.count, 2)
    }
    func testProposalExpiryAlsoClearsAccount() async {
        let model = MemberAccount(service: AccountService(), passkeys: AccountPasskeys())
        await model.signIn()
        XCTAssertNotNil(model.proposals.sessionIdentity)
        // The fixture expires at 5 seconds after the epoch; the live screen clock rejects it.
        await model.proposals.refresh()
        XCTAssertNil(model.session); XCTAssertNil(model.proposals.sessionIdentity)
        XCTAssertTrue(model.notice.contains("no longer available"))
    }
    func testCancelAndPlatformFailureNeverSubmitVerification() async {
        for error in [NativePasskeyFailure.cancelled, .unavailable] {
            let service = AccountService(), passkeys = AccountPasskeys(); passkeys.fail = error
            let model = MemberAccount(service: service, passkeys: passkeys)
            await model.signIn(); XCTAssertEqual(service.calls, ["login-options"]); XCTAssertNil(model.session)
            if error == .cancelled { XCTAssertTrue(model.notice.contains("cancelled")) }
            else { XCTAssertFalse(model.notice.contains("cancelled")) }
            XCTAssertFalse(model.busy)
        }
    }
    func testUncertainVerificationIsNotRetriedOrShownAsCancellation() async {
        let service = AccountService(); service.failure = .uncertainVerification
        let model = MemberAccount(service: service, passkeys: AccountPasskeys())
        await model.signIn()
        XCTAssertEqual(service.calls, ["login-options", "login"])
        XCTAssertNil(model.session); XCTAssertTrue(model.notice.contains("could not be confirmed"))
        XCTAssertFalse(model.notice.contains("cancelled"))
    }
    func testLogoutClearsVisibleSessionEvenWhenRemoteResultLost() async {
        let service = AccountService()
        let active = MemberAccount(service: service, passkeys: AccountPasskeys())
        await active.signIn(); service.failure = .remoteLogoutUnconfirmed; await active.signOut()
        XCTAssertNil(active.session); XCTAssertTrue(active.notice.contains("Server revocation could not be confirmed"))
    }
    func testRestoreFailureAndExpiryHideSession() async {
        let service = AccountService(), passkeys = AccountPasskeys()
        let model = MemberAccount(service: service, passkeys: passkeys)
        await model.restore(household: "lookup-only")
        XCTAssertEqual(model.session?.household, "server-household")
        model.clearExpired(now: 5000); XCTAssertNil(model.session)
        service.failure = .http(401); await model.restore(household: "lookup-only")
        XCTAssertNil(model.session); XCTAssertTrue(passkeys.kinds.isEmpty)
    }
    func testConcurrentActionAndLateResultAfterClose() async {
        let service = AccountService(); service.holdLogin = true
        let model = MemberAccount(service: service, passkeys: AccountPasskeys())
        let first = Task { await model.signIn() }
        await service.waitForHeldLogin()
        XCTAssertNotNil(service.waiting)
        await model.signIn(); XCTAssertEqual(service.calls, ["login-options", "login"])
        model.close(); service.waiting?.resume(returning: service.info); service.waiting = nil
        await first.value
        XCTAssertNil(model.session); XCTAssertEqual(model.notice, ""); XCTAssertFalse(model.busy)
    }
}

extension NativePasskeyTests {
    func testStatementRequestUsesOnlySelectedCredentialAndDoesNotWidenLogin() throws {
        let url = Bundle.module.url(forResource: "member-operation-runtime", withExtension: "json", subdirectory: "Fixtures")!
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let prepared = try JSONDecoder().decode(MemberPreparedOperation.self, from: JSONSerialization.data(withJSONObject: root["prepared"]!))
        let ceremony = MemberCeremony(id: prepared.operationID, expiresAt: prepared.expiresAt, publicKey: prepared.publicKey)
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .statement, now: 1_800_000_000_003)
        let request = try XCTUnwrap(options.request() as? ASAuthorizationPlatformPublicKeyCredentialAssertionRequest)
        XCTAssertEqual(request.allowedCredentials.map(\.credentialID), options.allowedCredentialIDs)
        XCTAssertEqual(request.allowedCredentials.count, 1); XCTAssertEqual(request.userVerificationPreference, .required)
        XCTAssertThrowsError(try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .assertion, now: 1_800_000_000_003))
        var key = ceremony.publicKey; key["allowCredentials"] = .array([])
        XCTAssertThrowsError(try NativePasskeyOptions(ceremony: MemberCeremony(id: ceremony.id, expiresAt: ceremony.expiresAt, publicKey: key), environment: environment, kind: .statement, now: 1_800_000_000_003))
    }
}
