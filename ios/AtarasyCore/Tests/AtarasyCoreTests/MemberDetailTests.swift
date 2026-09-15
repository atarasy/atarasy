import XCTest
@testable import AtarasyCore

func detailValue(_ name: String = "digital-presented") throws -> [String: Any] {
    let url = Bundle.module.url(forResource: "member-detail-responses", withExtension: "json", subdirectory: "Fixtures")!
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let cases = root["cases"] as! [[String: Any]]
    return cases.first { $0["name"] as? String == name }!["value"] as! [String: Any]
}
func decodedDetail(_ name: String = "digital-presented") throws -> MemberOfferDetail {
    let value = try detailValue(name)
    return try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house", presenter: "merchant-1")
}
private actor DetailService: MemberProposalService {
    var pending: CheckedContinuation<MemberOfferDetail, Error>?
    var observed: CheckedContinuation<Void, Never>?
    func offers(presenter: String) async throws -> [MemberOfferSummary] { [] }
    func offerDetail(id: String) async throws -> MemberOfferDetail {
        try await withCheckedThrowingContinuation { pending = $0; observed?.resume(); observed = nil }
    }
    func wait() async { if pending != nil { return }; await withCheckedContinuation { observed = $0 } }
    func release(_ result: Result<MemberOfferDetail, MemberFailure>) { let old = pending; pending = nil; old?.resume(with: result.mapError { $0 as Error }) }
}
private struct DetailVault: MemberSessionVault {
    let saved: StoredMemberSession
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { saved }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor DetailTransport: MemberHTTPTransport {
    let info: MemberSessionInfo; let data: Data
    var paths: [String] = []; var headers: [String?] = []; var status = 200
    init(info: MemberSessionInfo, data: Data) { self.info = info; self.data = data }
    func setStatus(_ status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        let path = request.url!.path; paths.append(path); headers.append(request.value(forHTTPHeaderField: "Authorization"))
        return MemberHTTPReply(url: request.url!, status: path == "/auth/session" ? 200 : status, contentType: "application/json", cacheControl: "no-store", data: path == "/auth/session" ? try JSONEncoder().encode(info) : data)
    }
}
@MainActor final class MemberDetailTests: XCTestCase {
    /// §3, question 48. `collected_as` is accepted from an engine that sends it, validated, and optional for one that does not.
    func testCollectedAsIsOptionalButWhole() throws {
        var value = try detailValue("physical-collected")
        func decode(_ v: [String: Any]) throws -> MemberOfferDetail {
            try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: v), expectedID: v["id"] as! String, household: "detail-house", presenter: "merchant-1")
        }
        XCTAssertEqual(try decode(value).collectedAsSupplied, false)
        var rows = value["candidates"] as! [[String: Any]]
        rows = rows.enumerated().map { i, r in var r = r; r["valence"] = i == 0 ? "lost" : r["valence"]; r["collected_as"] = i == 0 ? "missing" : NSNull(); return r }
        value["candidates"] = rows
        let supplied = try decode(value)
        XCTAssertEqual(supplied.collectedAsSupplied, true)
        XCTAssertEqual(supplied.candidates.map(\.collectedAs), ["missing", nil])
        var partial = value; var some = rows; some[1].removeValue(forKey: "collected_as"); partial["candidates"] = some
        XCTAssertThrowsError(try decode(partial))
        var wrong = value; var bad = rows; bad[0]["collected_as"] = "lost"; wrong["candidates"] = bad
        XCTAssertThrowsError(try decode(wrong))
    }
    func testLostOutcomeNamesTheKindOfLossOnlyWhenTheEngineSaidIt() {
        XCTAssertTrue(MemberOfferDetail.lostOutcome("missing", supplied: true).hasPrefix("Not in the box"))
        XCTAssertTrue(MemberOfferDetail.lostOutcome(nil, supplied: true).hasPrefix("Not collected by the deadline"))
        XCTAssertTrue(MemberOfferDetail.lostOutcome(nil, supplied: false).hasPrefix("Not returned"))
        XCTAssertTrue(MemberOfferDetail.lostOutcome("missing", supplied: false).hasPrefix("Not returned"))
    }

    func info(household: String = "detail-house", expiry: Int64 = 5000) -> MemberSessionInfo { .init(id: "session", household: household, presenters: ["merchant-1"], expiresAt: expiry) }
    func summary(_ value: MemberOfferDetail) -> MemberOfferSummary { .init(id: value.id, household: value.household, presenter: value.presenter, binding: value.binding, state: value.state) }
    func testCapturedDetailsPreserveGiftPartiesAndCollectionOutcomes() throws {
        let digital = try decodedDetail(), before = try decodedDetail("physical-presented"), after = try decodedDetail("physical-collected")
        XCTAssertEqual(digital.candidates[0].quantity, 2); XCTAssertEqual(digital.candidates[0].unitPrice, 1200)
        XCTAssertEqual(digital.candidates[0].maker, "made-by-tea"); XCTAssertEqual(digital.candidates[0].merchant, "maker-a")
        XCTAssertEqual(digital.candidates[1].givenBy, "fixture-giver"); XCTAssertNil(digital.priceBand)
        XCTAssertTrue(before.candidates.allSatisfy { $0.valence == "offered" })
        XCTAssertTrue(after.candidates.allSatisfy { $0.valence == "consumed" })
        XCTAssertEqual(before.expiresAt, after.expiresAt)
        XCTAssertEqual(digital.disclosures[0].items.map(\.label), ["payment", "delivery", "returns"])
    }
    func testMissingNullableFieldsAreNotTreatedAsNull() throws {
        var value = try detailValue(); value.removeValue(forKey: "price_band")
        XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house"))
        value = try detailValue(); var rows = value["candidates"] as! [[String: Any]]; rows[0].removeValue(forKey: "given_by"); value["candidates"] = rows
        XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house"))
    }
    func testUnsafeNumbersDuplicatesAndUnknownStateAreRefused() throws {
        for (key, bad) in [("quantity", 0 as Any), ("quantity", 1.5 as Any), ("unit_price", -1 as Any), ("unit_price", 9_007_199_254_740_992 as Any), ("valence", "unknown" as Any)] {
            var value = try detailValue(); var rows = value["candidates"] as! [[String: Any]]; rows[0][key] = bad; value["candidates"] = rows
            XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house"))
        }
        var value = try detailValue(); let rows = value["candidates"] as! [[String: Any]]; value["candidates"] = [rows[0], rows[0]]
        XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house"))
    }
    func testDetailScopeMustMatchExactResourceAndHousehold() throws {
        let value = try detailValue(), data = try JSONSerialization.data(withJSONObject: value)
        XCTAssertThrowsError(try MemberOfferDetail.decode(data, expectedID: value["id"] as! String, household: "other-house"))
        XCTAssertThrowsError(try MemberOfferDetail.decode(data, expectedID: "other-offer", household: "detail-house"))
        XCTAssertThrowsError(try MemberOfferDetail.decode(data, expectedID: value["id"] as! String, household: "detail-house", presenter: "other"))
    }
    func testDisclosurePlainTextAndProductContextArePreserved() throws {
        var value = try detailValue(); var blocks = value["disclosures"] as! [[String: Any]]
        blocks[0]["items"] = [["label": "<b>terms</b>", "value": "[label](https://example.invalid)"]]; value["disclosures"] = blocks
        let decoded = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house")
        XCTAssertEqual(decoded.disclosures[0].items[0].label, "<b>terms</b>")
        blocks[0]["product"] = "unrelated-product"; value["disclosures"] = blocks
        XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house"))
    }
    func testClientFetchesActualProjectionWithBearerAndPreservesRefusal() async throws {
        let value = try decodedDetail(), transport = DetailTransport(info: info(), data: try JSONSerialization.data(withJSONObject: detailValue()))
        let vault = DetailVault(saved: .init(token: "amr1_" + String(repeating: "A", count: 43), info: info()))
        let client = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: transport, vault: vault, now: { 1000 })
        _ = try await client.restore(household: "detail-house")
        let detail = try await client.offerDetail(id: value.id); XCTAssertEqual(detail, value)
        let paths = await transport.paths, headers = await transport.headers
        XCTAssertEqual(paths, ["/auth/session", "/offers/" + value.id]); XCTAssertTrue(headers.allSatisfy { $0?.hasPrefix("Bearer amr1_") == true })
        await transport.setStatus(404)
        do { _ = try await client.offerDetail(id: value.id); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .http(404)) }
    }
    func testLeavingDetailDiscardsLateSuccess() async throws {
        let service = DetailService()
        let active = MemberProposals(service: service, now: { 1000 }); active.setSession(info())
        let detail = try decodedDetail(), selected = summary(detail)
        let reading = Task { await active.loadDetail(selected) }; await service.wait()
        active.clearDetail(); await service.release(.success(detail)); await reading.value
        XCTAssertNil(active.detail); XCTAssertFalse(active.detailLoading)
    }
    func testOld401DoesNotInvalidateReplacementSession() async throws {
        let service = DetailService()
        let active = MemberProposals(service: service, now: { 1000 }); active.setSession(info())
        let selected = summary(try decodedDetail()); let reading = Task { await active.loadDetail(selected) }; await service.wait()
        active.setSession(info(household: "other")); let current = active.sessionIdentity
        await service.release(.failure(.http(401))); await reading.value
        XCTAssertEqual(active.sessionIdentity, current); XCTAssertNil(active.detail)
    }
    func testCurrent401AndExpiryClearDetailSession() async throws {
        let service = DetailService(); var clock: Int64 = 1000
        let model = MemberProposals(service: service, now: { clock }), value = try decodedDetail()
        model.setSession(info()); let first = Task { await model.loadDetail(summary(value)) }; await service.wait()
        await service.release(.failure(.http(401))); await first.value; XCTAssertNil(model.sessionIdentity)
        model.setSession(info(expiry: 2000)); let second = Task { await model.loadDetail(summary(value)) }; await service.wait()
        clock = 2000; await service.release(.success(value)); await second.value
        XCTAssertNil(model.sessionIdentity); XCTAssertNil(model.detail)
    }
    func testDetailFailureNeverFallsBackToPreviousData() async throws {
        let service = DetailService()
        let active = MemberProposals(service: service, now: { 1000 }); active.setSession(info())
        let value = try decodedDetail(); let first = Task { await active.loadDetail(summary(value)) }; await service.wait()
        await service.release(.success(value)); await first.value; XCTAssertNotNil(active.detail)
        let second = Task { await active.loadDetail(summary(value)) }; await service.wait(); XCTAssertNil(active.detail)
        await service.release(.failure(.unavailable)); await second.value
        XCTAssertNil(active.detail); XCTAssertTrue(active.detailUnavailable)
    }
}
