#if ATARASY_UI_TEST_FIXTURES
import Foundation
import SwiftUI
import AtarasyCore
private enum PermissionFixture {
    static let bytes = Data(base64Encoded: "ewogICJzY29wZSI6ICJTeW50aGV0aWMgUG9zdGdyZVNRTCBwZXJtaXNzaW9uIGxpc3QgYW5kIGluZGl2aWR1YWwgcmV2b2NhdGlvbjsgbm8gbmF0aXZlIFVJIG9yIG5ldy1ncmFudCBjZXJlbW9ueS4iLAogICJlbnZpcm9ubWVudCI6IHsKICAgICJuYW1lIjogInRlc3QiLAogICAgIm9yaWdpbiI6ICJodHRwczovL3VuaXQuZXhhbXBsZSIKICB9LAogICJzZXNzaW9uIjogewogICAgImlkIjogImIyMjkxZTY2LThkNTUtNGYxYi1iZGE2LWQ3ZTc3N2JlY2IyNyIsCiAgICAiaG91c2Vob2xkIjogImtleTpibGJCSzY4d3RRMjJ3YWdIc216QlU0YktvcEJVV3dZREJ6TWkxQ0tOSVc4IiwKICAgICJwcmVzZW50ZXJzIjogWwogICAgICAibWVyY2hhbnQtMSIKICAgIF0sCiAgICAiZXhwaXJlc0F0IjogMTgwMDAwMDA5MDAwMQogIH0sCiAgImxpc3RlZCI6IHsKICAgICJob3VzZWhvbGQiOiAia2V5OmJsYkJLNjh3dFEyMndhZ0hzbXpCVTRiS29wQlVXd1lEQnpNaTFDS05JVzgiLAogICAgImNoZWNrZWRBdCI6IDE4MDAwMDAwMDAwMDEsCiAgICAicGVybWlzc2lvbnMiOiBbCiAgICAgIHsKICAgICAgICAiaWQiOiAiYjllNDZkNjktY2M5ZS00ZDNkLWIxMTYtYzMxOWEzNjU0NzVjIiwKICAgICAgICAia2luZCI6ICJwYXJ0eSIsCiAgICAgICAgInJlc3VsdF9mb3JtIjogbnVsbCwKICAgICAgICAiZ3JhbnRlZSI6ICJmaXJzdCIsCiAgICAgICAgInNjb3BlIjogWwogICAgICAgICAgIm9mZmVycyIKICAgICAgICBdLAogICAgICAgICJwdXJwb3NlIjogIlN5bnRoZXRpYyBsaW1pdGVkIHBlcm1pc3Npb24iLAogICAgICAgICJncmFudGVkX2F0IjogMTgwMDAwMDAwMDAwMSwKICAgICAgICAiZXhwaXJlc19hdCI6IDE4MDAwMDAwMDUwMDEsCiAgICAgICAgImFza2VkX2Zyb20iOiAiNjNhNjVhMTItMGI5Mi00NDg1LWExN2ItYWMyZjRiYjdkZWQzIiwKICAgICAgICAicmV2b2tlZF9hdCI6IG51bGwKICAgICAgfSwKICAgICAgewogICAgICAgICJpZCI6ICIyYzlkYjRhZi0xZGRiLTQwMjAtYjk4NS03YjMwMDQyNWVjY2MiLAogICAgICAgICJraW5kIjogInBhcnR5IiwKICAgICAgICAicmVzdWx0X2Zvcm0iOiBudWxsLAogICAgICAgICJncmFudGVlIjogInNlY29uZCIsCiAgICAgICAgInNjb3BlIjogWwogICAgICAgICAgIm9mZmVycyIKICAgICAgICBdLAogICAgICAgICJwdXJwb3NlIjogIlN5bnRoZXRpYyBsaW1pdGVkIHBlcm1pc3Npb24iLAogICAgICAgICJncmFudGVkX2F0IjogMTgwMDAwMDAwMDAwMSwKICAgICAgICAiZXhwaXJlc19hdCI6IDE4MDAwMDAwMDUwMDEsCiAgICAgICAgImFza2VkX2Zyb20iOiAiNjNhNjVhMTItMGI5Mi00NDg1LWExN2ItYWMyZjRiYjdkZWQzIiwKICAgICAgICAicmV2b2tlZF9hdCI6IG51bGwKICAgICAgfQogICAgXQogIH0sCiAgInJldm9rZWQiOiB7CiAgICAiaG91c2Vob2xkIjogImtleTpibGJCSzY4d3RRMjJ3YWdIc216QlU0YktvcEJVV3dZREJ6TWkxQ0tOSVc4IiwKICAgICJwZXJtaXNzaW9uIjogewogICAgICAiaWQiOiAiYjllNDZkNjktY2M5ZS00ZDNkLWIxMTYtYzMxOWEzNjU0NzVjIiwKICAgICAgImtpbmQiOiAicGFydHkiLAogICAgICAicmVzdWx0X2Zvcm0iOiBudWxsLAogICAgICAiZ3JhbnRlZSI6ICJmaXJzdCIsCiAgICAgICJzY29wZSI6IFsKICAgICAgICAib2ZmZXJzIgogICAgICBdLAogICAgICAicHVycG9zZSI6ICJTeW50aGV0aWMgbGltaXRlZCBwZXJtaXNzaW9uIiwKICAgICAgImdyYW50ZWRfYXQiOiAxODAwMDAwMDAwMDAxLAogICAgICAiZXhwaXJlc19hdCI6IDE4MDAwMDAwMDUwMDEsCiAgICAgICJhc2tlZF9mcm9tIjogIjYzYTY1YTEyLTBiOTItNDQ4NS1hMTdiLWFjMmY0YmI3ZGVkMyIsCiAgICAgICJyZXZva2VkX2F0IjogMTgwMDAwMDAwMDAwMQogICAgfQogIH0sCiAgImFmdGVyIjogewogICAgImhvdXNlaG9sZCI6ICJrZXk6YmxiQks2OHd0UTIyd2FnSHNtekJVNGJLb3BCVVd3WURCek1pMUNLTklXOCIsCiAgICAiY2hlY2tlZEF0IjogMTgwMDAwMDAwMDAwMSwKICAgICJwZXJtaXNzaW9ucyI6IFsKICAgICAgewogICAgICAgICJpZCI6ICJiOWU0NmQ2OS1jYzllLTRkM2QtYjExNi1jMzE5YTM2NTQ3NWMiLAogICAgICAgICJraW5kIjogInBhcnR5IiwKICAgICAgICAicmVzdWx0X2Zvcm0iOiBudWxsLAogICAgICAgICJncmFudGVlIjogImZpcnN0IiwKICAgICAgICAic2NvcGUiOiBbCiAgICAgICAgICAib2ZmZXJzIgogICAgICAgIF0sCiAgICAgICAgInB1cnBvc2UiOiAiU3ludGhldGljIGxpbWl0ZWQgcGVybWlzc2lvbiIsCiAgICAgICAgImdyYW50ZWRfYXQiOiAxODAwMDAwMDAwMDAxLAogICAgICAgICJleHBpcmVzX2F0IjogMTgwMDAwMDAwNTAwMSwKICAgICAgICAiYXNrZWRfZnJvbSI6ICI2M2E2NWExMi0wYjkyLTQ0ODUtYTE3Yi1hYzJmNGJiN2RlZDMiLAogICAgICAgICJyZXZva2VkX2F0IjogMTgwMDAwMDAwMDAwMQogICAgICB9LAogICAgICB7CiAgICAgICAgImlkIjogIjJjOWRiNGFmLTFkZGItNDAyMC1iOTg1LTdiMzAwNDI1ZWNjYyIsCiAgICAgICAgImtpbmQiOiAicGFydHkiLAogICAgICAgICJyZXN1bHRfZm9ybSI6IG51bGwsCiAgICAgICAgImdyYW50ZWUiOiAic2Vjb25kIiwKICAgICAgICAic2NvcGUiOiBbCiAgICAgICAgICAib2ZmZXJzIgogICAgICAgIF0sCiAgICAgICAgInB1cnBvc2UiOiAiU3ludGhldGljIGxpbWl0ZWQgcGVybWlzc2lvbiIsCiAgICAgICAgImdyYW50ZWRfYXQiOiAxODAwMDAwMDAwMDAxLAogICAgICAgICJleHBpcmVzX2F0IjogMTgwMDAwMDAwNTAwMSwKICAgICAgICAiYXNrZWRfZnJvbSI6ICI2M2E2NWExMi0wYjkyLTQ0ODUtYTE3Yi1hYzJmNGJiN2RlZDMiLAogICAgICAgICJyZXZva2VkX2F0IjogbnVsbAogICAgICB9CiAgICBdCiAgfQp9Cg==")!
    static var value: [String: Any] { try! JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
    static func data(_ key: String) -> Data { try! JSONSerialization.data(withJSONObject: value[key]!) }
}
private struct PermissionFixtureVault: MemberSessionVault {
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? {
        let object: [String: Any] = ["token": "amr1_" + String(repeating: "A", count: 43), "info": PermissionFixture.value["session"]!]
        return try JSONDecoder().decode(StoredMemberSession.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor PermissionFixtureTransport: MemberHTTPTransport {
    var revoked = false
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        if request.url!.path.hasSuffix("/revoke") { revoked = true; throw URLError(.networkConnectionLost) }
        let key = request.url!.path == "/auth/session" ? "session" : revoked ? "after" : "listed"
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: PermissionFixture.data(key))
    }
}
@MainActor private final class PermissionFixtureModel: ObservableObject {
    let client: MemberClient
    let permissions: MemberPermissions
    @Published var ready = false
    init() {
        client = MemberClient(environment: try! .init(name: "test", origin: URL(string: "https://unit.example")!), transport: PermissionFixtureTransport(), vault: PermissionFixtureVault(), now: { 1_800_000_000_001 })
        permissions = MemberPermissions(service: client, now: { 1_800_000_000_001 })
    }
    func start() async {
        let session = try! JSONDecoder().decode(MemberSessionInfo.self, from: PermissionFixture.data("session"))
        _ = try? await client.restore(household: session.household); permissions.setSession(session); ready = true
    }
}
struct MemberPermissionFixtureView: View {
    @StateObject private var model = PermissionFixtureModel()
    var body: some View {
        Group { if model.ready { MemberPermissionsView(model: model.permissions) } else { ProgressView("Loading fixture") } }
        .safeAreaInset(edge: .top) { Text("Synthetic permission fixture. No external access.").font(.caption) }
        .task { await model.start() }
    }
}
#endif
