import XCTest
@testable import AtarasyCore
final class ContractTests: XCTestCase {
    struct Vector: Decodable { var id:String; var kind:String; var offer:String?; var decisions:[Decision]?; var lines:[StatementLine]?; var carriage:Int64?; var mandate:Mandate?; var host:String?; var canonical:String; var sha256:String; var challenge:String }
    func data(_ name:String) throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures"))) }
    func testIndependentCanonicalVectors() throws {
        let d=JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let vectors=try d.decode([Vector].self,from:data("canonical-vectors")); XCTAssertEqual(vectors.count,11)
        for v in vectors {
            let text:String
            switch v.kind { case "decision": text=try Canonical.decisions(offer:XCTUnwrap(v.offer),lines:XCTUnwrap(v.decisions)); case "statement": text=try Canonical.statement(offer:XCTUnwrap(v.offer),carriage:v.carriage,lines:XCTUnwrap(v.lines)); default: text=try Canonical.mandate(XCTUnwrap(v.mandate),host:XCTUnwrap(v.host)) }
            XCTAssertEqual(text,v.canonical,v.id); XCTAssertEqual(Canonical.digest(text),v.sha256,v.id); XCTAssertEqual(Canonical.challenge(text),v.challenge,v.id)
        }
    }
    func testMissingCarriageAndInvalidDisputeCannotSign() throws {
        XCTAssertThrowsError(try Canonical.statement(offer:"box",carriage:nil,lines:[]))
        XCTAssertThrowsError(try Canonical.statement(offer:"box",carriage:0,lines:[.init(candidate:"a",valence:"kept",amount:5,disputed:true)]))
        XCTAssertThrowsError(try Canonical.decisions(offer:"o",lines:[.init(candidate:"a\nb",valence:"kept")]))
        XCTAssertThrowsError(try Canonical.statement(offer:"o",carriage:Canonical.maximumInteger+1,lines:[]))
        // Question 46: a missing line is never charged, and only a consumed or missing line may be disputed.
        XCTAssertThrowsError(try Canonical.statement(offer:"box",carriage:0,lines:[.init(candidate:"a",valence:"lost",amount:700,disputed:false)]))
        XCTAssertThrowsError(try Canonical.statement(offer:"box",carriage:0,lines:[.init(candidate:"a",valence:"defaulted",amount:5,disputed:true)]))
        XCTAssertEqual(try Canonical.statement(offer:"box",carriage:0,lines:[.init(candidate:"a",valence:"lost",amount:0,disputed:true)]),"valence.statement.1\nbox\n0\na:lost:0:disputed")
    }
    func testCarriageAndDisputeChangeAuthority() throws {
        let l=StatementLine(candidate:"a",valence:"consumed",amount:600,disputed:false)
        let a=try Canonical.statement(offer:"box",carriage:0,lines:[l])
        XCTAssertNotEqual(a,try Canonical.statement(offer:"box",carriage:200,lines:[l]))
        XCTAssertNotEqual(a,try Canonical.statement(offer:"box",carriage:0,lines:[.init(candidate:"a",valence:"consumed",amount:600,disputed:true)]))
    }
    func testLostReplyReadbackDoesNotRepeatSimulatedEffect() throws {
        var op=DemoOperation(); op.review("test"); try op.begin(); try op.submit(lostReply:true)
        var restored=try JSONDecoder().decode(DemoOperation.self,from:JSONEncoder().encode(op))
        XCTAssertThrowsError(try restored.submit(lostReply:false)); try restored.reconcile(); XCTAssertEqual(restored.simulatedEffects,1); XCTAssertEqual(restored.phase,.confirmed)
    }
    func testCancellationGrantsNothing() throws { var op=DemoOperation();op.review("test");try op.begin();try op.cancel();XCTAssertEqual(op.simulatedEffects,0);XCTAssertEqual(op.phase,.reviewing) }
    func testTwoActorFixtureOrderingAndGiftDisputeTotal() throws {
        let f=try JSONDecoder().decode(DemoFixtures.self,from:data("fixtures"));XCTAssertTrue(f.synthetic)
        let digital=f.visibleOffers(household:f.households[0],binding:"digital");XCTAssertFalse(digital.contains{$0.id == "private-b"})
        XCTAssertEqual(digital.map(\.id),["digital-b","digital-a"])
        XCTAssertEqual(f.visibleOffers(household:f.households[0],binding:"digital",unavailablePresenter:f.merchants[1]).map(\.id),["digital-a"])
        let box=try XCTUnwrap(f.visibleOffers(household:f.households[0],binding:"physical").first);XCTAssertEqual(box.amount(kept:[],disputed:[]),1600);XCTAssertEqual(box.amount(kept:[],disputed:["physical-a"]),1000)
    }
}
