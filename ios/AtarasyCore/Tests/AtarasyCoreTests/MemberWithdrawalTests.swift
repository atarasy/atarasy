import Foundation
import XCTest
@testable import AtarasyCore

private struct WithdrawalVault: MemberSessionVault {
    let session: MemberSessionInfo
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: session) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor WithdrawalTransport: MemberHTTPTransport {
    let session: MemberSessionInfo
    var replies: [Data?]
    var requests: [URLRequest] = []
    init(_ session: MemberSessionInfo, _ replies: [Data?]) { self.session = session; self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let data: Data
        if request.url!.path == "/auth/session" { data = try JSONEncoder().encode(session) }
        else { guard !replies.isEmpty, let next = replies.removeFirst() else { throw URLError(.networkConnectionLost) }; data = next }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: data)
    }
}
@MainActor private final class WithdrawalPasskeys: MemberPasskeyAuthorising {
    var response: MemberPasskeyResponse?
    var calls = 0
    var beforeReturn: (() -> Void)?
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        calls += 1; XCTAssertEqual(kind, .withdrawal); beforeReturn?()
        guard let response else { throw NativePasskeyFailure.cancelled }; return response
    }
}
@MainActor final class MemberWithdrawalTests: XCTestCase {
    let environment = try! MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!)
    func fixture() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "member-withdrawal-runtime", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    func original(_ f: [String: Any]) throws -> MemberOperationHandle {
        let p = try JSONDecoder().decode(MemberPreparedDecision.self, from: digitalData(f["decisionPrepared"]!))
        let o = (f["decisionOutcome"] as! [String: Any])["decision"] as! [String: Any]
        var detail = o; detail.removeValue(forKey: "reminders_sent")
        let d = try MemberOfferDetail.decode(digitalData(detail), expectedID: o["id"] as! String, household: o["household"] as! String)
        let session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!))
        guard case .string(let challenge) = p.publicKey["challenge"], case .array(let credentials) = p.publicKey["allowCredentials"], case .object(let credential) = credentials[0], case .string(let id) = credential["id"] else { throw MemberFailure.malformed }
        return .init(id: p.operationID, environment: environment.name, origin: environment.origin, sessionID: session.id, household: d.household, presenter: d.presenter, offer: d.id, canonical: p.canonical, expiresAt: p.expiresAt, requestDigest: p.requestDigest, reviewedRevision: p.reviewedRevision, challenge: challenge, credentialID: id, attempted: true, profile: memberDecisionProfile, digitalTermsDigest: try digitalTermsDigest(d))
    }
    func preparation(_ f: [String: Any], prepared: Any? = nil) throws -> [Data?] {
        var review = f["decisionPrepared"] as! [String: Any]; review["operationState"] = "committed"
        return try [digitalData(f["decisionOutcome"]!), digitalData(review), digitalData(prepared ?? f["withdrawalPrepared"]!)]
    }
    private func client(_ f: [String: Any], _ replies: [Data?]) async throws -> (MemberClient, WithdrawalTransport) {
        let session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!))
        let transport = WithdrawalTransport(session, replies)
        let client = MemberClient(environment: environment, transport: transport, vault: WithdrawalVault(session: session), now: { 1_800_000_000_001 })
        _ = try await client.restore(household: session.household); return (client, transport)
    }
    func store() throws -> (FileMemberOperationStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return (try FileMemberOperationStore(directory: directory), directory)
    }
    func assertion(_ h: MemberOperationHandle) throws -> MemberPasskeyResponse {
        let data = try digitalData(["type":"webauthn.get", "origin": h.origin.absoluteString, "challenge":h.challenge])
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // Transport placeholder; this test does not exercise an authenticator.
        return .assertion(id: h.credentialID, clientDataJSON: encoded, authenticatorData: "YQ", signature: "YQ", userHandle: "YQ")
    }
    func testActualWithdrawalReviewAndHistoricalResult() async throws {
        let f = try fixture(), (store, _) = try store()
        let (client, transport) = try await client(f, preparation(f) + [digitalData(f["withdrawalOutcome"]!)])
        let (h, p, frozen) = try await client.prepareWithdrawal(original(f), store: store)
        XCTAssertEqual(frozen.total, 1750); XCTAssertEqual(frozen.nextIncarnation, 1)
        XCTAssertEqual(h.operationProfile, memberWithdrawalProfile)
        let options = try NativePasskeyOptions(ceremony: .init(id: p.operationID, expiresAt: p.expiresAt, publicKey: p.publicKey), environment: environment, kind: .withdrawal, now: 1_800_000_000_001)
        XCTAssertEqual(options.allowedCredentialIDs.count, 1)
        guard case .recorded(let detail) = await client.withdrawalOutcome(h) else { return XCTFail("historical withdrawal") }
        XCTAssertEqual(detail.state, "presented"); XCTAssertTrue(detail.candidates.allSatisfy { $0.valence == "offered" })
        let requests = await transport.requests.filter { $0.url!.path != "/auth/session" }
        XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET", "GET", "POST", "GET"])
    }
    func testCorruptedWithdrawalReviewIsNeverSaved() async throws {
        let f = try fixture()
        for change in 0..<6 {
            var p = f["withdrawalPrepared"] as! [String: Any], review = p["review"] as! [String: Any]
            switch change {
            case 0: p["profile"] = memberDecisionProfile
            case 1: review["decisionOperationID"] = UUID().uuidString.lowercased()
            case 2: var e = review["eligibility"] as! [String: Any]; e["decisionRevision"] = String(repeating: "0", count: 64); review["eligibility"] = e
            case 3: var e = review["eligibility"] as! [String: Any]; e["coolingEndsAt"] = 1; review["eligibility"] = e
            case 4: var d = review["decisionReview"] as! [String: Any]; d["total"] = 0; review["decisionReview"] = d
            default: var m = review["mandate"] as! [String: Any]; m["household"] = "another"; review["mandate"] = m
            }
            p["review"] = review
            let (client, _) = try await client(f, preparation(f, prepared: p)), (store, _) = try store()
            do { _ = try await client.prepareWithdrawal(original(f), store: store); XCTFail("mutation accepted") } catch {}
            XCTAssertTrue(try store.handles().isEmpty)
        }
    }
    func testChangedResultCannotMasqueradeAsOriginalWithdrawal() async throws {
        let f = try fixture()
        for change in 0..<4 {
            var outcome = f["withdrawalOutcome"] as! [String: Any], result = outcome["withdrawal"] as! [String: Any]
            if change == 0 { result["decisionOperationID"] = UUID().uuidString.lowercased() }
            else if change == 1 { result["nextIncarnation"] = 2 }
            else {
                var offer = result["offer"] as! [String: Any], candidates = offer["candidates"] as! [[String: Any]]
                if change == 2 { candidates[0]["unit_price"] = 0 } else { candidates[0]["valence"] = "kept" }
                offer["candidates"] = candidates; result["offer"] = offer
            }
            outcome["withdrawal"] = result
            let (client, _) = try await client(f, preparation(f) + [digitalData(outcome)]), (store, _) = try store()
            let (h, _, _) = try await client.prepareWithdrawal(original(f), store: store)
            let value = await client.withdrawalOutcome(h); XCTAssertEqual(value, .unresolved)
        }
    }
    func testLostResponsePersistsAttemptAndRestartOnlyReadsResult() async throws {
        let f = try fixture(), (store, directory) = try store()
        let (client, transport) = try await client(f, preparation(f) + [nil])
        let (h, _, _) = try await client.prepareWithdrawal(original(f), store: store)
        let value = try await client.submitWithdrawal(h, assertion: assertion(h), store: store); XCTAssertEqual(value, .unresolved)
        let reopened = try FileMemberOperationStore(directory: directory), saved = try XCTUnwrap(reopened.load(id: h.id))
        XCTAssertTrue(saved.attempted); XCTAssertEqual(saved.withdrawalDecisionID, h.withdrawalDecisionID)
        do { _ = try await client.submitWithdrawal(h, assertion: assertion(h), store: reopened); XCTFail("duplicate") } catch {}
        let (fresh, reads) = try await self.client(f, [digitalData(f["withdrawalOutcome"]!)])
        guard case .recorded = await fresh.withdrawalOutcome(saved) else { return XCTFail("recovery") }
        let sent = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertEqual(sent.count, 1)
        let requests = await reads.requests.filter { $0.url!.path != "/auth/session" }; XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET"])
        do { _ = try await fresh.submitDecision(saved, assertion: assertion(saved), store: reopened); XCTFail("cross-profile") } catch {}
    }
    func testFlowCancellationAndSessionChangePreventSubmission() async throws {
        let f = try fixture()
        for changeSession in [false, true] {
            let (client, transport) = try await client(f, preparation(f) + [digitalData(f["withdrawalPrepared"]!)]), (store, _) = try store(), keys = WithdrawalPasskeys()
            let flow = MemberWithdrawalFlow(environment: environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
            let session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!))
            flow.setSession(session); await flow.prepare(original: try original(f)); XCTAssertTrue(flow.canApprove)
            if changeSession { keys.response = try assertion(XCTUnwrap(flow.handle)); keys.beforeReturn = { flow.setSession(nil) } }
            await flow.approve(); XCTAssertEqual(keys.calls, 1)
            if changeSession { XCTAssertNil(flow.handle); XCTAssertNil(flow.review) } else { XCTAssertTrue(flow.canApprove) }
            let sent = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertTrue(sent.isEmpty)
        }
    }
    func testFlowChangedReviewNeverOpensPasskey() async throws {
        let f = try fixture(), (store, _) = try store(), keys = WithdrawalPasskeys()
        var changed = f["withdrawalPrepared"] as! [String: Any], review = changed["review"] as! [String: Any]
        review["incarnation"] = 2; changed["review"] = review
        let (client, transport) = try await client(f, preparation(f) + [digitalData(changed)])
        let flow = MemberWithdrawalFlow(environment: environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
        flow.setSession(try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!)))
        await flow.prepare(original: try original(f)); XCTAssertTrue(flow.canApprove)
        await flow.approve(); XCTAssertEqual(keys.calls, 0); XCTAssertFalse(flow.canApprove)
        let sent = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertTrue(sent.isEmpty)
    }
    func testFlowLostResponseDisablesApprovalAndRecoversSavedResult() async throws {
        let f = try fixture(), (store, directory) = try store(), keys = WithdrawalPasskeys()
        let (client, transport) = try await client(f, preparation(f) + [digitalData(f["withdrawalPrepared"]!), nil, digitalData(f["withdrawalOutcome"]!)])
        let flow = MemberWithdrawalFlow(environment: environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
        let session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!))
        flow.setSession(session); await flow.prepare(original: try original(f)); keys.response = try assertion(XCTUnwrap(flow.handle))
        await flow.approve(); XCTAssertFalse(flow.canApprove); XCTAssertTrue(flow.handle?.attempted == true)
        await flow.approve(); XCTAssertEqual(keys.calls, 1)
        let resumed = MemberWithdrawalFlow(environment: environment, service: client, passkeys: keys, store: try FileMemberOperationStore(directory: directory), now: { 1_800_000_000_001 })
        resumed.setSession(session); await resumed.check(try XCTUnwrap(resumed.saved.first)); XCTAssertTrue(resumed.notice.contains("Withdrawal recorded"))
        let sent = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertEqual(sent.count, 1)
    }

}
