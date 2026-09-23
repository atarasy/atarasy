import Foundation
import XCTest
@testable import AtarasyCore
private struct RequestVault: MemberSessionVault {
    let info: MemberSessionInfo
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: info) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor RequestTransport: MemberHTTPTransport {
    let session: MemberSessionInfo; var replies: [Data?]; var requests: [URLRequest] = []
    init(_ session: MemberSessionInfo, _ replies: [Data?]) { self.session = session; self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let data: Data
        if request.url!.path == "/auth/session" { data = try JSONEncoder().encode(session) }
        else { guard !replies.isEmpty, let next = replies.removeFirst() else { throw URLError(.networkConnectionLost) }; data = next }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: data)
    }
}
@MainActor final class MemberPermissionRequestTests: XCTestCase {
    func fixture() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.module.url(forResource: "member-permission-request-runtime", withExtension: "json", subdirectory: "Fixtures")!)) as! [String: Any] }
    private func client(_ f: [String: Any], _ replies: [Data?]) async throws -> (MemberClient, RequestTransport, MemberSessionInfo) {
        let session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!)), transport = RequestTransport(session, replies)
        let client = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: transport, vault: RequestVault(info: session), now: { 1_800_000_000_001 })
        _ = try await client.restore(household: session.household); return (client, transport, session)
    }
    private func review(_ f: [String: Any]) throws -> MemberPermissionRequest { try JSONDecoder().decode(MemberPermissionRequest.self, from: digitalData(f["review"]!)) }
    func testActualPostgresDigestAndGrantTerms() async throws {
        let f = try fixture(), source = try review(f), (client, transport, _) = try await client(f, [digitalData(f["review"]!), digitalData(f["granted"]!), digitalData(f["revoked"]!)])
        let checked = try await client.permissionRequest(source.id); XCTAssertEqual(checked, source)
        XCTAssertEqual(Canonical.digest(checked.terms.canonical()), checked.digest)
        let granted = try await client.decidePermissionRequest(checked, grant: true); XCTAssertEqual(granted.permission?.scope, ["duplicate_check"])
        let revoked = try await client.permissionRequest(source.id); XCTAssertNotNil(revoked.permission?.revoked_at)
        let writes = await transport.requests.filter { $0.httpMethod == "POST" }; XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: writes[0].httpBody!) as! [String: String], ["digest": checked.digest])
    }
    func testTamperedReviewAndOutcomeCannotBePresented() async throws {
        let f = try fixture(), source = try review(f)
        for mutation in 0..<7 {
            var object = f[mutation >= 4 ? "granted" : "review"] as! [String: Any], terms = object["terms"] as! [String: Any]
            switch mutation {
            case 0: terms["purpose"] = "Changed purpose"
            case 1: terms["household"] = "another household"
            case 2: terms["accessExpiresAt"] = NSNull()
            case 3: terms["extra"] = true
            case 4: var p = object["permission"] as! [String: Any]; p["scope"] = ["offers"]; object["permission"] = p
            case 5: object["state"] = "cancelled"
            default: object["decidedAt"] = terms["reviewExpiresAt"]
            }
            object["terms"] = terms
            let (client, _, _) = try await client(f, [digitalData(object)])
            do { _ = try await client.permissionRequest(source.id); XCTFail("Accepted invalid review") } catch {}
        }
    }
    func testUncertainGrantRequiresReadbackAndSessionChangeClearsReview() async throws {
        let f = try fixture(), source = try review(f), (client, transport, session) = try await client(f, [digitalData(f["review"]!), nil, digitalData(f["granted"]!)])
        let model = MemberPermissionRequests(service: client, now: { 1_800_000_000_001 }); model.setSession(session)
        await model.open(source.id); XCTAssertTrue(model.ready); await model.decide(grant: true); XCTAssertFalse(model.ready); XCTAssertTrue(model.notice.contains("could not confirm"))
        await model.decide(grant: true); await model.open(source.id); XCTAssertEqual(model.review?.state, "granted"); XCTAssertFalse(model.ready)
        let count = await transport.requests.filter { $0.httpMethod == "POST" }.count; XCTAssertEqual(count, 1)
        model.setSession(nil); XCTAssertNil(model.review); XCTAssertTrue(model.rows.isEmpty)
    }
    func testCancelAndLeaveNeverGrant() async throws {
        let f = try fixture(), source = try review(f); var cancelled = f["review"] as! [String: Any]; cancelled["state"] = "cancelled"; cancelled["decidedAt"] = 1_800_000_000_001 as Int64
        let (client, transport, session) = try await client(f, [digitalData(f["review"]!), digitalData(cancelled)])
        let model = MemberPermissionRequests(service: client, now: { 1_800_000_000_001 }); model.setSession(session); await model.open(source.id); await model.decide(grant: false)
        XCTAssertEqual(model.review?.state, "cancelled"); XCTAssertNil(model.review?.permission); model.leave(); await model.decide(grant: true)
        let writes = await transport.requests.filter { $0.httpMethod == "POST" }; XCTAssertEqual(writes.count, 1); XCTAssertTrue(writes[0].url!.path.hasSuffix("/cancel"))
    }
    func testDuplicateListAndExpiredActionRefuse() async throws {
        let f = try fixture(), source = try review(f), session = f["session"] as! [String: Any]
        let list: [String: Any] = ["household":session["household"]!,"checkedAt":1_800_000_000_001 as Int64,"requests":[f["review"]!,f["review"]!]]
        let (client, transport, info) = try await client(f, [digitalData(list),digitalData(f["review"]!)])
        do { _ = try await client.permissionRequests(); XCTFail("Duplicate requests") } catch {}
        let model = MemberPermissionRequests(service: client, now: { source.terms.reviewExpiresAt }); model.setSession(info); await model.open(source.id); XCTAssertFalse(model.ready); await model.decide(grant: true)
        let writes = await transport.requests.filter { $0.httpMethod == "POST" }; XCTAssertTrue(writes.isEmpty)
    }
}
