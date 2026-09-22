import Foundation
import XCTest
@testable import AtarasyCore

private final class LeaveVault: MemberSessionVault, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: StoredMemberSession] = [:]
    private func key(_ environment: MemberEnvironment, _ household: String) -> String { environment.origin.absoluteString + "|" + household }
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { lock.withLock { values[key(environment, household)] } }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws { lock.withLock { values[key(environment, session.info.household)] = session } }
    func remove(environment: MemberEnvironment, household: String) throws { _ = lock.withLock { values.removeValue(forKey: key(environment, household)) } }
}
private actor LeaveTransport: MemberHTTPTransport {
    struct Reply: Sendable { let status: Int; let data: Data }
    var replies: [Reply]; var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request); guard !replies.isEmpty else { throw MemberFailure.unavailable }; let reply = replies.removeFirst()
        return .init(url: request.url!, status: reply.status, contentType: "application/json", cacheControl: "no-store", data: reply.data)
    }
    func paths() -> [String] { requests.map { $0.url!.path } }
}

@MainActor final class LeaveTests: XCTestCase {
    private let household = "key:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let token = "amr1_" + String(repeating: "A", count: 43)
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func b64(_ data: Data) -> String { PasskeyBytes.encode(data) }
    private func environment() throws -> MemberEnvironment { try MemberEnvironment(name: "test", origin: URL(string: "https://leave.example")!) }
    private func leaveCeremony(_ origin: String) -> [String: Any] {
        ["profile": "atarasy.member-leave.1", "id": "22222222-2222-4222-8222-222222222222", "household": household,
         "origin": origin, "rpID": URL(string: origin)!.host!, "expiresAt": 2000,
         "digest": b64(Data(repeating: 9, count: 32)),
         "publicKey": ["challenge": b64(Data(repeating: 9, count: 32)), "rpId": URL(string: origin)!.host!, "timeout": 1000, "userVerification": "required", "allowCredentials": [["type": "public-key", "id": "YQ"]]]]
    }
    private func client(_ transport: LeaveTransport, _ vault: LeaveVault, _ environment: MemberEnvironment, session: MemberSessionInfo) async throws -> MemberClient {
        try vault.save(.init(token: token, info: session), environment: environment)
        let client = MemberClient(environment: environment, transport: transport, vault: vault, now: { 1000 })
        _ = try await client.restore(household: household)
        return client
    }

    // MARK: status

