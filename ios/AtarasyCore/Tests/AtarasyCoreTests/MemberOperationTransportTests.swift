import Foundation
import XCTest
@testable import AtarasyCore

private struct RuntimeVault: MemberSessionVault {
    let info: MemberSessionInfo
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: info) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor RuntimeTransport: MemberHTTPTransport {
    let info: MemberSessionInfo
    var replies: [Data?]
    var requests: [URLRequest] = []
    init(info: MemberSessionInfo, replies: [Data?]) { self.info = info; self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let data: Data
        if request.url!.path == "/auth/session" { data = try JSONEncoder().encode(info) }
        else {
            guard !replies.isEmpty, let next = replies.removeFirst() else { throw URLError(.networkConnectionLost) }
            data = next
        }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: data)
    }
}
private struct RefusingOperationStore: MemberOperationStore {
    func save(_ handle: MemberOperationHandle) throws { throw MemberFailure.storage }
    func load(id: String) throws -> MemberOperationHandle? { nil }
    func claim(_ handle: MemberOperationHandle, confirmation: String) throws { throw MemberFailure.storage }
}
@MainActor final class MemberOperationTransportTests: XCTestCase {
    let info = MemberSessionInfo(id: "session", household: "house", presenters: ["merchant-1"], expiresAt: 1_800_000_010_000)
    func fixture(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "member-operation-runtime", withExtension: "json", subdirectory: "Fixtures")!
        return (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])[name] as! [String: Any]
    }
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    /// The signature the committed fixture's receipt names as its confirmation.
    func fixtureSignature() throws -> String { (try fixture("committed")["receipt"] as! [String: Any])["confirmation"] as! String }
    /// `submitted` is the signature this device claims to have sent; nil is a handle never submitted.
    func handle(canonical override: String? = nil, submitted: String? = nil) throws -> MemberOperationHandle {
        let p = try fixture("prepared"), key = p["publicKey"] as! [String: Any], credential = (key["allowCredentials"] as! [[String: Any]])[0]
        let receipt = try fixture("committed")["receipt"] as! [String: Any]
        let fresh = MemberOperationHandle(id: p["operationID"] as! String, environment: "test", origin: URL(string: "https://unit.example")!, sessionID: info.id, household: info.household, presenter: "merchant-1", offer: receipt["offer"] as! String, canonical: override ?? p["canonical"] as! String, expiresAt: (p["expiresAt"] as! NSNumber).int64Value, requestDigest: p["requestDigest"] as! String, reviewedRevision: p["reviewedRevision"] as! String, challenge: key["challenge"] as! String, credentialID: credential["id"] as! String, attempted: false)
        return submitted.map { fresh.markedAttempted(confirmation: $0) } ?? fresh
    }
    private func client(_ replies: [Data?], environment: String = "test") async throws -> (MemberClient, RuntimeTransport) {
        let transport = RuntimeTransport(info: info, replies: replies)
        let client = MemberClient(environment: try .init(name: environment, origin: URL(string: "https://unit.example")!), transport: transport, vault: RuntimeVault(info: info), now: { 1_800_000_000_003 })
        _ = try await client.restore(household: info.household)
        return (client, transport)
    }
    func store() throws -> (FileMemberOperationStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return (try FileMemberOperationStore(directory: directory), directory)
    }
    func assertion(_ h: MemberOperationHandle, signature: String = "YQ") throws -> MemberPasskeyResponse {
        let bytes = try data(["type":"webauthn.get", "challenge":h.challenge, "origin":h.origin.absoluteString])
        let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // Transport-only assertion placeholder; never offered as native cryptographic evidence.
        return .assertion(id: h.credentialID, clientDataJSON: encoded, authenticatorData: "YQ", signature: signature, userHandle: "YQ")
    }
    func testActualServiceChallengeAndReceiptDecodeWithoutResubmission() async throws {
        let h = try handle(submitted: fixtureSignature()), (c, t) = try await client([data(fixture("prepared")), data(fixture("pending")), data(fixture("committed"))])
        let review = try await c.operationReview(h); XCTAssertEqual(review.publicKey["challenge"], .string(h.challenge))
        let pending = await c.operationOutcome(h); XCTAssertEqual(pending, .pending("prepared"))
        let outcome = await c.operationOutcome(h)
        guard case .committed(let receipt) = outcome else { return XCTFail("Actual service receipt was not decoded") }
        XCTAssertEqual(receipt.charged, 1200)
        let requests = await t.requests; XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }
    /// Question 46. A line the collection recorded missing is signed at 0 and carried on the
    /// receipt at its stock value; the read-back must rebuild the signed bytes, not drop it.
    /// `missing` names the extra candidate; ids before and after the consumed line's id
    /// exercise the statement's sort order.
    func missingOutcome(missing: String = "ffffffff-0000-4000-8000-000000000046", disputed: Bool, signed: Bool,
                        receiptDisputed: Bool? = nil, dropFromReceipt: Bool = false) throws -> (MemberOperationHandle, Data) {
        var outcome = try fixture("committed"), receipt = outcome["receipt"] as! [String: Any]
        var lines = receipt["lines"] as! [[String: Any]], line = lines[0]
        line["candidate"] = missing; line["product"] = "salt-0"; line["valence"] = "lost"; line["amount"] = 300; line["disputed"] = receiptDisputed ?? disputed
        if !dropFromReceipt { lines.append(line); receipt["lost_amount"] = 300 }
        receipt["lines"] = lines; outcome["receipt"] = receipt
        let base = try fixture("prepared")["canonical"] as! String
        var parts = base.components(separatedBy: "\n")
        if signed {
            parts.append("\(missing):lost:0:\(disputed ? "disputed" : "")")
            let header = parts.prefix(3), body = parts.dropFirst(3).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            parts = Array(header) + body
        }
        return (try handle(canonical: parts.joined(separator: "\n"), submitted: fixtureSignature()), try data(outcome))
    }
    func testSignedMissingLineReadsBackAsCommitted() async throws {
        var failures: [String] = []
        for missing in ["00000000-0000-4000-8000-000000000046", "ffffffff-0000-4000-8000-000000000046"] {
            for disputed in [true, false] {
                let (h, reply) = try missingOutcome(missing: missing, disputed: disputed, signed: true)
                let (c, _) = try await client([reply])
                if case .committed(let receipt) = await c.operationOutcome(h) {
                    XCTAssertEqual(receipt.charged, 1200); XCTAssertEqual(receipt.lostAmount, 300)
                } else { failures.append("\(missing) disputed: \(disputed)") }
            }
        }
        XCTAssertEqual(failures, [], "Signed missing lines were not read back")
    }
    /// A regression guard, not a fix check: a deadline loss was read back before and must still be.
    func testDeadlineLossOffTheStatementStillReadsBackAsCommitted() async throws {
        let (h, reply) = try missingOutcome(disputed: false, signed: false)
        let (c, _) = try await client([reply])
        let outcome = await c.operationOutcome(h); guard case .committed = outcome else { return XCTFail("Deadline loss broke the read-back") }
    }
    func testTamperedMissingLineReceiptsRemainUnresolved() async throws {
        let cases: [(String, (MemberOperationHandle, Data))] = [
            ("signed missing line dropped from the receipt", try missingOutcome(disputed: false, signed: true, dropFromReceipt: true)),
            ("dispute flag flipped on the receipt", try missingOutcome(disputed: true, signed: true, receiptDisputed: false)),
            ("disputed lost line the statement never named", try missingOutcome(disputed: false, signed: false, receiptDisputed: true)),
        ]
        for (name, (h, reply)) in cases {
            let (c, _) = try await client([reply])
            let outcome = await c.operationOutcome(h)
            XCTAssertEqual(outcome, .unresolved, name)
        }
    }
    /// A receipt whose lines match what this device signed, but whose confirmation is another
    /// signature, is a settlement that stands and not this device's approval.
    func testReceiptSettledByAnotherSignatureIsNotReportedAsThisDevices() async throws {
        let cases: [(String, MemberOperationHandle)] = [
            ("different signature", try handle(submitted: "another-signature")),
            ("never submitted from this device", try handle()),
        ]
        for (name, h) in cases {
            let (c, _) = try await client([data(fixture("committed"))])
            let outcome = await c.operationOutcome(h)
            guard case .settledElsewhere(let receipt) = outcome else { XCTFail(name); continue }
            XCTAssertEqual(receipt.charged, 1200, name)
        }
    }
    /// A handle saved before this build recorded signatures still settles, but is not called this device's.
    func testLegacyAttemptedHandleWithoutFingerprintIsNotReportedAsThisDevices() async throws {
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handle())) as! [String: Any]
        saved["attempted"] = true; saved.removeValue(forKey: "confirmationFingerprint")
        let legacy = try JSONDecoder().decode(MemberOperationHandle.self, from: data(saved))
        XCTAssertTrue(legacy.attempted); XCTAssertNil(legacy.confirmationFingerprint)
        let (c, _) = try await client([data(fixture("committed"))])
        let outcome = await c.operationOutcome(legacy)
        guard case .settledUnverified(let receipt) = outcome else { return XCTFail("A legacy handle read back as this device's approval") }
        XCTAssertEqual(receipt.charged, 1200)
    }
    /// Signing in again and preparing the same box returns the same operation, which a new session id must not refuse.
    func testSavingTheSameOperationFromANewSessionKeepsTheStoredHandle() throws {
        let h = try handle(), (s, _) = try store(); try s.save(h)
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        fields["sessionID"] = "a-later-session"
        let later = try JSONDecoder().decode(MemberOperationHandle.self, from: data(fields))
        XCTAssertNoThrow(try s.save(later)); XCTAssertEqual(try s.load(id: h.id), h)
        fields["canonical"] = "changed"
        XCTAssertThrowsError(try s.save(JSONDecoder().decode(MemberOperationHandle.self, from: data(fields))))
    }
    /// A result read after signing in again, from the same household.
    func testOutcomeReadsAfterANewSessionForTheSameHousehold() async throws {
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handle(submitted: fixtureSignature()))) as! [String: Any]
        var earlier = saved; earlier["sessionID"] = "an-earlier-session"
        let h = try JSONDecoder().decode(MemberOperationHandle.self, from: data(earlier))
        let (c, _) = try await client([data(fixture("committed"))])
        let outcome = await c.operationOutcome(h); guard case .committed = outcome else { return XCTFail("A new sign-in could not read its own result") }
        var foreign = saved; foreign["household"] = "another-house"
        let other = try JSONDecoder().decode(MemberOperationHandle.self, from: data(foreign))
        let (c2, t2) = try await client([data(fixture("committed"))])
        let refused = await c2.operationOutcome(other); XCTAssertEqual(refused, .unresolved)
        let requests = await t2.requests; XCTAssertEqual(requests.count, 1)
    }
    func testLostSubmissionPersistsAttemptAndRestartCannotSendAgain() async throws {
        let h = try handle(), (s, directory) = try store(); try s.save(h)
        let (c, t) = try await client([nil, data(fixture("committed"))])
        let first = try await c.submitStatement(h, assertion: assertion(h, signature: fixtureSignature()), store: s); XCTAssertEqual(first, .unresolved)
        let reopened = try FileMemberOperationStore(directory: directory), loaded = try XCTUnwrap(reopened.load(id: h.id)); XCTAssertTrue(loaded.attempted)
        do { _ = try await c.submitStatement(h, assertion: assertion(h), store: reopened); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .busy) }
        let outcome = await c.operationOutcome(loaded); guard case .committed = outcome else { return XCTFail() }
        let requests = await t.requests; XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        let checkpoint = try String(contentsOf: directory.appendingPathComponent(h.id + ".json"), encoding: .utf8)
        XCTAssertFalse(checkpoint.contains("amr1_")); XCTAssertFalse(checkpoint.contains("clientDataJSON"))
    }
    func testPersistenceFailurePreventsDispatch() async throws {
        let h = try handle(), (c, t) = try await client([])
        do { _ = try await c.submitStatement(h, assertion: assertion(h), store: RefusingOperationStore()); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .storage) }
        let requests = await t.requests; XCTAssertEqual(requests.count, 1)
    }
    func testDifferentEnvironmentAndCorruptReceiptRemainUnresolved() async throws {
        let h = try handle(submitted: fixtureSignature()), (foreign, transport) = try await client([], environment: "other")
        let refused = await foreign.operationOutcome(h); XCTAssertEqual(refused, .unresolved)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
        var outcome = try fixture("committed"), receipt = outcome["receipt"] as! [String: Any]; receipt["charged"] = 99; outcome["receipt"] = receipt
        let (c, _) = try await client([data(outcome)]); let bad = await c.operationOutcome(h); XCTAssertEqual(bad, .unresolved)
    }
    func testChangedChallengeOrRevisionCannotReplaceReview() async throws {
        for field in ["challenge", "reviewedRevision"] {
            var p = try fixture("prepared")
            if field == "challenge" { var key = p["publicKey"] as! [String: Any]; key[field] = "wrong"; p["publicKey"] = key }
            else { p[field] = String(repeating: "a", count: 64) }
            let (c, _) = try await client([data(p)])
            do { _ = try await c.operationReview(handle()); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .scopeMismatch) }
        }
    }
    func testCancellationRouteAndCheckpointCannotBeReset() async throws {
        let h = try handle(), (s, _) = try store(); try s.save(h); try s.claim(h, confirmation: "YQ")
        XCTAssertThrowsError(try s.save(h)); XCTAssertThrowsError(try s.claim(h, confirmation: "YQ"))
        let (c, t) = try await client([data(["cancelled":true])])
        try await c.cancelOperation(h)
        let request = await t.requests.last!; XCTAssertEqual(request.url?.path, "/member/operations/" + h.id + "/cancel"); XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }
    func testCancellationRejectsFalseMissingAndNonBooleanAcknowledgements() async throws {
        let h = try handle()
        for payload: [String: Any] in [["cancelled": false], [:], ["cancelled": 1], ["cancelled": "true"], ["id": h.id, "state": "cancelled"]] {
            let (c, _) = try await client([data(payload)])
            do { try await c.cancelOperation(h); XCTFail("Invalid cancellation acknowledgement accepted") }
            catch { XCTAssertEqual(error as? MemberFailure, .malformed) }
        }
    }
    func testPreparationSavesHandleAndStorageFailureDoesNotReturnApproval() async throws {
        let url = Bundle.module.url(forResource: "member-transaction-responses", withExtension: "json", subdirectory: "Fixtures")!
        let cases = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["cases"] as! [[String: Any]]
        func value(_ name: String) -> [String: Any] { cases.first { $0["name"] as? String == name }!["value"] as! [String: Any] }
        let detailValue = value("physical-detail"), statementValue = value("physical-known-carriage")
        let detail = try MemberOfferDetail.decode(data(detailValue), expectedID: detailValue["id"] as! String, household: "detail-house")
        let statement = try MemberStatement.decode(data(statementValue), detail: detail)
        let localInfo = MemberSessionInfo(id: "session", household: "detail-house", presenters: ["merchant-1"], expiresAt: 5000)
        let environment = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!)
        let local = try PreparedMemberStatement(environment: environment, session: localInfo, detail: detail, statement: statement, disputed: [], now: 1000)
        var reply = try fixture("prepared"), review = reply["review"] as! [String: Any]
        var serverStatement = statementValue; serverStatement.removeValue(forKey: "challenge")
        review["statement"] = serverStatement; review["disputed"] = [] as [String]
        var mandate = review["mandate"] as! [String: Any]; mandate["household"] = localInfo.household; review["mandate"] = mandate
        reply["review"] = review; reply["canonical"] = local.canonical; reply["expiresAt"] = 2000
        // Scope and digest inputs are unchanged, preserving the independently generated service challenge.
        for fails in [false, true] {
            let transport = RuntimeTransport(info: localInfo, replies: [try data(reply)])
            let client = MemberClient(environment: environment, transport: transport, vault: RuntimeVault(info: localInfo), now: { 1000 })
            _ = try await client.restore(household: localInfo.household)
            let (storage, _) = try store()
            do {
                let (handle, _) = try await client.prepareStatement(local, store: fails ? RefusingOperationStore() : storage)
                XCTAssertFalse(fails); XCTAssertEqual(try storage.load(id: handle.id), handle)
            } catch { XCTAssertTrue(fails); XCTAssertEqual(error as? MemberFailure, .storage) }
            let request = await transport.requests.last!
            XCTAssertEqual(request.url?.path, "/member/statements/prepare")
            XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]).keys), ["offer", "disputed"])
        }
    }

    /// Signing in again and preparing the same box must hand back the handle already stored, or the
    /// claim before submission refuses it as busy and the approval is stranded.
    func testPreparingAgainAfterANewSignInReturnsTheStoredHandleSoItCanBeClaimed() async throws {
        let url = Bundle.module.url(forResource: "member-transaction-responses", withExtension: "json", subdirectory: "Fixtures")!
        let cases = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["cases"] as! [[String: Any]]
        func value(_ name: String) -> [String: Any] { cases.first { $0["name"] as? String == name }!["value"] as! [String: Any] }
        let detailValue = value("physical-detail"), statementValue = value("physical-known-carriage")
        let detail = try MemberOfferDetail.decode(data(detailValue), expectedID: detailValue["id"] as! String, household: "detail-house")
        let statement = try MemberStatement.decode(data(statementValue), detail: detail)
        let environment = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!)
        let (storage, _) = try store()
        var stored: MemberOperationHandle?
        for sessionID in ["earlier-session", "later-session"] {
            let localInfo = MemberSessionInfo(id: sessionID, household: "detail-house", presenters: ["merchant-1"], expiresAt: 5000)
            let local = try PreparedMemberStatement(environment: environment, session: localInfo, detail: detail, statement: statement, disputed: [], now: 1000)
            var reply = try fixture("prepared"), review = reply["review"] as! [String: Any]
            var serverStatement = statementValue; serverStatement.removeValue(forKey: "challenge")
            review["statement"] = serverStatement; review["disputed"] = [] as [String]
            var mandate = review["mandate"] as! [String: Any]; mandate["household"] = localInfo.household; review["mandate"] = mandate
            reply["review"] = review; reply["canonical"] = local.canonical; reply["expiresAt"] = 2000
            let transport = RuntimeTransport(info: localInfo, replies: [try data(reply)])
            let client = MemberClient(environment: environment, transport: transport, vault: RuntimeVault(info: localInfo), now: { 1000 })
            _ = try await client.restore(household: localInfo.household)
            let (handle, _) = try await client.prepareStatement(local, store: storage)
            if let stored { XCTAssertEqual(handle, stored) } else { stored = handle }
        }
        XCTAssertEqual(stored?.sessionID, "earlier-session")
        XCTAssertNoThrow(try storage.claim(XCTUnwrap(stored), confirmation: "YQ"))
    }
    func testMatchingTamperedCheckpointAndResponseStillNeedValidContextualChallenge() async throws {
        let h = try handle()
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
        saved["challenge"] = "tampered"
        let altered = try JSONDecoder().decode(MemberOperationHandle.self, from: data(saved))
        var reply = try fixture("prepared"), key = reply["publicKey"] as! [String: Any]
        key["challenge"] = "tampered"; reply["publicKey"] = key
        let (c, _) = try await client([data(reply)])
        do { _ = try await c.operationReview(altered); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .scopeMismatch) }
    }

}

