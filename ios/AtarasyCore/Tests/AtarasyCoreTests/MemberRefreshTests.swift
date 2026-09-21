import XCTest
@testable import AtarasyCore

private final class RefreshVault: MemberSessionVault, @unchecked Sendable {
    var stored: StoredMemberSession?
    init(_ stored: StoredMemberSession) { self.stored = stored }
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { stored?.info.household == household ? stored : nil }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws { stored = session }
    func remove(environment: MemberEnvironment, household: String) throws { stored = nil }
}
private actor RefreshTransport: MemberHTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request)
        let path = request.url!.path, body: [String: Any]
        if path == "/auth/session" { body = ["id": "session", "household": "home", "presenters": ["merchant"], "expiresAt": 5000] }
        else if path == "/member/refresh/subscription" { body = ["profile": "atarasy.member-refresh-subscription.1", "active": true, "apnsEnvironment": "sandbox", "updatedAt": 1000] }
        else { body = ["profile": "atarasy.member-refresh-subscription.1", "active": false, "apnsEnvironment": NSNull(), "updatedAt": 1001] }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: try JSONSerialization.data(withJSONObject: body))
    }
    func captured() -> [URLRequest] { requests }
}

final class MemberRefreshTests: XCTestCase {
    func testHintIsClosedAndContainsNoPrivateProjection() throws {
        let valid = try JSONSerialization.data(withJSONObject: ["aps": ["content-available": 1], "atarasy": ["profile": "atarasy.member-refresh-hint.1"]])
        XCTAssertTrue(MemberRefreshHint.validate(valid))
        let invalid: [[String: Any]] = [
            ["aps": ["content-available": 1], "atarasy": ["profile": "atarasy.member-refresh-hint.1", "offer": "private"]],
            ["aps": ["content-available": 1], "atarasy": ["profile": "atarasy.member-refresh-hint.1"], "household": "private"],
            ["aps": ["content-available": true], "atarasy": ["profile": "atarasy.member-refresh-hint.1"]],
            ["aps": ["content-available": 1], "atarasy": ["profile": "other"]],
        ]
        for value in invalid { XCTAssertFalse(MemberRefreshHint.validate(try JSONSerialization.data(withJSONObject: value))) }
    }
    func testClientRegistersOnlyDeviceTokenAndValidatesClosedStatus() async throws {
        let environment = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!), info = MemberSessionInfo(id: "session", household: "home", presenters: ["merchant"], expiresAt: 5000)
        let vault = RefreshVault(.init(token: "amr1_" + String(repeating: "A", count: 43), info: info)), transport = RefreshTransport(), client = MemberClient(environment: environment, transport: transport, vault: vault, now: { 1000 })
        let restored = try await client.restore(household: "home"); XCTAssertEqual(restored, info)
        let registered = try await client.registerRefresh(token: Data(repeating: 0xab, count: 32), apnsEnvironment: .sandbox); XCTAssertTrue(registered.active)
        let disabled = try await client.disableRefresh(); XCTAssertFalse(disabled.active)
        let requests = await transport.captured(); XCTAssertEqual(requests.map { $0.url!.path }, ["/auth/session", "/member/refresh/subscription", "/member/refresh/disable"])
        let object = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["token", "apnsEnvironment"]); XCTAssertEqual(object["token"] as? String, String(repeating: "ab", count: 32)); XCTAssertNil(object["household"]); XCTAssertNil(object["presenter"])
    }
}
