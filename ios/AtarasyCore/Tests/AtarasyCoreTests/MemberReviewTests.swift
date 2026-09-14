import XCTest
@testable import AtarasyCore

func reviewValue(_ name: String) throws -> [String: Any] {
    let url = Bundle.module.url(forResource: "member-review-responses", withExtension: "json", subdirectory: "Fixtures")!
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return (root["cases"] as! [[String: Any]]).first { $0["name"] as? String == name }!["value"] as! [String: Any]
}
func reviewDetail(_ binding: String) throws -> MemberOfferDetail {
    let value = try reviewValue(binding + "-detail")
    return try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house")
}
private actor ReviewService: MemberProposalService {
    let detail: MemberOfferDetail
    var pending: CheckedContinuation<MemberReview, Error>?
    var observed: CheckedContinuation<Void, Never>?
    init(_ detail: MemberOfferDetail) { self.detail = detail }
    func offers(presenter: String) async throws -> [MemberOfferSummary] { [] }
    func offerDetail(id: String) async throws -> MemberOfferDetail { detail }
    func review(detail: MemberOfferDetail) async throws -> MemberReview { try await withCheckedThrowingContinuation { pending = $0; observed?.resume(); observed = nil } }
    func wait() async { if pending != nil { return }; await withCheckedContinuation { observed = $0 } }
    func release(_ result: Result<MemberReview, MemberFailure>) { let old = pending; pending = nil; old?.resume(with: result.mapError { $0 as Error }) }
}
private actor ReviewTransport: MemberHTTPTransport {
    var requests: [URLRequest] = []
    let payload: Data; var status = 200
    init(_ payload: Data) { self.payload = payload }
    func setStatus(_ value: Int) { status = value }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let session = Data(#"{"id":"session","household":"detail-house","presenters":["merchant-1"],"expiresAt":5000}"#.utf8)
        return .init(url: request.url!, status: request.url!.path == "/auth/session" ? 200 : status, contentType: "application/json", cacheControl: "no-store", data: request.url!.path == "/auth/session" ? session : payload)
    }
}
private struct ReviewVault: MemberSessionVault {
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: .init(id: "session", household: "detail-house", presenters: ["merchant-1"], expiresAt: 5000)) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
@MainActor final class MemberReviewTests: XCTestCase {
    func data(_ name: String) throws -> Data { try JSONSerialization.data(withJSONObject: reviewValue(name)) }
    func testActualApprovalPreservesAlternativesExclusionsAndNilVersusZero() throws {
        let detail = try reviewDetail("digital")
        let unknown = try MemberApproval.decode(data("digital-unknown-carriage"), detail: detail)
        let known = try MemberApproval.decode(data("digital-known-carriage"), detail: detail)
        XCTAssertNil(unknown.carriage); XCTAssertEqual(known.carriage, 0)
        XCTAssertEqual(known.candidates[0].alternatives.count, 2); XCTAssertEqual(known.candidates[0].argumentAgainst, "Existing supplies may already be sufficient.")
        XCTAssertEqual(known.excluded[0].reason, "auto_renewal"); XCTAssertEqual(known.mandate.kind, "standing"); XCTAssertNotNil(known.mandate.lapsesAt)
        XCTAssertEqual(known.candidates[1].givenBy, "fixture-giver")
        XCTAssertTrue(known.disclosures.contains { $0.product == nil }); XCTAssertTrue(known.disclosures.contains { $0.product == "tea-b" })
        XCTAssertEqual(known.candidates[1].disclosure.product, "tea-b")
    }
    func testActualStatementChecksChallengeGiftAndUnknownCarriage() throws {
        let detail = try reviewDetail("physical")
        let unknown = try MemberStatement.decode(data("physical-unknown-carriage"), detail: detail)
        let known = try MemberStatement.decode(data("physical-known-carriage"), detail: detail)
        XCTAssertNil(unknown.carriage); XCTAssertEqual(known.carriage, 550)
        XCTAssertNotEqual(unknown.challenge, known.challenge)
        XCTAssertEqual(known.lines.map(\.amount), [3000, 0]); XCTAssertEqual(known.lines.map(\.valence), ["consumed", "consumed"])
        XCTAssertEqual(known.lines[1].disclosure.product, "miso-a")
    }
    func testStatementTamperedChallengeIsRejected() throws {
        var value = try reviewValue("physical-known-carriage"); value["challenge"] = String(repeating: "A", count: 43)
        XCTAssertThrowsError(try MemberStatement.decode(JSONSerialization.data(withJSONObject: value), detail: reviewDetail("physical")))
    }
    func testCorrectlyRehashedStatementStillRejectsWrongGoodsAndGiftCharges() throws {
        let detail = try reviewDetail("physical")
        for index in [0, 1] {
            var value = try reviewValue("physical-known-carriage"), rows = value["lines"] as! [[String: Any]]
            rows[index]["amount"] = 1; value["lines"] = rows
            let lines = rows.map { StatementLine(candidate: $0["candidate"] as! String, valence: $0["valence"] as! String, amount: ($0["amount"] as! NSNumber).int64Value, disputed: false) }
            value["challenge"] = Canonical.challenge(try Canonical.statement(offer: detail.id, carriage: 550, lines: lines))
            XCTAssertThrowsError(try MemberStatement.decode(JSONSerialization.data(withJSONObject: value), detail: detail))
        }
    }
    func testReviewRejectsMissingNullsWrongScopeAndChangedTerms() throws {
        for binding in ["digital", "physical"] {
            let detail = try reviewDetail(binding)
            let original = try reviewValue(binding + "-known-carriage")
            for key in ["carriage", binding == "digital" ? "price_band" : "household"] {
                var value = original; value.removeValue(forKey: key)
                XCTAssertThrowsError(try decode(value, detail: detail))
            }
            for (key, bad) in [("offer", "foreign" as Any), ("expires_at", 0 as Any), ("carriage", -1 as Any), ("carriage", 9_007_199_254_740_992 as Any)] {
                var value = original; value[key] = bad; XCTAssertThrowsError(try decode(value, detail: detail))
            }
            let rowKey = binding == "digital" ? "candidates" : "lines"
            for field in ["unit_price", "quantity", "maker", "given_by", "valence", "disclosure"] {
                var value = original; var rows = value[rowKey] as! [[String: Any]]
                rows[0][field] = field == "quantity" || field == "unit_price" ? 999 : "changed"; value[rowKey] = rows
                XCTAssertThrowsError(try decode(value, detail: detail))
            }
            var value = original; let rows = value[rowKey] as! [[String: Any]]; value[rowKey] = [rows[0], rows[0]]
            XCTAssertThrowsError(try decode(value, detail: detail))
            value = original; value[rowKey] = []; XCTAssertThrowsError(try decode(value, detail: detail))
        }
    }
    func testApprovalRejectsEmptyDeliberationAndMissingStandingLapse() throws {
        let detail = try reviewDetail("digital")
        for (key, bad) in [("alternatives", [] as Any), ("argument_against", "  " as Any), ("alternatives", [""] as Any)] {
            var value = try reviewValue("digital-known-carriage"), rows = value["candidates"] as! [[String: Any]]
            rows[0][key] = bad; value["candidates"] = rows; XCTAssertThrowsError(try decode(value, detail: detail))
        }
        var value = try reviewValue("digital-known-carriage"); value["mandate"] = ["kind": "standing", "scope": "supplies", "lapses_at": NSNull()]
        XCTAssertThrowsError(try decode(value, detail: detail))
        value = try reviewValue("digital-known-carriage"); value["excluded"] = [["product": "other", "reason": "commercial_preference"]]
        XCTAssertThrowsError(try decode(value, detail: detail))
    }
    func testDisclosureOmissionOrWrongGoverningBlockIsRejected() throws {
        for binding in ["digital", "physical"] {
            let detail = try reviewDetail(binding); var value = try reviewValue(binding + "-known-carriage")
            value["disclosures"] = []; XCTAssertThrowsError(try decode(value, detail: detail))
            value = try reviewValue(binding + "-known-carriage"); let key = binding == "digital" ? "candidates" : "lines"
            var rows = value[key] as! [[String: Any]]; rows[1]["disclosure"] = ["merchant": "maker-a", "product": NSNull()]; value[key] = rows
            XCTAssertThrowsError(try decode(value, detail: detail))
        }
    }
    func testClientUsesNamedBearerReadsAndPreservesMissingDeliberation() async throws {
        for binding in ["digital", "physical"] {
            let transport = ReviewTransport(try data(binding + "-known-carriage")), detail = try reviewDetail(binding)
            let client = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: transport, vault: ReviewVault(), now: { 1000 })
            _ = try await client.restore(household: "detail-house"); _ = try await client.review(detail: detail)
            let requests = await transport.requests
            XCTAssertEqual(requests.last?.url?.path, "/offers/" + detail.id + (binding == "physical" ? "/statement" : "/approval"))
            XCTAssertEqual(requests.last?.httpMethod, "GET"); XCTAssertNil(requests.last?.httpBody); XCTAssertTrue(requests.last?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer amr1_") == true)
            await transport.setStatus(422)
            do { _ = try await client.review(detail: detail); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .http(422)) }
        }
    }
    /// A settled box has nothing to sign: its review is the settlement that stands, read from
    /// the settlement route, and never a statement to prepare.
    func testSettledPhysicalBoxReviewsItsSettlementNotAStatement() async throws {
        var detailValue = try reviewValue("physical-detail"); detailValue["state"] = "settled"
        let detail = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: detailValue), expectedID: detailValue["id"] as! String, household: "detail-house")
        let url = Bundle.module.url(forResource: "member-operation-runtime", withExtension: "json", subdirectory: "Fixtures")!
        let runtime = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var receipt = (runtime["committed"] as! [String: Any])["receipt"] as! [String: Any]
        receipt["offer"] = detail.id; receipt["payer"] = detail.household
        let transport = ReviewTransport(try JSONSerialization.data(withJSONObject: receipt))
        let client = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: transport, vault: ReviewVault(), now: { 1000 })
        _ = try await client.restore(household: "detail-house")
        guard case .settlement(let settled) = try await client.review(detail: detail) else { return XCTFail("A settled box was reviewed as something to sign") }
        XCTAssertEqual(settled.charged, 1200)
        let requests = await transport.requests; XCTAssertEqual(requests.last?.url?.path, "/offers/" + detail.id + "/settlement")
        receipt["payer"] = "another-house"
        let foreign = ReviewTransport(try JSONSerialization.data(withJSONObject: receipt))
        let other = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: foreign, vault: ReviewVault(), now: { 1000 })
        _ = try await other.restore(household: "detail-house")
        do { _ = try await other.review(detail: detail); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .scopeMismatch) }
        // A gift box is paid for by its giver, and its settlement is still this household's to see.
        detailValue["purpose"] = "ceremonial"; detailValue["giver"] = "giver-1"; detailValue["price_band"] = ["min": 0, "max": 5000]
        let gift = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: detailValue), expectedID: detailValue["id"] as! String, household: "detail-house")
        receipt["payer"] = "giver-1"
        let giftTransport = ReviewTransport(try JSONSerialization.data(withJSONObject: receipt))
        let giftClient = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: giftTransport, vault: ReviewVault(), now: { 1000 })
        _ = try await giftClient.restore(household: "detail-house")
        guard case .settlement = try await giftClient.review(detail: gift) else { return XCTFail("A settled gift box was refused") }
    }
    func testReviewDepartureAndReplacementDiscardLateReply() async throws {
        for replace in [false, true] {
            let detail = try reviewDetail("physical"), service = ReviewService(try reviewDetail("physical"))
            let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info())
            let task = Task { await model.loadReview(summary(detail)) }; await service.wait()
            if replace { model.setSession(info()) } else { model.clearDetail() }
            let identity = model.sessionIdentity
            await service.release(replace ? .failure(.http(401)) : .success(try decode(reviewValue("physical-known-carriage"), detail: detail)))
            await task.value; XCTAssertNil(model.review); XCTAssertFalse(model.reviewLoading); XCTAssertEqual(identity, model.sessionIdentity)
        }
    }
    func testCurrentReviewFailureAndExpiryNeverRetainReview() async throws {
        for failure in [MemberFailure.http(422), .http(401), .expired] {
            let detail = try reviewDetail("digital"), service = ReviewService(try reviewDetail("digital"))
            let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info())
            let task = Task { await model.loadReview(summary(detail)) }; await service.wait(); await service.release(.failure(failure)); await task.value
            XCTAssertNil(model.review); XCTAssertEqual(model.sessionIdentity == nil, failure != .http(422)); XCTAssertEqual(model.reviewUnavailable, failure == .http(422))
        }
        var now: Int64 = 1000
        let detail = try reviewDetail("digital"), service = ReviewService(try reviewDetail("digital"))
        let model = MemberProposals(service: service, now: { now }); model.setSession(info())
        let task = Task { await model.loadReview(summary(detail)) }; await service.wait(); now = 5000
        await service.release(.success(try decode(reviewValue("digital-known-carriage"), detail: detail))); await task.value
        XCTAssertNil(model.review); XCTAssertNil(model.sessionIdentity)
    }
    private func decode(_ value: [String: Any], detail: MemberOfferDetail) throws -> MemberReview {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try detail.binding == "digital" ? .approval(MemberApproval.decode(data, detail: detail)) : .statement(MemberStatement.decode(data, detail: detail))
    }
    private func info() -> MemberSessionInfo { .init(id: "session", household: "detail-house", presenters: ["merchant-1"], expiresAt: 5000) }
    private func summary(_ detail: MemberOfferDetail) -> MemberOfferSummary { .init(id: detail.id, household: detail.household, presenter: detail.presenter, binding: detail.binding, state: detail.state) }
}
