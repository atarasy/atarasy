import Foundation
import XCTest
@testable import AtarasyCore
private struct PermissionVault: MemberSessionVault {
    let info: MemberSessionInfo
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { .init(token: "amr1_" + String(repeating: "A", count: 43), info: info) }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor PermissionTransport: MemberHTTPTransport {
    let session: MemberSessionInfo
    var replies: [Data?]
    var requests: [URLRequest] = []
    init(_ session: MemberSessionInfo, _ replies: [Data?]) { self.session = session; self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let data: Data
        if request.url!.path == "/auth/session" { data = try JSONEncoder().encode(session) }
        else { guard !replies.isEmpty, let next = replies.removeFirst() else { throw URLError(.networkConnectionLost) }; data = next }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: data)
    }
}
@MainActor final class MemberPermissionTests: XCTestCase {
    func fixture() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.module.url(forResource: "member-permissions-runtime", withExtension: "json", subdirectory: "Fixtures")!)) as! [String: Any] }
    private func client(_ f: [String: Any], _ replies: [Data?]) async throws -> (MemberClient, PermissionTransport, MemberSessionInfo) {
        let session = try JSONDecoder().decode(MemberSessionInfo.self, from: digitalData(f["session"]!)), transport = PermissionTransport(session, replies)
        let client = MemberClient(environment: try .init(name: "test", origin: URL(string: "https://unit.example")!), transport: transport, vault: PermissionVault(info: session), now: { 1_800_000_000_001 })
        _ = try await client.restore(household: session.household); return (client, transport, session)
    }
    func testActualListAndRevocationPreserveScopeAndOtherRows() async throws {
        let f = try fixture(), (client, transport, session) = try await client(f, [digitalData(f["listed"]!), digitalData(f["revoked"]!), digitalData(f["after"]!)])
        let list = try await client.permissionList(); XCTAssertEqual(list.household, session.household); XCTAssertEqual(list.permissions.count, 2)
        let row = list.permissions[0]; XCTAssertEqual(row.status(at: row.expires_at), "Expired")
        let revoked = try await client.revokePermission(row); XCTAssertTrue(revoked.sameGrant(row)); XCTAssertEqual(revoked.status(at: row.granted_at), "Revoked")
        let after = try await client.permissionList(); XCTAssertEqual(after.permissions[1], list.permissions[1])
        let requests = await transport.requests.filter { $0.url!.path != "/auth/session" }; XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET", "POST", "GET"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: String], ["permission": row.id])
    }
    func testMalformedForeignDuplicateAndUnlimitedPermissionsRefuse() async throws {
        let f = try fixture()
        for change in 0..<5 {
            var listed = f["listed"] as! [String: Any], rows = listed["permissions"] as! [[String: Any]]
            switch change {
            case 0: listed["household"] = "another"
            case 1: rows.append(rows[0])
            case 2: rows[0]["expires_at"] = NSNull()
            case 3: rows[0]["extra"] = "unexpected"
            default: rows[0]["result_form"] = "raw"
            }; listed["permissions"] = rows
            let (client, _, _) = try await client(f, [digitalData(listed)])
            do { _ = try await client.permissionList(); XCTFail("accepted mutation") } catch {}
        }
    }
    func testRevocationCannotChangePurposeOrAnotherGrant() async throws {
        let f = try fixture(); var reply = f["revoked"] as! [String: Any], row = reply["permission"] as! [String: Any]; row["purpose"] = "different"; reply["permission"] = row
        let (client, _, _) = try await client(f, [digitalData(f["listed"]!), digitalData(reply)])
        let listed = try await client.permissionList()
        do { _ = try await client.revokePermission(listed.permissions[0]); XCTFail("changed result") } catch {}
    }
    func testCancelSendsNothingAndLostResponseRequiresReadBeforeAnotherAction() async throws {
        let f = try fixture(), (client, transport, session) = try await client(f, [digitalData(f["listed"]!), nil, digitalData(f["after"]!)])
        let model = MemberPermissions(service: client, now: { 1_800_000_000_001 }); model.setSession(session); await model.refresh()
        let first = try XCTUnwrap(model.rows.first); model.select(first); model.cancel(); await model.revoke()
        XCTAssertTrue(model.loaded); model.select(first); await model.revoke(); XCTAssertFalse(model.loaded); XCTAssertTrue(model.notice.contains("could not be confirmed"))
        model.select(first); await model.revoke(); await model.refresh(); XCTAssertTrue(model.loaded); XCTAssertEqual(model.rows[0].status(at: first.granted_at), "Revoked")
        let requests = await transport.requests.filter { $0.url!.path == "/member/permissions/revoke" }; XCTAssertEqual(requests.count, 1)
        model.setSession(nil); XCTAssertTrue(model.rows.isEmpty); XCTAssertNil(model.selected)
    }
}
@MainActor private final class PermissionCallbackService: MemberPermissionService {
    let list: MemberPermissionList
    var callback: (() -> Void)?
    init(_ list: MemberPermissionList) { self.list = list }
    func permissionList() async throws -> MemberPermissionList { callback?(); return list }
    func revokePermission(_ permission: MemberPermission) async throws -> MemberPermission { throw MemberFailure.unavailable }
}
extension MemberPermissionTests {
    func testSessionChangeDiscardsAnInFlightList() async throws {
        let f = try fixture(), (client, _, session) = try await client(f, [digitalData(f["listed"]!)])
        let service = PermissionCallbackService(try await client.permissionList()), model = MemberPermissions(service: service, now: { 1_800_000_000_001 })
        model.setSession(session); service.callback = { model.setSession(nil) }; await model.refresh()
        XCTAssertFalse(model.loaded); XCTAssertTrue(model.rows.isEmpty); XCTAssertNil(model.selected)
    }
}
