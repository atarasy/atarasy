import Foundation
import XCTest
@testable import AtarasyCore

final class ReferenceResponseTests: XCTestCase {
    private func examples() throws -> [[String: Any]] {
        let url = Bundle.module.url(forResource: "response-examples", withExtension: "json", subdirectory: "Fixtures")!
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root["cases"] as! [[String: Any]]
    }
    private func example(_ id: String) throws -> [String: Any] { try examples().first { $0["id"] as? String == id }!["value"] as! [String: Any] }
    private func read(_ body: [String: Any], expected: String? = nil, status: Int = 200, type: String? = "application/json") throws -> ProtocolSettlement {
        try ReferenceResponseReader.settlement(status: status, contentType: type, data: JSONSerialization.data(withJSONObject: body), expectedOffer: expected ?? (body["offer"] as? String ?? "fixture-offer"))
    }
    func testActualReferenceReceiptsKeepGoodsDisputeAndProviderBoundaries() throws {
        let receipts = try examples().filter { $0["schema"] as? String == "SettlementResponse" }
        XCTAssertEqual(receipts.count, 6)
        for receipt in receipts { _ = try read(receipt["value"] as! [String: Any]) }
        let digital = try read(example("digital-settled"))
        XCTAssertEqual(digital.charged, 1200)
        XCTAssertNil(digital.confirmation)
        let physical = try read(example("physical-settled"))
        XCTAssertEqual(physical.charged, 0)
        XCTAssertEqual(physical.disputedAmount, 1200)
        XCTAssertEqual(physical.lines.first { $0.disputed }?.amount, 1200)
        XCTAssertEqual(try read(example("physical-read-back")), physical)
        XCTAssertEqual(try read(example("physical-same-asserted-bytes")), physical)
        // Question 62: every line returned settles at 0 inside the decision.
        let returned = try read(example("returned-read-back"))
        XCTAssertEqual(returned.charged, 0)
        XCTAssertEqual(returned.keptAmount, 0)
        XCTAssertTrue(returned.lines.allSatisfy { $0.valence == "returned" && !$0.disputed })
    }
    func testLostGoodsStayOutsideChargedTotal() throws {
        var body = try example("digital-settled")
        var lines = body["lines"] as! [[String: Any]]
        var lost = lines[0]
        lost["candidate"] = "fixture-lost-line"; lost["valence"] = "lost"; lost["amount"] = 900
        lines.append(lost); body["lines"] = lines; body["lost_amount"] = 900
        let result = try read(body)
        XCTAssertEqual(result.charged, 1200)
        XCTAssertEqual(result.lostAmount, 900)
        body["charged"] = 2100
        XCTAssertThrowsError(try read(body))
    }
    func testDisputedMissingLineStaysStockLossAndAddsNoDisputedAmount() throws {
        // Question 46.
        var body = try example("digital-settled"), lines = body["lines"] as! [[String: Any]]
        var lost = lines[0]
        lost["candidate"] = "fixture-missing-line"; lost["valence"] = "lost"; lost["amount"] = 900; lost["disputed"] = true
        lines.append(lost); body["lines"] = lines; body["lost_amount"] = 900
        XCTAssertEqual(try read(body).disputedAmount, 0)
        body["disputed_amount"] = 900
        XCTAssertThrowsError(try read(body))
    }
    func testRefusalsPreserveStatusAndUnknownCodesWithoutServerMessages() throws {
        for item in try examples().filter({ $0["schema"] as? String == "ErrorResponse" }) {
            let body = item["value"] as! [String: Any], status = item["status"] as! Int
            XCTAssertThrowsError(try read(body, status: status)) {
                XCTAssertEqual($0 as? ReferenceReadFailure, .protocolRefusal(status: status, code: body["error"] as! String))
            }
        }
        XCTAssertThrowsError(try read(["error": "future_refusal", "message": "private diagnostic"], status: 422)) {
            XCTAssertEqual($0 as? ReferenceReadFailure, .protocolRefusal(status: 422, code: "future_refusal"))
        }
    }
    func testMalformedIntermediaryAndUnexpectedSuccessNeverBecomeAReceipt() throws {
        let valid = try example("digital-settled")
        for status in [201, 204, 302, 503] {
            XCTAssertThrowsError(try read(valid, status: status)) { XCTAssertEqual($0 as? ReferenceReadFailure, .unexpectedHTTP(status: status)) }
        }
        XCTAssertThrowsError(try read(valid, type: "text/html"))
        XCTAssertThrowsError(try read(valid, type: nil))
        _ = try read(valid, type: "Application/JSON; charset=utf-8")
        XCTAssertThrowsError(try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: Data("broken".utf8), expectedOffer: "a"))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try read(missing))
        }
        var extra = valid; extra["paid"] = true
        XCTAssertThrowsError(try read(extra))
    }
    func testDifferentResourceAndUnicodeEquivalentIdentifierAreRefused() throws {
        var valid = try example("digital-settled")
        XCTAssertThrowsError(try read(valid, expected: "another-offer")) { XCTAssertEqual($0 as? ReferenceReadFailure, .mismatchedResource) }
        valid["offer"] = "é"
        XCTAssertThrowsError(try read(valid, expected: "e\u{301}")) { XCTAssertEqual($0 as? ReferenceReadFailure, .mismatchedResource) }
    }
    func testAlteredTotalsUnsafeAmountsDuplicateAndInvalidDisputesAreRefused() throws {
        let base = try example("physical-settled")
        for amount in [-1, 1, 9_007_199_254_740_992] as [Int64] {
            var changed = base; changed["charged"] = amount
            XCTAssertThrowsError(try read(changed))
        }
        var changed = base
        var lines = base["lines"] as! [[String: Any]]
        lines.append(lines[0]); changed["lines"] = lines
        XCTAssertThrowsError(try read(changed))
        for valence in ["returned", "future", "kept"] {
            lines = base["lines"] as! [[String: Any]]
            lines[0]["valence"] = valence; lines[0]["disputed"] = true; changed["lines"] = lines
            XCTAssertThrowsError(try read(changed))
        }
        lines = base["lines"] as! [[String: Any]]
        lines[0]["amount"] = Canonical.maximumInteger; lines[1]["amount"] = Canonical.maximumInteger
        lines[0]["disputed"] = false; lines[1]["disputed"] = false; changed["lines"] = lines
        XCTAssertThrowsError(try read(changed))
    }
}