    func testStatusDecodesAnUnrecognisedBlockerKindWithoutDroppingIt() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let status: [String: Any] = ["profile": "atarasy.member-leave-status.1", "household": household, "blockers": [["kind": "a_kind_this_build_has_never_heard_of", "id": "row-1"], ["kind": "co_signer", "id": "key:other-household"]]]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(status))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        let value = try await client.leaveStatus()
        XCTAssertEqual(value.blockers.count, 2)
        XCTAssertEqual(value.blockers[0].kind, "a_kind_this_build_has_never_heard_of")
        XCTAssertEqual(value.blockers[0].id, "row-1")
        XCTAssertEqual(value.blockers[1].kind, "co_signer")
    }
    func testStatusForAnotherHouseholdIsRefused() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let status: [String: Any] = ["profile": "atarasy.member-leave-status.1", "household": "key:" + String(repeating: "B", count: 42) + "A", "blockers": []]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(status))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do { _ = try await client.leaveStatus(); XCTFail("Expected household mismatch refusal") } catch {}
    }
    func testStatusWithAnExtraKeyIsRefused() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let status: [String: Any] = ["profile": "atarasy.member-leave-status.1", "household": household, "blockers": [], "extra": true]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(status))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do { _ = try await client.leaveStatus(); XCTFail("Expected exact-key refusal") } catch {}
    }

    // MARK: prepare

    func testPrepareTwoHundredReturnsAReviewableCeremony() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let ceremony = leaveCeremony(env.origin.absoluteString)
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(ceremony))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        let prepared = try await client.prepareLeave()
        XCTAssertEqual(prepared.id, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(prepared.household, household)
        XCTAssertEqual(prepared.origin, env.origin.absoluteString)
        XCTAssertEqual(prepared.rpID, env.origin.host)
        XCTAssertEqual(prepared.ceremony.publicKey["challenge"], .string(prepared.digest))
        let paths = await transport.paths()
        XCTAssertEqual(paths, ["/auth/session", "/member/account/leave/prepare"])
    }
    func testPrepareFourOhNineCarriesTheBlockerListAsATypedError() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let blocked: [String: Any] = ["error": "leave_blocked", "blockers": [["kind": "offer_in_progress", "id": "offer-1"]]]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 409, data: try data(blocked))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do {
            _ = try await client.prepareLeave(); XCTFail("Expected leave_blocked")
        } catch MemberLeaveError.blocked(let blockers) {
            XCTAssertEqual(blockers, [.init(kind: "offer_in_progress", id: "offer-1")])
        }
    }
    func testPrepareRefusesAChallengeThatDoesNotMatchTheDigest() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        var ceremony = leaveCeremony(env.origin.absoluteString)
        var publicKey = ceremony["publicKey"] as! [String: Any]; publicKey["challenge"] = b64(Data(repeating: 1, count: 32)); ceremony["publicKey"] = publicKey
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(ceremony))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do { _ = try await client.prepareLeave(); XCTFail("Expected digest/challenge mismatch refusal") } catch {}
    }
    func testPrepareRefusesAForeignOrigin() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        var ceremony = leaveCeremony(env.origin.absoluteString); ceremony["origin"] = "https://elsewhere.example"
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(ceremony))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do { _ = try await client.prepareLeave(); XCTFail("Expected origin refusal") } catch {}
    }

    // MARK: submit

    func testSubmitDecodesTheReceiptAndRemovesTheLocalSession() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: ["merchant"], expiresAt: 5000)
        let ceremony = leaveCeremony(env.origin.absoluteString)
        let left: [String: Any] = ["profile": "atarasy.member-left.1", "household": household, "leftAt": 1500, "deleted": ["offers": 2, "privateRecords": 3]]
        let vault = LeaveVault()
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(ceremony)), .init(status: 200, data: try data(left))])
        let client = try await client(transport, vault, env, session: session)
        let prepared = try await client.prepareLeave()
        let assertion = MemberPasskeyResponse.assertion(id: "YQ", clientDataJSON: "Yg", authenticatorData: "Yw", signature: "ZA", userHandle: "ZQ")
        let result = try await client.leave(prepared, assertion: assertion)
        XCTAssertEqual(result.household, household); XCTAssertEqual(result.leftAt, 1500)
        // The saved session is gone: restoring it again finds nothing.
        XCTAssertNil(try vault.load(environment: env, household: household))
        // The in-memory active session is gone too: any further authenticated call is refused.
        do { _ = try await client.offers(presenter: "merchant"); XCTFail("Expected the session to be gone") }
        catch MemberFailure.expired {} catch MemberFailure.scopeMismatch {}
    }
    func testSubmitForAnotherHouseholdIsRefused() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let ceremony = leaveCeremony(env.origin.absoluteString)
        let left: [String: Any] = ["profile": "atarasy.member-left.1", "household": "key:" + String(repeating: "C", count: 42) + "A", "leftAt": 1500, "deleted": [:]]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(ceremony)), .init(status: 200, data: try data(left))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        let prepared = try await client.prepareLeave()
        let assertion = MemberPasskeyResponse.assertion(id: "YQ", clientDataJSON: "Yg", authenticatorData: "Yw", signature: "ZA", userHandle: "ZQ")
        do { _ = try await client.leave(prepared, assertion: assertion); XCTFail("Expected household mismatch refusal") } catch {}
    }

    // MARK: export

    func testExportKeepsNodeAndPrivateRecordsByteExact() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        // Hand-built, not run through JSONSerialization, so re-encoding could not
        // accidentally produce the same bytes: nested braces, a colon and a comma inside a
        // string value, and out-of-order keys relative to "node"/"privateRecords".
        let body = Data("""
        {"household":"\(household)","profile":"atarasy.member-export.1","exportedAt":1234,"node":{"a":1,"nested":{"b":"x:y, z"}},"privateRecords":[{"id":"r1","note":"a{b}c"},{"id":"r2"}]}
        """.utf8)
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: body)])
        let client = try await client(transport, LeaveVault(), env, session: session)
        let export = try await client.exportAccount()
        XCTAssertEqual(export.household, household); XCTAssertEqual(export.exportedAt, 1234)
        XCTAssertEqual(String(decoding: export.node, as: UTF8.self), #"{"a":1,"nested":{"b":"x:y, z"}}"#)
        XCTAssertEqual(String(decoding: export.privateRecords, as: UTF8.self), #"[{"id":"r1","note":"a{b}c"},{"id":"r2"}]"#)
        // The reassembled file embeds those same bytes verbatim and parses back to an
        // equivalent document.
        let reassembled = try export.fileContents()
        let parsedOriginal = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let parsedReassembled = try JSONSerialization.jsonObject(with: reassembled) as! [String: Any]
        XCTAssertEqual(parsedOriginal["household"] as? String, parsedReassembled["household"] as? String)
        XCTAssertEqual((parsedOriginal["exportedAt"] as? NSNumber)?.int64Value, (parsedReassembled["exportedAt"] as? NSNumber)?.int64Value)
        XCTAssertTrue(String(decoding: reassembled, as: UTF8.self).contains(#""node":{"a":1,"nested":{"b":"x:y, z"}}"#))
    }
    func testExportWithAMissingFieldIsRefused() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let body: [String: Any] = ["profile": "atarasy.member-export.1", "household": household, "exportedAt": 1, "node": [:]]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(body))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do { _ = try await client.exportAccount(); XCTFail("Expected missing-field refusal") } catch {}
    }
    func testExportForAnotherHouseholdIsRefused() async throws {
        let env = try environment(), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let body: [String: Any] = ["profile": "atarasy.member-export.1", "household": "key:" + String(repeating: "D", count: 42) + "A", "exportedAt": 1, "node": [:], "privateRecords": []]
        let transport = LeaveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 200, data: try data(body))])
        let client = try await client(transport, LeaveVault(), env, session: session)
        do { _ = try await client.exportAccount(); XCTFail("Expected household mismatch refusal") } catch {}
    }
}

