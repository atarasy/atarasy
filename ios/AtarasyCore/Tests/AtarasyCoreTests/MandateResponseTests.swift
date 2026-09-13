import Foundation
import XCTest
@testable import AtarasyCore

final class MandateResponseTests: XCTestCase {
    private func examples() throws -> [[String: Any]] {
        let url = Bundle.module.url(forResource: "response-examples", withExtension: "json", subdirectory: "Fixtures")!
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root["cases"] as! [[String: Any]]
    }
    private func body(_ id: String) throws -> [String: Any] { try examples().first { $0["id"] as? String == id }!["value"] as! [String: Any] }
    private func read(_ value: [String: Any], id: String? = nil, household: String? = nil, version: Int64 = 1) throws -> Mandate {
        try ReferenceResponseReader.mandate(status: 200, contentType: "application/json", data: JSONSerialization.data(withJSONObject: value), expectedID: id ?? (value["id"] as? String ?? "fixture"), expectedHousehold: household ?? (value["household"] as? String ?? "fixture"), minimumVersion: version)
    }
    func testActualMandateResponsesPreserveNullZeroAndFormerCosignerChange() throws {
        for item in try examples().filter({ $0["schema"] as? String == "MandateResponse" }) { _ = try read(item["value"] as! [String: Any]) }
        let first = try read(body("mandate-created")), tight = try read(body("mandate-tightened")), loose = try read(body("mandate-loosened"))
        XCTAssertNil(first.ceilingDaily); XCTAssertNil(first.coolingSeconds)
        XCTAssertEqual(tight.ceilingDaily, 0); XCTAssertEqual(tight.coolingSeconds, 60)
        XCTAssertNil(loose.ceilingDaily); XCTAssertEqual(loose.coSigners, []); XCTAssertEqual(loose.version, 3)
        XCTAssertNotEqual(try Canonical.mandate(first), try Canonical.mandate(tight))
    }
    func testMandateCannotChangeResourceHouseholdOrRegressBelowKnownVersion() throws {
        let value = try body("mandate-created")
        XCTAssertThrowsError(try read(value, id: "other"))
        XCTAssertThrowsError(try read(value, household: "other"))
        XCTAssertThrowsError(try read(value, version: 2))
        var unicode = value; unicode["household"] = "é"
        XCTAssertThrowsError(try read(unicode, household: "e\u{301}"))
    }
    func testMandateMissingNullableExtraFieldsAndUnsafeValuesAreRejected() throws {
        let value = try body("mandate-created")
        for key in value.keys { var changed = value; changed.removeValue(forKey: key); XCTAssertThrowsError(try read(changed)) }
        var changed = value; changed["signatures"] = [:] as [String: String]; XCTAssertThrowsError(try read(changed))
        for key in ["ceiling_out_of_network", "ceiling_daily", "cooling_seconds", "lapses_at", "version"] {
            for number: Int64 in [-1, Canonical.maximumInteger + 1] { changed = value; changed[key] = number; XCTAssertThrowsError(try read(changed)) }
        }
    }
    func testLapsedMandateRemainsReadableWithoutGrantingAuthority() throws {
        var value = try body("mandate-created"); value["lapses_at"] = 0
        XCTAssertEqual(try read(value).lapsesAt, 0)
    }
}
