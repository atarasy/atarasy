import Foundation
import XCTest
@testable import AtarasyCore

func digitalFixture() throws -> [String: Any] {
    let url = Bundle.module.url(forResource: "member-digital-runtime", withExtension: "json", subdirectory: "Fixtures")!
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
func digitalData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private struct DigitalVault: MemberSessionVault {
    let session: MemberSessionInfo
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: session) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor DigitalTransport: MemberHTTPTransport {
    let session: MemberSessionInfo
    var replies: [Data?]
    var requests: [URLRequest] = []
    init(session: MemberSessionInfo, replies: [Data?]) { self.session = session; self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let data: Data
        if request.url!.path == "/auth/session" { data = try JSONEncoder().encode(session) }
        else {
            guard !replies.isEmpty, let next = replies.removeFirst() else { throw URLError(.networkConnectionLost) }
            data = next
        }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: data)
    }
}
private struct DigitalRefusingStore: MemberOperationStore {
    func save(_ handle: MemberOperationHandle) throws { throw MemberFailure.storage }
    func load(id: String) throws -> MemberOperationHandle? { nil }
    func claim(_ handle: MemberOperationHandle, confirmation: String) throws { throw MemberFailure.storage }
}
@MainActor final class MemberDigitalTransportTests: XCTestCase {
    let now: Int64 = 1_800_000_000_001
    func local() throws -> PreparedMemberDecision {
        let f = try digitalFixture(), session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!))
        let object = f["detail"] as! [String: Any]
        let detail = try MemberOfferDetail.decode(digitalData(object), expectedID: object["id"] as! String, household: session.household)
        let view = (f["prepared"] as! [String: Any])["review"] as! [String: Any]
        let approval = try MemberApproval.decode(digitalData(view["approval"]!), detail: detail)
        var draft = MemberDigitalDraft(approval: approval)
        for c in approval.candidates { try draft.choose(.keep, candidate: c.id) }
        return try .init(environment: .init(name: "test", origin: URL(string: "https://unit.example")!), session: session, detail: detail, draft: draft, now: now)
    }
    func store() throws -> (FileMemberOperationStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return (try FileMemberOperationStore(directory: dir), dir)
    }
    private func client(_ replies: [Data?]) async throws -> (MemberClient, DigitalTransport) {
        let l = try local(), transport = DigitalTransport(session: l.session, replies: replies)
        let client = MemberClient(environment: l.environment, transport: transport, vault: DigitalVault(session: l.session), now: { 1_800_000_000_001 })
        _ = try await client.restore(household: l.session.household)
        return (client, transport)
    }
    func assertion(_ h: MemberOperationHandle, challenge: String? = nil) throws -> MemberPasskeyResponse {
        let bytes = try digitalData(["type":"webauthn.get", "origin":h.origin.absoluteString, "challenge":challenge ?? h.challenge])
        let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // Transport placeholder only. The service fixture used a real synthetic P-256 assertion.
        return .assertion(id: h.credentialID, clientDataJSON: encoded, authenticatorData: "YQ", signature: "YQ", userHandle: "YQ")
    }
    func testActualPreparedReviewAndResultAreIndependentlyChecked() async throws {
        let f = try digitalFixture(), l = try local(), (store, _) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!), digitalData(f["committed"]!)])
        let (handle, prepared) = try await client.prepareDecision(l, store: store)
        let frozen = try FrozenMemberDecision(prepared, local: l, now: now)
        XCTAssertEqual(frozen.goods, 1200); XCTAssertEqual(frozen.carriage, 550); XCTAssertEqual(frozen.total, 1750)
        XCTAssertEqual(handle.operationProfile, memberDecisionProfile)
        XCTAssertEqual(try store.load(id: handle.id), handle)
        guard case .recorded(let result) = await client.decisionOutcome(handle) else { return XCTFail("matching historical result expected") }
        XCTAssertEqual(result.candidates[0].valence, "kept")
        let requests = await transport.requests.filter { $0.url!.path != "/auth/session" }
        XCTAssertEqual(requests.map { $0.httpMethod! }, ["POST", "GET"])
        let payload = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual((payload["decisions"] as! [[String: Any]])[0]["kept_as"] as? String, "self")
    }
    func testLostResponsePersistsAttemptAndRestartOnlyReadsOriginalOutcome() async throws {
        let f = try digitalFixture(), l = try local(), (store, directory) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!), nil])
        let (h, _) = try await client.prepareDecision(l, store: store)
        let outcome = try await client.submitDecision(h, assertion: assertion(h), store: store)
        XCTAssertEqual(outcome, .unresolved)
        let reopened = try FileMemberOperationStore(directory: directory), saved = try XCTUnwrap(reopened.load(id: h.id))
        XCTAssertTrue(saved.attempted); XCTAssertEqual(saved.operationProfile, memberDecisionProfile)
        do { _ = try await client.submitDecision(h, assertion: assertion(h), store: reopened); XCTFail("duplicate attempt") } catch {}
        let (fresh, reads) = try await self.client([digitalData(f["committed"]!)])
        guard case .recorded = await fresh.decisionOutcome(saved) else { return XCTFail("recovered") }
        let requests = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }
        XCTAssertEqual(requests.count, 1)
        let resultReads = await reads.requests.filter { $0.url!.path != "/auth/session" }
        XCTAssertEqual(resultReads.map { $0.httpMethod! }, ["GET"])
        let storedText = try String(contentsOf: directory.appendingPathComponent(h.id + ".json"), encoding: .utf8)
        XCTAssertFalse(storedText.contains("amr1_")); XCTAssertFalse(storedText.contains("authenticatorData"))
    }
    func testBadPreparedScopeTermsAmountsAndChallengeAreNotSaved() async throws {
        let f = try digitalFixture(), l = try local()
        for change in 0..<6 {
            var prepared = f["prepared"] as! [String: Any]
            switch change {
            case 0: prepared["profile"] = "atarasy.member-statement-authorisation.1"
            case 1: var key = prepared["publicKey"] as! [String: Any]; key["challenge"] = "wrong"; prepared["publicKey"] = key
            case 2: var review = prepared["review"] as! [String: Any]; review["total"] = 0; prepared["review"] = review
            case 3: var review = prepared["review"] as! [String: Any]; review["decisions"] = []; prepared["review"] = review
            case 4: var review = prepared["review"] as! [String: Any]; var approval = review["approval"] as! [String: Any]; approval["carriage"] = 0; review["approval"] = approval; prepared["review"] = review
            default: var review = prepared["review"] as! [String: Any]; var mandate = review["mandate"] as! [String: Any]; mandate["household"] = "another"; review["mandate"] = mandate; prepared["review"] = review
            }
            let (client, _) = try await client([digitalData(prepared)]), (store, _) = try store()
            do { _ = try await client.prepareDecision(l, store: store); XCTFail("accepted mutation \(change)") } catch {}
            XCTAssertTrue(try store.handles().isEmpty)
        }
    }
    func testChangedResultPriceOrChoicesCannotMasqueradeAsSavedOperation() async throws {
        let f = try digitalFixture(), l = try local()
        for change in 0..<3 {
            var outcome = f["committed"] as! [String: Any], result = outcome["decision"] as! [String: Any]
            var candidates = result["candidates"] as! [[String: Any]]
            if change == 0 { candidates[0]["unit_price"] = 1 }
            else if change == 1 { candidates[0]["valence"] = "returned"; candidates[0]["kept_as"] = NSNull() }
            else { result["household"] = "another" }
            result["candidates"] = candidates; outcome["decision"] = result
            let (client, _) = try await client([digitalData(f["prepared"]!), digitalData(outcome)]), (store, _) = try store()
            let (h, _) = try await client.prepareDecision(l, store: store)
            let value = await client.decisionOutcome(h); XCTAssertEqual(value, .unresolved)
        }
    }
    func testWrongChallengeAndStorageFailureSendNoDecision() async throws {
        let f = try digitalFixture(), l = try local(), (store, _) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!)])
        let (h, _) = try await client.prepareDecision(l, store: store)
        do { _ = try await client.submitDecision(h, assertion: assertion(h, challenge: "wrong"), store: store); XCTFail("wrong challenge") } catch {}
        do { _ = try await client.submitDecision(h, assertion: assertion(h), store: DigitalRefusingStore()); XCTFail("storage failure") } catch {}
        XCTAssertFalse(try XCTUnwrap(store.load(id: h.id)).attempted)
        let submissions = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertTrue(submissions.isEmpty)
    }
    func testDigitalHandlesCannotEnterPhysicalSubmissionOrReadback() async throws {
        let f = try digitalFixture(), l = try local(), (store, _) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!)])
        let (h, _) = try await client.prepareDecision(l, store: store)
        do { _ = try await client.submitStatement(h, assertion: assertion(h), store: store); XCTFail("cross-profile submit") } catch {}
        let outcome = await client.operationOutcome(h); XCTAssertEqual(outcome, .unresolved)
        let requests = await transport.requests.filter { $0.url!.path != "/auth/session" }; XCTAssertEqual(requests.count, 1)
    }
}