@MainActor private final class FlowService: MemberStatementService {
    let handle: MemberOperationHandle
    var preparation: MemberPreparedOperation
    var submissions = 0
    var outcomes = 0
    var changed = false
    var outcome: MemberOperationOutcome = .pending("prepared")
    init(handle: MemberOperationHandle, preparation: MemberPreparedOperation) { self.handle = handle; self.preparation = preparation }
    func prepareStatement(_ local: PreparedMemberStatement, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedOperation) { try store.save(handle); return (handle, preparation) }
    func operationReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedOperation { if changed { throw MemberFailure.scopeMismatch }; return preparation }
    func submitStatement(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberOperationOutcome { try store.claim(handle, confirmation: "YQ"); submissions += 1; return .unresolved }
    func operationOutcome(_ handle: MemberOperationHandle) async -> MemberOperationOutcome { outcomes += 1; return outcome }
    func cancelOperation(_ handle: MemberOperationHandle) async throws {}
    var settled: ProtocolSettlement?
    func settlement(offerID: String) async throws -> ProtocolSettlement { guard let settled else { throw MemberFailure.http(404) }; return settled }
}
@MainActor private final class FlowPasskeys: MemberPasskeyAuthorising {
    var calls = 0
    var cancel = false
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var observed: CheckedContinuation<Void, Never>?
    func wait() async { if pending != nil { return }; await withCheckedContinuation { observed = $0 } }
    func release() { pending?.resume(); pending = nil }
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        calls += 1; XCTAssertTrue(kind == .statement)
        if hold { await withCheckedContinuation { pending = $0; observed?.resume(); observed = nil } }
        if cancel { throw NativePasskeyFailure.cancelled }
        return .assertion(id: "YQ", clientDataJSON: "YQ", authenticatorData: "YQ", signature: "YQ", userHandle: "YQ")
    }
}
extension MemberOperationTransportTests {
    private func flowSetup(diagnostic: @escaping (String) -> Void = { _ in }) throws -> (MemberStatementFlow, FlowService, FlowPasskeys, MemberOfferDetail, MemberStatement, MemberSessionInfo) {
        let url = Bundle.module.url(forResource: "member-transaction-responses", withExtension: "json", subdirectory: "Fixtures")!
        let cases = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["cases"] as! [[String: Any]]
        func value(_ name: String) -> [String: Any] { cases.first { $0["name"] as? String == name }!["value"] as! [String: Any] }
        let object = value("physical-detail"), raw = value("physical-known-carriage")
        let detail = try MemberOfferDetail.decode(data(object), expectedID: object["id"] as! String, household: "detail-house")
        let statement = try MemberStatement.decode(data(raw), detail: detail)
        let info = MemberSessionInfo(id: "session", household: "detail-house", presenters: ["merchant-1"], expiresAt: 5000)
        let env = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!)
        let local = try PreparedMemberStatement(environment: env, session: info, detail: detail, statement: statement, disputed: [], now: 1000)
        var p = try fixture("prepared"), review = p["review"] as! [String: Any], st = raw
        st.removeValue(forKey: "challenge"); review["statement"] = st; review["disputed"] = [] as [String]
        var mandate = review["mandate"] as! [String: Any]; mandate["id"] = detail.mandate; mandate["household"] = info.household; review["mandate"] = mandate
        p["review"] = review; p["canonical"] = local.canonical; p["expiresAt"] = 2000
        var h = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handle())) as! [String: Any]
        h["household"] = info.household; h["offer"] = detail.id; h["canonical"] = local.canonical; h["expiresAt"] = 2000
        let service = try FlowService(handle: JSONDecoder().decode(MemberOperationHandle.self, from: data(h)), preparation: JSONDecoder().decode(MemberPreparedOperation.self, from: data(p)))
        let passkeys = FlowPasskeys(), (store, _) = try store()
        let flow = MemberStatementFlow(environment: env, service: service, passkeys: passkeys, store: store, diagnostic: diagnostic, now: { 1000 }); flow.setSession(info)
        return (flow, service, passkeys, detail, statement, info)
    }
    func testFrozenReviewPrecedesNativeSigningAndUncertaintyDisablesAnotherApproval() async throws {
        let (flow, service, passkeys, detail, statement, _) = try flowSetup()
        await flow.approve(); XCTAssertEqual(passkeys.calls, 0)
        await flow.prepare(detail: detail, statement: statement, disputed: [])
        XCTAssertTrue(flow.canApprove); XCTAssertEqual(flow.review?.goodsCharged, 3000)
        XCTAssertEqual(flow.review?.statement.disclosures, statement.disclosures)
        await flow.approve(); XCTAssertEqual(service.submissions, 1); XCTAssertFalse(flow.canApprove)
        await flow.approve(); XCTAssertEqual(service.submissions, 1)
        XCTAssertTrue(flow.saved[0].attempted)
    }
    func testNativeCancellationAndChangedReviewNeverSubmit() async throws {
        for changed in [false, true] {
            let (flow, service, passkeys, detail, statement, _) = try flowSetup()
            await flow.prepare(detail: detail, statement: statement, disputed: [])
            passkeys.cancel = true; service.changed = changed
            await flow.approve(); XCTAssertEqual(service.submissions, 0); XCTAssertEqual(passkeys.calls, changed ? 0 : 1)
        }
    }
    func testApprovalDiagnosticsIdentifyStageWithoutPayloads() async throws {
        for changed in [false, true] {
            var events: [String] = []
            let (flow, service, passkeys, detail, statement, _) = try flowSetup(diagnostic: { events.append($0) })
            await flow.prepare(detail: detail, statement: statement, disputed: [])
            service.changed = changed; passkeys.cancel = true
            await flow.approve()
            XCTAssertEqual(events, [changed ? "review-read:scope-mismatch" : "passkey-presentation:cancelled"])
            XCTAssertEqual(service.submissions, 0)
            XCTAssertFalse(flow.saved[0].attempted)
        }
    }
    func testConfirmedCancellationReopensPreparationAndKeepsSavedResult() async throws {
        let (flow, service, passkeys, detail, statement, _) = try flowSetup()
        await flow.prepare(detail: detail, statement: statement, disputed: [])
        XCTAssertNotNil(flow.handle)
        await flow.cancelPrepared()
        XCTAssertNil(flow.handle); XCTAssertNil(flow.review); XCTAssertFalse(flow.canApprove)
        XCTAssertEqual(flow.saved.count, 1); XCTAssertFalse(flow.saved[0].attempted)
        XCTAssertTrue(flow.notice.contains("Review closed"))
        XCTAssertEqual(service.submissions, 0); XCTAssertEqual(passkeys.calls, 0)
    }
    func testClosingDuringNativeCeremonyDropsLateAssertion() async throws {
        let (flow, service, passkeys, detail, statement, _) = try flowSetup()
        await flow.prepare(detail: detail, statement: statement, disputed: []); passkeys.hold = true
        let task = Task { await flow.approve() }; await passkeys.wait()
        flow.closeReview(); passkeys.release(); await task.value
        XCTAssertEqual(service.submissions, 0); XCTAssertNil(flow.review)
    }
    func testRestoredHandlesOnlyReadResultsAndFilterHousehold() async throws {
        let (flow, service, passkeys, detail, statement, info) = try flowSetup()
        await flow.prepare(detail: detail, statement: statement, disputed: [])
        flow.setSession(nil); XCTAssertTrue(flow.saved.isEmpty)
        flow.setSession(info); XCTAssertEqual(flow.saved.count, 1); XCTAssertFalse(flow.canApprove)
        await flow.check(flow.saved[0]); XCTAssertEqual(service.outcomes, 1); XCTAssertEqual(passkeys.calls, 0)
        // A new sign-in by the same household still sees what it prepared; another household does not.
        flow.setSession(MemberSessionInfo(id: "other", household: info.household, presenters: info.presenters, expiresAt: info.expiresAt)); XCTAssertEqual(flow.saved.count, 1)
        flow.setSession(MemberSessionInfo(id: "other", household: "another-house", presenters: info.presenters, expiresAt: info.expiresAt)); XCTAssertTrue(flow.saved.isEmpty)
    }
    /// A box seen to settle is remembered, so a statement review loaded before settling does not offer preparation again.
    func testSettledOutcomeIsRememberedAcrossClosingTheReview() async throws {
        let (flow, service, _, detail, statement, info) = try flowSetup()
        await flow.prepare(detail: detail, statement: statement, disputed: [])
        var receipt = try fixture("committed")["receipt"] as! [String: Any]; receipt["offer"] = detail.id
        let settlement = try JSONDecoder().decode(ProtocolSettlement.self, from: data(receipt))
        for outcome in [MemberOperationOutcome.committed(settlement), .settledElsewhere(settlement), .settledUnverified(settlement)] {
            flow.setSession(info); XCTAssertTrue(flow.settledOffers.isEmpty)
            service.outcome = outcome
            await flow.check(flow.saved[0]); flow.closeReview()
            XCTAssertTrue(flow.settledOffers.contains(detail.id), "\(outcome)")
        }
        service.outcome = .pending("prepared"); flow.setSession(info)
        await flow.check(flow.saved[0]); XCTAssertFalse(flow.settledOffers.contains(detail.id))
    }
    /// A box settled by another route while its statement screen opens is seen as settled before preparation is offered.
    func testCheckSettledMarksABoxSettledElsewhere() async throws {
        let (flow, service, _, detail, _, info) = try flowSetup()
        await flow.checkSettled(offerID: detail.id); XCTAssertFalse(flow.settledOffers.contains(detail.id))
        var receipt = try fixture("committed")["receipt"] as! [String: Any]; receipt["offer"] = detail.id; receipt["payer"] = "another-house"
        service.settled = try JSONDecoder().decode(ProtocolSettlement.self, from: data(receipt))
        await flow.checkSettled(offerID: detail.id); XCTAssertFalse(flow.settledOffers.contains(detail.id), "another household's settlement")
        receipt["payer"] = info.household; receipt["signed_by"] = "a-presenter-this-session-does-not-hold"
        service.settled = try JSONDecoder().decode(ProtocolSettlement.self, from: data(receipt))
        await flow.checkSettled(offerID: detail.id); XCTAssertFalse(flow.settledOffers.contains(detail.id), "signed by a presenter outside the session")
        receipt["signed_by"] = info.presenters[0]
        service.settled = try JSONDecoder().decode(ProtocolSettlement.self, from: data(receipt))
        await flow.checkSettled(offerID: detail.id); XCTAssertTrue(flow.settledOffers.contains(detail.id))
    }
    func testCancellingPreparedStatementClosesApprovalWithoutSigning() async throws {
        let (flow, service, passkeys, detail, statement, _) = try flowSetup()
        await flow.prepare(detail: detail, statement: statement, disputed: [])
        await flow.cancelPrepared()
        XCTAssertFalse(flow.canApprove); XCTAssertTrue(flow.notice.contains("Review closed"))
        XCTAssertEqual(service.submissions, 0); XCTAssertEqual(passkeys.calls, 0)
    }

}
