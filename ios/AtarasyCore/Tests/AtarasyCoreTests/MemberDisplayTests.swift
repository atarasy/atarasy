import XCTest
@testable import AtarasyCore

private actor UnionService: MemberProposalService {
    let answers: [String: [MemberOfferSummary]]
    init(_ answers: [String: [MemberOfferSummary]]) { self.answers = answers }
    func offers(presenter: String) async throws -> [MemberOfferSummary] { answers[presenter] ?? [] }
}

/// Vault `80`: the inbox is one list over every presenter, and a row can name what it holds.
@MainActor final class MemberDisplayTests: XCTestCase {
    private func row(_ presenter: String, _ id: String, binding: String = "digital", at: Int64) -> MemberOfferSummary {
        MemberOfferSummary(id: id, household: "home", presenter: presenter, binding: binding, state: "presented", presentedAt: at)
    }

    // 04b §1b.2, clause 14. The session's presenter order must not decide the list order.
    func testRowsInterleaveTwoPresentersByArrivalNotBySessionOrder() async {
        let service = UnionService([
            "first": [row("first", "a-old", at: 100), row("first", "a-new", at: 400)],
            "second": [row("second", "b-mid", at: 300), row("second", "b-box", binding: "physical", at: 200)],
        ])
        let model = MemberProposals(service: service, now: { 1000 })
        model.setSession(MemberSessionInfo(id: "s", household: "home", presenters: ["first", "second"], expiresAt: 5000))
        await model.refresh()
        XCTAssertEqual(model.rows(binding: "digital").map(\.id), ["a-new", "b-mid", "a-old"])
        XCTAssertEqual(model.rows(binding: "physical").map(\.id), ["b-box"])
        // Listing the presenters the other way round changes nothing.
        model.setSession(MemberSessionInfo(id: "s2", household: "home", presenters: ["second", "first"], expiresAt: 5000))
        await model.refresh()
        XCTAssertEqual(model.rows(binding: "digital").map(\.id), ["a-new", "b-mid", "a-old"])
    }

    func testSummaryReadsRowFieldsAndToleratesTheirAbsence() throws {
        let full = Data(#"{"id":"o","household":"h","presenter":"p","binding":"physical","state":"presented","presented_at":10,"expires_at":20,"candidates":[{"product":"tea","merchant":"Shop","quantity":2,"unit_price":300,"given_by":null,"valence":"consumed","collected_as":"consumed","name":"Sencha","variant":"100g","maker":"x"}]}"#.utf8)
        let value = try JSONDecoder().decode(MemberOfferSummary.self, from: full)
        XCTAssertEqual(value.presentedAt, 10); XCTAssertEqual(value.expiresAt, 20)
        XCTAssertEqual(value.candidates?.first?.name, "Sencha"); XCTAssertEqual(value.candidates?.first?.variant, "100g")
        let bare = try JSONDecoder().decode(MemberOfferSummary.self, from: Data(#"{"id":"o","household":"h","presenter":"p","binding":"digital","state":"presented"}"#.utf8))
        XCTAssertNil(bare.candidates); XCTAssertEqual(bare.arrivedAt, 0)
    }

    func testDetailAcceptsADisplayNameAndRefusesAnEmptyOne() throws {
        var value = try detailValue()
        var candidates = value["candidates"] as! [[String: Any]]
        candidates[0]["name"] = "Sencha"; candidates[0]["variant"] = "100g"
        value["candidates"] = candidates
        let named = try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house", presenter: "merchant-1")
        XCTAssertEqual(named.candidates[0].name, "Sencha"); XCTAssertEqual(named.candidates[0].variant, "100g")
        XCTAssertNil(named.candidates[1].name)

        candidates[0]["name"] = "  "; value["candidates"] = candidates
        XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house", presenter: "merchant-1"))
        candidates[0]["name"] = String(repeating: "x", count: 121); value["candidates"] = candidates
        XCTAssertThrowsError(try MemberOfferDetail.decode(JSONSerialization.data(withJSONObject: value), expectedID: value["id"] as! String, household: "detail-house", presenter: "merchant-1"))
    }

    // A name travels outside every signed form, so adding one must not move the terms digest of an offer that has none.
    func testTermsDigestIgnoresAbsentNames() throws {
        let detail = try decodedDetail()
        XCTAssertEqual(try digitalTermsDigest(detail), try digitalTermsDigest(try decodedDetail()))
        XCTAssertFalse(String(decoding: try digitalJSON(detail), as: UTF8.self).contains("\"name\""))
    }

    func testSettlementLineNameMustBeText() throws {
        func body(_ extra: String) -> Data {
            Data(#"{"offer":"o","settled_at":1,"kept_amount":0,"consumed_amount":300,"lost_amount":0,"charged":300,"disputed_amount":0,"lines":[{"candidate":"c","product":"tea","merchant":"m","maker":"k","ships":"s","valence":"consumed","amount":300,"disputed":false\#(extra)}],"payer":"h","signed_by":"h","signed_as":"agent","receipt":"r","confirmation":null}"#.utf8)
        }
        let named = try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: body(#","name":"Sencha""#), expectedOffer: "o")
        XCTAssertEqual(named.lines[0].name, "Sencha")
        XCTAssertNoThrow(try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: body(""), expectedOffer: "o"))
        XCTAssertThrowsError(try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: body(#","name":3"#), expectedOffer: "o"))
        XCTAssertThrowsError(try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: body(#","colour":"red""#), expectedOffer: "o"))
    }
}

/// The package's notices are looked up in its own tables, so a Japanese member reads Japanese.
final class MemberCopyTests: XCTestCase {
    func testEveryNoticeHasAJapaneseEntry() throws {
        func table(_ lang: String) throws -> [String: String] {
            let url = try XCTUnwrap(AtarasyCoreResources.url(lang))
            return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        }
        let en = try table("en"), ja = try table("ja")
        XCTAssertEqual(Set(en.keys), Set(ja.keys))
        XCTAssertFalse(en.isEmpty)
        for (key, value) in ja { XCTAssertNotEqual(value, key, "untranslated: \(key)") }
    }
}