@MainActor private final class DigitalPasskeys: MemberPasskeyAuthorising {
    var response: MemberPasskeyResponse?
    var calls = 0
    var beforeReturn: (() -> Void)?
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        calls += 1; XCTAssertEqual(kind, .decision); beforeReturn?()
        guard let response else { throw NativePasskeyFailure.cancelled }; return response
    }
}
extension MemberDigitalTransportTests {
    func draft(_ local: PreparedMemberDecision) throws -> MemberDigitalDraft {
        var draft = MemberDigitalDraft(approval: local.approval)
        for c in local.approval.candidates { try draft.choose(.keep, candidate: c.id) }
        return draft
    }
    func testFlowPasskeyCancellationKeepsReviewAndSendsNothing() async throws {
        let f = try digitalFixture(), l = try local(), (store, _) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!), digitalData(f["prepared"]!)]), keys = DigitalPasskeys()
        let flow = MemberDigitalFlow(environment: l.environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
        flow.setSession(l.session); await flow.prepare(detail: l.detail, draft: try draft(l)); XCTAssertTrue(flow.canApprove)
        await flow.approve(); XCTAssertEqual(keys.calls, 1); XCTAssertTrue(flow.canApprove); XCTAssertTrue(flow.notice.contains("cancelled"))
        XCTAssertFalse(try XCTUnwrap(store.handles().first).attempted)
        let calls = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertTrue(calls.isEmpty)
    }
    func testFlowSessionChangeDuringCeremonyPreventsDispatch() async throws {
        let f = try digitalFixture(), l = try local(), (store, _) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!), digitalData(f["prepared"]!)]), keys = DigitalPasskeys()
        let flow = MemberDigitalFlow(environment: l.environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
        flow.setSession(l.session); await flow.prepare(detail: l.detail, draft: try draft(l))
        keys.response = try assertion(XCTUnwrap(flow.handle)); keys.beforeReturn = { flow.setSession(nil) }
        await flow.approve(); XCTAssertNil(flow.review); XCTAssertNil(flow.handle); XCTAssertTrue(flow.saved.isEmpty)
        let calls = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertTrue(calls.isEmpty)
    }
    func testFlowLostResponseDisablesApprovalAndRestoresSavedResult() async throws {
        let f = try digitalFixture(), l = try local(), (store, directory) = try store()
        let (client, transport) = try await client([digitalData(f["prepared"]!), digitalData(f["prepared"]!), nil, digitalData(f["committed"]!)]), keys = DigitalPasskeys()
        let flow = MemberDigitalFlow(environment: l.environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
        flow.setSession(l.session); await flow.prepare(detail: l.detail, draft: try draft(l)); keys.response = try assertion(XCTUnwrap(flow.handle))
        await flow.approve(); XCTAssertFalse(flow.canApprove); XCTAssertTrue(flow.handle?.attempted == true)
        await flow.approve(); XCTAssertEqual(keys.calls, 1)
        let resumed = MemberDigitalFlow(environment: l.environment, service: client, passkeys: keys, store: try FileMemberOperationStore(directory: directory), now: { 1_800_000_000_001 })
        resumed.setSession(l.session); await resumed.check(try XCTUnwrap(resumed.saved.first)); XCTAssertEqual(resumed.result, .recorded(amount: nil))
        let calls = await transport.requests.filter { $0.url!.path.hasSuffix("/submit") }; XCTAssertEqual(calls.count, 1)
        resumed.setSession(.init(id: "other-session", household: l.session.household, presenters: ["another-presenter"], expiresAt: l.session.expiresAt)); XCTAssertTrue(resumed.saved.isEmpty)
    }
    func testFlowChangedReviewNeverOpensPasskeyAndCancelAllowsNewPreparation() async throws {
        let f = try digitalFixture(), l = try local(), (store, _) = try store()
        var changed = f["prepared"] as! [String: Any], review = changed["review"] as! [String: Any]; review["goods"] = 1; changed["review"] = review
        let (client, _) = try await client([digitalData(f["prepared"]!), digitalData(changed), digitalData(["cancelled":true])]), keys = DigitalPasskeys()
        let flow = MemberDigitalFlow(environment: l.environment, service: client, passkeys: keys, store: store, now: { 1_800_000_000_001 })
        flow.setSession(l.session); await flow.prepare(detail: l.detail, draft: try draft(l)); await flow.approve()
        XCTAssertEqual(keys.calls, 0); XCTAssertFalse(flow.canApprove)
        await flow.cancelPrepared(); XCTAssertNil(flow.handle); XCTAssertNil(flow.review); XCTAssertTrue(flow.notice.contains("Review closed"))
    }
}
extension MemberDigitalTransportTests {
    func testDigitalPasskeyUsesSelectedCredentialAndRejectsWeakenedVerification() throws {
        let f = try digitalFixture(), l = try local()
        let prepared = try JSONDecoder().decode(MemberPreparedDecision.self, from: digitalData(f["prepared"]!))
        let ceremony = MemberCeremony(id: prepared.operationID, expiresAt: prepared.expiresAt, publicKey: prepared.publicKey)
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: l.environment, kind: .decision, now: now)
        XCTAssertEqual(options.challenge.count, 32); XCTAssertEqual(options.allowedCredentialIDs.count, 1)
        var weak = prepared.publicKey; weak["userVerification"] = .string("preferred")
        XCTAssertThrowsError(try NativePasskeyOptions(ceremony: .init(id: prepared.operationID, expiresAt: prepared.expiresAt, publicKey: weak), environment: l.environment, kind: .decision, now: now))
    }

    /// Found on a device, 2026-09-23. A Vox-presented offer carries `predicted_conversion`
    /// as a fraction; the outcome read it through `MemberJSON`, which had no fractional
    /// case, so a recorded decision always read back as unresolved. This is that outcome,
    /// byte for byte as the development member API returned it.
    func testOutcomeWithAFractionalPredictedConversionIsRecorded() async throws {
        let env = try MemberEnvironment(name: "development", origin: URL(string: "https://api-dev.vox.delivery")!)
        let session = MemberSessionInfo(id: "s", household: "key:W-ayxg0PDRdzZ_FmY3iOpuBtLgNtHReNJrYzzsh146E", presenters: ["vox_presenter_dev"], expiresAt: 1_900_000_000_000)
        let transport = DigitalTransport(session: session, replies: [Data(#"{"operationID": "721faecd-2ed9-4f7f-b8c0-062f4f688543", "operationState": "committed", "decision": {"id": "e8e4b801-fa20-402b-8fef-420dd08dca79", "binding": "digital", "household": "key:W-ayxg0PDRdzZ_FmY3iOpuBtLgNtHReNJrYzzsh146E", "presenter": "vox_presenter_dev", "purpose": "replenish", "presenter_attested": false, "price_band": null, "giver": null, "config_version": "dev-digital-20260923-v1", "presented_at": 1790117885519, "expires_at": 1790204220000, "state": "settled", "exploration_floor_met": true, "mandate": "key:W-ayxg0PDRdzZ_FmY3iOpuBtLgNtHReNJrYzzsh146E.1", "candidates": [{"id": "b72dd886-93c6-4ab2-8899-dd9f70dd263b", "product": "dev_digital_goods_20260923", "quantity": 1, "unit_price": 800, "merchant": "vox_merchant_dev", "maker": "dev_workbench_maker", "ships": "dev_workbench_carrier", "category": null, "predicted_conversion": 0.5, "is_exploration": true, "given_by": null, "valence": "returned", "decided_at": 1790120534044, "kept_as": null, "lineage": null}], "disclosures": [{"merchant": "vox_merchant_dev", "product": null, "version": "dev-disclosure-20260923-v1", "items": [{"label": "Return terms", "value": "Unopened items within 7 days of arrival"}], "contact": {"kind": "email", "value": "support@example.com"}, "signature": "ba96CWyMcNN5scIDIg7rVgmeSPJfDiGprCq/Aj0TJfyLbrSWEO+a6y/AnfftOpvA1DKdlyC+t6BCwIDMwvQ9Ag=="}], "reminders_sent": 0, "decided_at": 1790120534044}}"#.utf8)])
        let client = MemberClient(environment: env, transport: transport, vault: DigitalVault(session: session), now: { 1_790_120_600_000 })
        _ = try await client.restore(household: session.household)
        let handle = MemberOperationHandle(id: "721faecd-2ed9-4f7f-b8c0-062f4f688543", environment: "development", origin: env.origin, sessionID: "s", household: session.household, presenter: "vox_presenter_dev", offer: "e8e4b801-fa20-402b-8fef-420dd08dca79", canonical: "e8e4b801-fa20-402b-8fef-420dd08dca79\nb72dd886-93c6-4ab2-8899-dd9f70dd263b:returned::", expiresAt: 1790120794247, requestDigest: String(repeating: "a", count: 64), reviewedRevision: String(repeating: "b", count: 64), challenge: "c", credentialID: "x", attempted: true, profile: memberDecisionProfile, digitalTermsDigest: "9c29e8dfad0194f044acb4c3e618af6dab6e26c52e6a6803cf9fe77f2b0222ed")
        guard case .recorded(let result) = await client.decisionOutcome(handle) else { return XCTFail("a recorded outcome with a fractional conversion must be readable") }
        XCTAssertEqual(result.candidates[0].valence, "returned")
        XCTAssertEqual(result.candidates[0].predictedConversion, 0.5)
    }
    func testMemberJSONRoundTripsAFraction() throws {
        let value = try JSONDecoder().decode(MemberJSON.self, from: Data(#"{"a":0.5,"b":2,"c":-1.25}"#.utf8))
        XCTAssertEqual(value, .object(["a": .fraction(0.5), "b": .integer(2), "c": .fraction(-1.25)]))
        XCTAssertEqual(try JSONDecoder().decode(MemberJSON.self, from: JSONEncoder().encode(value)), value)
    }
}