// MARK: - MemberAccount-level

@MainActor private final class LeaveAccountService: MemberAccountService {
    let info = MemberSessionInfo(id: "session", household: "server-household", presenters: ["merchant"], expiresAt: 5_000_000)
    var status = MemberLeaveStatus(profile: "atarasy.member-leave-status.1", household: "server-household", blockers: [])
    var prepared: PreparedMemberLeave?
    var leftResult: MemberLeft?
    var calls: [String] = []
    var disableRefreshCalled = false
    func registrationOptions(invitation: String) async throws -> MemberCeremony { throw MemberFailure.unavailable }
    func loginOptions() async throws -> MemberCeremony { throw MemberFailure.unavailable }
    func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws { throw MemberFailure.unavailable }
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo { info }
    func restore(household: String) async throws -> MemberSessionInfo? { info }
    func offers(presenter: String) async throws -> [MemberOfferSummary] { [] }
    func logout() async throws -> MemberLogoutOutcome { .revoked }
    func disableRefresh() async throws -> MemberRefreshSubscription { disableRefreshCalled = true; throw MemberFailure.unavailable }
    func leaveStatus() async throws -> MemberLeaveStatus { calls.append("status"); return status }
    func prepareLeave() async throws -> PreparedMemberLeave {
        calls.append("prepare")
        guard let prepared else { throw MemberLeaveError.blocked(status.blockers) }
        return prepared
    }
    func leave(_ prepared: PreparedMemberLeave, assertion: MemberPasskeyResponse) async throws -> MemberLeft {
        calls.append("leave")
        guard let leftResult else { throw MemberFailure.unavailable }
        return leftResult
    }
}
@MainActor private final class LeavePasskeys: MemberPasskeyAuthorising {
    var kinds: [NativePasskeyOptions.Kind] = []
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        kinds.append(kind)
        return .assertion(id: "fixture", clientDataJSON: "fixture", authenticatorData: "fixture", signature: "fixture", userHandle: "fixture")
    }
}

@MainActor final class LeaveAccountTests: XCTestCase {
    func testStatusWithBlockersDoesNotOfferDeletion() async {
        let service = LeaveAccountService()
        service.status = .init(profile: "atarasy.member-leave-status.1", household: "server-household", blockers: [.init(kind: "co_signer", id: "key:other")])
        let account = MemberAccount(service: service, passkeys: LeavePasskeys())
        await account.restore(household: "server-household")
        await account.refreshLeaveStatus()
        XCTAssertEqual(account.leavePhase, .blocked)
        XCTAssertEqual(account.leaveBlockers, [.init(kind: "co_signer", id: "key:other")])
        // Deletion does nothing while blocked: it only runs from `.ready`.
        await account.deleteAccount()
        XCTAssertEqual(service.calls, ["status"])
        XCTAssertNotNil(account.session)
    }
    func testSuccessfulDeletionClearsTheSessionAndDisablesRefreshFirst() async {
        let service = LeaveAccountService()
        service.prepared = .init(ceremony: .init(id: "leave-1", expiresAt: 9_000_000, publicKey: [:]), id: "leave-1", household: "server-household", origin: "https://unit.example", rpID: "unit.example", digest: "digest")
        service.leftResult = .init(profile: "atarasy.member-left.1", household: "server-household", leftAt: 4000, deleted: .object(["offers": .integer(1)]))
        let passkeys = LeavePasskeys()
        let account = MemberAccount(service: service, passkeys: passkeys)
        await account.restore(household: "server-household")
        await account.refreshLeaveStatus()
        XCTAssertEqual(account.leavePhase, .ready)
        await account.deleteAccount()
        XCTAssertTrue(service.disableRefreshCalled)
        XCTAssertEqual(service.calls, ["status", "prepare", "leave"])
        XCTAssertEqual(passkeys.kinds, [.leave])
        XCTAssertNil(account.session)
        XCTAssertEqual(account.leavePhase, .done)
        XCTAssertEqual(account.leaveResult?.leftAt, 4000)
        XCTAssertTrue(account.leaveNotice.contains("deleted"))
    }
    func testABlockerDiscoveredDuringPrepareReturnsToBlockedInsteadOfFailing() async {
        let service = LeaveAccountService()
        // `prepared` stays nil, so `prepareLeave()` throws `.blocked`.
        let account = MemberAccount(service: service, passkeys: LeavePasskeys())
        await account.restore(household: "server-household")
        await account.refreshLeaveStatus()
        XCTAssertEqual(account.leavePhase, .ready)
        await account.deleteAccount()
        XCTAssertEqual(account.leavePhase, .blocked)
        XCTAssertNotNil(account.session)
    }
}
