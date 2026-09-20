import XCTest
@testable import AtarasyCore

final class MemberDigitalDraftTests: XCTestCase {
    private func approval(_ name: String = "digital-known-carriage") throws -> MemberApproval {
        try MemberApproval.decode(JSONSerialization.data(withJSONObject: reviewValue(name)), detail: reviewDetail("digital"))
    }
    private func selected(_ approval: MemberApproval) throws -> MemberDigitalDraft {
        var draft = MemberDigitalDraft(approval: approval)
        for c in approval.candidates { try draft.choose(.keep, candidate: c.id) }
        return draft
    }
    func testEveryChoiceMustBeExplicitAndDiscardRestoresUndecided() throws {
        let value = try approval()
        var draft = MemberDigitalDraft(approval: value)
        XCTAssertThrowsError(try draft.summary(now: 1))
        try draft.choose(.decline, candidate: value.candidates[0].id)
        XCTAssertThrowsError(try draft.summary(now: 1))
        for c in value.candidates { try draft.choose(.decline, candidate: c.id) }
        XCTAssertEqual(try draft.summary(now: 1).goods, 0)
        XCTAssertThrowsError(try draft.choose(.keep, candidate: "another-offer-candidate"))
        draft.discard()
        for c in value.candidates { XCTAssertEqual(draft.choice(for: c.id), .undecided) }
        XCTAssertThrowsError(try draft.summary(now: 1))
    }
    func testGiftCostsZeroAndOnlyKeptPaidLinesContribute() throws {
        let value = try approval()
        var draft = try selected(value)
        let paid = value.candidates.filter { $0.givenBy == nil }
        XCTAssertTrue(value.candidates.contains { $0.givenBy != nil })
        let expected = paid.reduce(Int64(0)) { $0 + $1.quantity * $1.unitPrice }
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(try draft.summary(now: 1).goods, expected)
        XCTAssertEqual(try draft.summary(now: 1).total, expected + value.carriage!)
        for c in paid { try draft.choose(.decline, candidate: c.id) }
        XCTAssertEqual(try draft.summary(now: 1).goods, 0)
    }
    func testUnknownCarriageAndExpiredOfferOrMandateCannotProduceTotal() throws {
        XCTAssertThrowsError(try selected(approval("digital-unknown-carriage")).summary(now: 1))
        let value = try approval()
        let draft = try selected(value)
        XCTAssertThrowsError(try draft.summary(now: value.expiresAt))
        XCTAssertThrowsError(try draft.summary(now: value.mandate.lapsesAt!))
        XCTAssertThrowsError(try draft.summary(now: -1))
    }
    func testChangedTermsBeginWithNoChoices() throws {
        let value = try approval()
        let old = try selected(value)
        XCTAssertNoThrow(try old.summary(now: 1))
        let refreshed = MemberDigitalDraft(approval: value)
        XCTAssertThrowsError(try refreshed.summary(now: 1))
    }
    func testOverflowRefusesTotalRatherThanWrapping() throws {
        var object = try reviewValue("digital-known-carriage")
        var rows = object["candidates"] as! [[String: Any]]
        rows[0]["quantity"] = Canonical.maximumInteger
        rows[0]["unit_price"] = Canonical.maximumInteger
        object["candidates"] = rows
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(MemberApproval.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try selected(value).summary(now: 1))
        rows[0]["quantity"] = 1
        rows[0]["unit_price"] = Canonical.maximumInteger
        object["candidates"] = rows; object["carriage"] = 1
        let sum = try decoder.decode(MemberApproval.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try selected(sum).summary(now: 1))
    }
}
