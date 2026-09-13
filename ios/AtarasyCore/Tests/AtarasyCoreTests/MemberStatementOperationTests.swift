import XCTest
@testable import AtarasyCore

private func transactionValue(_ name: String) throws -> [String: Any] {
    let url = Bundle.module.url(forResource: "member-transaction-responses", withExtension: "json", subdirectory: "Fixtures")!
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return (root["cases"] as! [[String: Any]]).first { $0["name"] as? String == name }!["value"] as! [String: Any]
}
private struct OperationVault: MemberSessionVault {
    let info: MemberSessionInfo
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: info) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor OperationTransport: MemberHTTPTransport {
    let info: MemberSessionInfo; let payload: Data
    var requests: [URLRequest] = []; var status = 200; var hold = false
    var pending: CheckedContinuation<Void, Never>?; var observed: CheckedContinuation<Void, Never>?
    init(info: MemberSessionInfo, payload: Data) { self.info = info; self.payload = payload }
    func configure(status: Int = 200, hold: Bool = false) { self.status = status; self.hold = hold }
    func wait() async { if pending != nil { return }; await withCheckedContinuation { observed = $0 } }
    func release() { let old = pending; pending = nil; old?.resume() }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        if request.url!.path == "/auth/session" { return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: try JSONEncoder().encode(info)) }
        if hold { await withCheckedContinuation { pending = $0; observed?.resume(); observed = nil } }
        return .init(url: request.url!, status: status, contentType: "application/json", cacheControl: "no-store", data: payload)
    }
}
@MainActor final class MemberStatementOperationTests: XCTestCase {
    func environment(_ name: String = "test") throws -> MemberEnvironment { try .init(name: name, origin: URL(string: "https://unit.example")!) }
    func session(_ id: String = "session", household: String = "detail-house", expiry: Int64 = 5000) -> MemberSessionInfo { .init(id: id, household: household, presenters: ["merchant-1"], expiresAt: expiry) }
    func detail(_ name: String = "physical-detail") throws -> MemberOfferDetail {
        let value = try transactionValue(name)
        return try .decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house")
    }
    func statement(_ name: String = "physical-known-carriage") throws -> MemberStatement { try .decode(JSONSerialization.data(withJSONObject: transactionValue(name)), detail: detail()) }
    func prepared(dispute: Bool = true) throws -> PreparedMemberStatement {
        let d = try detail()
        return try .init(environment: environment(), session: session(), detail: d, statement: statement(), disputed: dispute ? [d.candidates[0].id] : [], now: 1000)
    }
    func receipt(_ value: [String: Any]? = nil) throws -> ProtocolSettlement {
        let value = try value ?? transactionValue("physical-settlement")
        return try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: JSONSerialization.data(withJSONObject: value), expectedOffer: detail().id)
    }
    func pending() throws -> PendingMemberStatement { try .init(prepared: prepared(), submittedSignature: receipt().confirmation!) }
    func testPreparationPreservesDisputedCanonicalAmountAndZeroGift() throws {
        let p = try prepared(), undisputed = try prepared(dispute: false)
        XCTAssertEqual(p.goodsCharged, 0); XCTAssertEqual(p.disputedGoods, 3000); XCTAssertEqual(p.carriage, 550)
        XCTAssertTrue(p.canonical.contains(":consumed:3000:disputed")); XCTAssertTrue(p.canonical.contains(":consumed:0:"))
        XCTAssertNotEqual(p.challenge, undisputed.challenge); XCTAssertEqual(undisputed.goodsCharged, 3000)
        XCTAssertEqual(undisputed.challenge, try statement().challenge)
    }
    func testPreparationRefusesUnknownCarriageScopeExpiryAndInvalidDisputes() throws {
        let d = try detail(), s = try statement()
        XCTAssertThrowsError(try PreparedMemberStatement(environment: environment(), session: session(), detail: d, statement: statement("physical-unknown-carriage"), disputed: [], now: 1000))
        XCTAssertThrowsError(try PreparedMemberStatement(environment: environment(), session: session(household: "foreign"), detail: d, statement: s, disputed: [], now: 1000))
        XCTAssertThrowsError(try PreparedMemberStatement(environment: environment(), session: session(expiry: 1000), detail: d, statement: s, disputed: [], now: 1000))
        for choices in [["foreign"], [d.candidates[0].id, d.candidates[0].id]] {
            XCTAssertThrowsError(try PreparedMemberStatement(environment: environment(), session: session(), detail: d, statement: s, disputed: choices, now: 1000))
        }
    }
    func testPreparationRefusesUnresolvedOrChangedDetail() throws {
        for (key, bad) in [("state", "presented"), ("binding", "digital")] {
            var value = try transactionValue("physical-detail"); value[key] = bad
            let d = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house")
            XCTAssertThrowsError(try PreparedMemberStatement(environment: environment(), session: session(), detail: d, statement: statement(), disputed: [], now: 1000))
        }
        var value = try transactionValue("physical-detail"), rows = value["candidates"] as! [[String: Any]]
        rows[0]["valence"] = "offered"; value["candidates"] = rows
        let d = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house")
        XCTAssertThrowsError(try PreparedMemberStatement(environment: environment(), session: session(), detail: d, statement: statement(), disputed: [], now: 1000))
    }
    func testLostGiftIsStockLossRatherThanGoodsCharged() throws {
        var object = try transactionValue("physical-detail"), candidates = object["candidates"] as! [[String: Any]]
        candidates[1]["valence"] = "lost"; object["candidates"] = candidates
        let d = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: object), expectedID: object["id"] as! String, household: "detail-house")
        var statementObject = try transactionValue("physical-known-carriage")
        let first = (statementObject["lines"] as! [[String: Any]])[0]
        statementObject["lines"] = [first]
        statementObject["challenge"] = Canonical.challenge(try Canonical.statement(offer: d.id, carriage: 550, lines: [.init(candidate: d.candidates[0].id, valence: "consumed", amount: 3000, disputed: false)]))
        let s = try MemberStatement.decode(JSONSerialization.data(withJSONObject: statementObject), detail: d)
        let prepared = try PreparedMemberStatement(environment: environment(), session: session(), detail: d, statement: s, disputed: [d.candidates[0].id], now: 1000)
        XCTAssertEqual(prepared.goodsCharged, 0)
        var record = try transactionValue("physical-settlement"), lines = record["lines"] as! [[String: Any]]
        lines[1]["valence"] = "lost"; lines[1]["amount"] = 700; record["lines"] = lines; record["lost_amount"] = 700
        let r = try receipt(record), p = try PendingMemberStatement(prepared: prepared, submittedSignature: r.confirmation!)
        XCTAssertEqual(p.inspect(r), .matchingProtocolRecord(r))
    }
    func testExactConfirmationAndCompleteReceiptMatchActualReadback() throws {
        let pending = try pending(), receipt = try receipt()
        XCTAssertEqual(pending.inspect(receipt), .matchingProtocolRecord(receipt))
        XCTAssertEqual(try self.receipt(transactionValue("physical-settlement-read-again")), receipt)
        XCTAssertFalse(pending.confirmationFingerprint.contains(receipt.confirmation!))
    }
    func testDifferentConfirmationNeverConfirmsSameOfferAndAmounts() throws {
        var value = try transactionValue("physical-settlement"); value["confirmation"] = Data("other public signature".utf8).base64EncodedString()
        XCTAssertEqual(try pending().inspect(receipt(value)), .differentConfirmation)
        value["confirmation"] = NSNull(); XCTAssertEqual(try pending().inspect(receipt(value)), .differentConfirmation)
    }
    func testBalancedButAlteredReceiptAndForeignPartiesAreRefused() throws {
        let pending = try pending()
        for key in ["payer", "signed_by"] {
            var value = try transactionValue("physical-settlement"); value[key] = "foreign"
            XCTAssertEqual(try pending.inspect(receipt(value)), .inconsistentRecord)
        }
        var value = try transactionValue("physical-settlement"), rows = value["lines"] as! [[String: Any]]
        rows[0]["product"] = "other-product"; value["lines"] = rows
        XCTAssertEqual(try pending.inspect(receipt(value)), .inconsistentRecord)
        value = try transactionValue("physical-settlement"); rows = value["lines"] as! [[String: Any]]
        rows[0]["amount"] = 1; value["lines"] = rows; value["disputed_amount"] = 1
        XCTAssertEqual(try pending.inspect(receipt(value)), .inconsistentRecord)
        value = try transactionValue("physical-settlement"); rows = value["lines"] as! [[String: Any]]
        rows[1]["amount"] = 5; value["lines"] = rows; value["consumed_amount"] = 5; value["charged"] = 5
        XCTAssertEqual(try pending.inspect(receipt(value)), .inconsistentRecord)
    }
    func testClientOnlyReadsAndMissingOrFailedReadRemainsUnresolved() async throws {
        let transport = OperationTransport(info: session(), payload: try JSONSerialization.data(withJSONObject: transactionValue("physical-settlement")))
        let client = MemberClient(environment: try environment(), transport: transport, vault: OperationVault(info: session()), now: { 1000 })
        _ = try await client.restore(household: "detail-house")
        let p = try pending(); let success = await client.reconcile(p); XCTAssertEqual(success, try .matchingProtocolRecord(receipt()))
        for code in [404, 409, 422, 500] { await transport.configure(status: code); let result = await client.reconcile(p); XCTAssertEqual(result, .unresolved) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.url?.path == "/offers/" + p.prepared.offer + "/settlement" })
        await transport.configure(status: 401)
        let revoked = await client.reconcile(p); XCTAssertEqual(revoked, .sessionUnavailable)
        let again = await client.reconcile(p); XCTAssertEqual(again, .sessionUnavailable)
        let finalRequests = await transport.requests; XCTAssertEqual(finalRequests.count, 7)

    }
    func testWrongEnvironmentOrReplacementSessionSendsNoRead() async throws {
        for (env, info) in [(try environment("other"), session()), (try environment(), session("replacement"))] {
            let transport = OperationTransport(info: info, payload: Data())
            let client = MemberClient(environment: env, transport: transport, vault: OperationVault(info: info), now: { 1000 })
            _ = try await client.restore(household: "detail-house")
            let result = await client.reconcile(try pending()); XCTAssertEqual(result, .sessionUnavailable)
            let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
        }
    }
    func testCancelledReadCannotPublishMatchingReceipt() async throws {
        let transport = OperationTransport(info: session(), payload: try JSONSerialization.data(withJSONObject: transactionValue("physical-settlement")))
        let client = MemberClient(environment: try environment(), transport: transport, vault: OperationVault(info: session()), now: { 1000 })
        _ = try await client.restore(household: "detail-house"); await transport.configure(hold: true)
        let p = try pending(); let task = Task { await client.reconcile(p) }; await transport.wait()
        task.cancel(); await transport.release()
        let result = await task.value; XCTAssertEqual(result, .unresolved)
    }
    func testLateReceiptAfterSessionRestoreCannotConfirm() async throws {
        let transport = OperationTransport(info: session(), payload: try JSONSerialization.data(withJSONObject: transactionValue("physical-settlement")))
        let client = MemberClient(environment: try environment(), transport: transport, vault: OperationVault(info: session()), now: { 1000 })
        _ = try await client.restore(household: "detail-house"); await transport.configure(hold: true)
        let p = try pending(); let task = Task { await client.reconcile(p) }; await transport.wait()
        _ = try await client.restore(household: "detail-house"); await transport.release()
        let result = await task.value; XCTAssertEqual(result, .sessionUnavailable)
    }
}
