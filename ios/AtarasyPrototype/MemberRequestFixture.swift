#if ATARASY_UI_TEST_FIXTURES
import Foundation
import SwiftUI
import AtarasyCore
private enum RequestFixture {
    static let bytes = Data(base64Encoded: "ewogICJlbnZpcm9ubWVudCI6IHsKICAgICJuYW1lIjogInRlc3QiLAogICAgIm9yaWdpbiI6ICJodHRwczovL3VuaXQuZXhhbXBsZSIKICB9LAogICJzZXNzaW9uIjogewogICAgImlkIjogIjgxZTNhNjNlLWZjODctNDU5Mi04Yzc1LTg5MWRmODZmYjIyOCIsCiAgICAiaG91c2Vob2xkIjogImtleToySVZHdVQ4ZnNtajZhS0lfRnlCVUN6bV85MXBOTnVRRTZnbWZncVNwVXhFIiwKICAgICJwcmVzZW50ZXJzIjogWwogICAgICAibWVyY2hhbnQtMSIKICAgIF0sCiAgICAiZXhwaXJlc0F0IjogMTgwMDAwMDA5MDAwMQogIH0sCiAgInJldmlldyI6IHsKICAgICJ0ZXJtcyI6IHsKICAgICAgInByb2ZpbGUiOiAiYXRhcmFzeS5wZXJtaXNzaW9uLXJldmlldy4xIiwKICAgICAgInJlcXVlc3RJRCI6ICIzMjE2OTcwNi00MDkwLTRmZTAtYTZjNS1hMmY4YTZmNjFkYzAiLAogICAgICAiaG91c2Vob2xkIjogImtleToySVZHdVQ4ZnNtajZhS0lfRnlCVUN6bV85MXBOTnVRRTZnbWZncVNwVXhFIiwKICAgICAgImFjdGlvbiI6ICJDaGVjayBmb3IgYSBkdXBsaWNhdGUgYmVmb3JlIHByb3Bvc2luZyBhIGdpZnQiLAogICAgICAicmVxdWVzdGVyIjogewogICAgICAgICJpZCI6ICJnaXZlci1vbmUiLAogICAgICAgICJuYW1lIjogIkV4YW1wbGUgZ2l2ZXIiCiAgICAgIH0sCiAgICAgICJwdXJwb3NlIjogIkF2b2lkIHByb3Bvc2luZyBhIHByb2R1Y3QgeW91IGFscmVhZHkgaGF2ZSIsCiAgICAgICJmaWVsZHMiOiBbCiAgICAgICAgewogICAgICAgICAgImlkIjogImR1cGxpY2F0ZV9jaGVjayIsCiAgICAgICAgICAibGFiZWwiOiAiV2hldGhlciB5b3UgYWxyZWFkeSBoYXZlIGEgcHJvZHVjdCIKICAgICAgICB9CiAgICAgIF0sCiAgICAgICJjcmVhdGVkQXQiOiAxODAwMDAwMDAwMDAxLAogICAgICAicmV2aWV3RXhwaXJlc0F0IjogMTgwMDAwMDAwNTAwMSwKICAgICAgImFjY2Vzc0V4cGlyZXNBdCI6IDE4MDAwMDAwMTAwMDEKICAgIH0sCiAgICAiZGlnZXN0IjogIjIzZDdhNWVkNDAxZDY0YmVlMWZmMWIxNTYwYzBmM2JhMmU0ZTMxZGM0ZGIwYzIwYzkzYWViOGI2YTcxZmY5YzMiLAogICAgInN0YXRlIjogInBlbmRpbmciLAogICAgImRlY2lkZWRBdCI6IG51bGwsCiAgICAicGVybWlzc2lvbiI6IG51bGwKICB9LAogICJncmFudGVkIjogewogICAgInRlcm1zIjogewogICAgICAicHJvZmlsZSI6ICJhdGFyYXN5LnBlcm1pc3Npb24tcmV2aWV3LjEiLAogICAgICAicmVxdWVzdElEIjogIjMyMTY5NzA2LTQwOTAtNGZlMC1hNmM1LWEyZjhhNmY2MWRjMCIsCiAgICAgICJob3VzZWhvbGQiOiAia2V5OjJJVkd1VDhmc21qNmFLSV9GeUJVQ3ptXzkxcE5OdVFFNmdtZmdxU3BVeEUiLAogICAgICAiYWN0aW9uIjogIkNoZWNrIGZvciBhIGR1cGxpY2F0ZSBiZWZvcmUgcHJvcG9zaW5nIGEgZ2lmdCIsCiAgICAgICJyZXF1ZXN0ZXIiOiB7CiAgICAgICAgImlkIjogImdpdmVyLW9uZSIsCiAgICAgICAgIm5hbWUiOiAiRXhhbXBsZSBnaXZlciIKICAgICAgfSwKICAgICAgInB1cnBvc2UiOiAiQXZvaWQgcHJvcG9zaW5nIGEgcHJvZHVjdCB5b3UgYWxyZWFkeSBoYXZlIiwKICAgICAgImZpZWxkcyI6IFsKICAgICAgICB7CiAgICAgICAgICAiaWQiOiAiZHVwbGljYXRlX2NoZWNrIiwKICAgICAgICAgICJsYWJlbCI6ICJXaGV0aGVyIHlvdSBhbHJlYWR5IGhhdmUgYSBwcm9kdWN0IgogICAgICAgIH0KICAgICAgXSwKICAgICAgImNyZWF0ZWRBdCI6IDE4MDAwMDAwMDAwMDEsCiAgICAgICJyZXZpZXdFeHBpcmVzQXQiOiAxODAwMDAwMDA1MDAxLAogICAgICAiYWNjZXNzRXhwaXJlc0F0IjogMTgwMDAwMDAxMDAwMQogICAgfSwKICAgICJkaWdlc3QiOiAiMjNkN2E1ZWQ0MDFkNjRiZWUxZmYxYjE1NjBjMGYzYmEyZTRlMzFkYzRkYjBjMjBjOTNhZWI4YjZhNzFmZjljMyIsCiAgICAic3RhdGUiOiAiZ3JhbnRlZCIsCiAgICAiZGVjaWRlZEF0IjogMTgwMDAwMDAwMDAwMSwKICAgICJwZXJtaXNzaW9uIjogewogICAgICAiaWQiOiAiMGU5YjdiNDMtMDU2MS00NGIyLWI4ODEtZTMyZjMwZWM4NjY2IiwKICAgICAgImtpbmQiOiAicGFydHkiLAogICAgICAicmVzdWx0X2Zvcm0iOiBudWxsLAogICAgICAiZ3JhbnRlZSI6ICJnaXZlci1vbmUiLAogICAgICAic2NvcGUiOiBbCiAgICAgICAgImR1cGxpY2F0ZV9jaGVjayIKICAgICAgXSwKICAgICAgInB1cnBvc2UiOiAiQXZvaWQgcHJvcG9zaW5nIGEgcHJvZHVjdCB5b3UgYWxyZWFkeSBoYXZlIiwKICAgICAgImdyYW50ZWRfYXQiOiAxODAwMDAwMDAwMDAxLAogICAgICAiZXhwaXJlc19hdCI6IDE4MDAwMDAwMTAwMDEsCiAgICAgICJhc2tlZF9mcm9tIjogIjlhNmZjYjk1LTRlN2UtNGU5ZS04NGY2LTZmMjliMGVhNDAyNyIsCiAgICAgICJyZXZva2VkX2F0IjogbnVsbAogICAgfQogIH0sCiAgInJldm9rZWQiOiB7CiAgICAidGVybXMiOiB7CiAgICAgICJwcm9maWxlIjogImF0YXJhc3kucGVybWlzc2lvbi1yZXZpZXcuMSIsCiAgICAgICJyZXF1ZXN0SUQiOiAiMzIxNjk3MDYtNDA5MC00ZmUwLWE2YzUtYTJmOGE2ZjYxZGMwIiwKICAgICAgImhvdXNlaG9sZCI6ICJrZXk6MklWR3VUOGZzbWo2YUtJX0Z5QlVDem1fOTFwTk51UUU2Z21mZ3FTcFV4RSIsCiAgICAgICJhY3Rpb24iOiAiQ2hlY2sgZm9yIGEgZHVwbGljYXRlIGJlZm9yZSBwcm9wb3NpbmcgYSBnaWZ0IiwKICAgICAgInJlcXVlc3RlciI6IHsKICAgICAgICAiaWQiOiAiZ2l2ZXItb25lIiwKICAgICAgICAibmFtZSI6ICJFeGFtcGxlIGdpdmVyIgogICAgICB9LAogICAgICAicHVycG9zZSI6ICJBdm9pZCBwcm9wb3NpbmcgYSBwcm9kdWN0IHlvdSBhbHJlYWR5IGhhdmUiLAogICAgICAiZmllbGRzIjogWwogICAgICAgIHsKICAgICAgICAgICJpZCI6ICJkdXBsaWNhdGVfY2hlY2siLAogICAgICAgICAgImxhYmVsIjogIldoZXRoZXIgeW91IGFscmVhZHkgaGF2ZSBhIHByb2R1Y3QiCiAgICAgICAgfQogICAgICBdLAogICAgICAiY3JlYXRlZEF0IjogMTgwMDAwMDAwMDAwMSwKICAgICAgInJldmlld0V4cGlyZXNBdCI6IDE4MDAwMDAwMDUwMDEsCiAgICAgICJhY2Nlc3NFeHBpcmVzQXQiOiAxODAwMDAwMDEwMDAxCiAgICB9LAogICAgImRpZ2VzdCI6ICIyM2Q3YTVlZDQwMWQ2NGJlZTFmZjFiMTU2MGMwZjNiYTJlNGUzMWRjNGRiMGMyMGM5M2FlYjhiNmE3MWZmOWMzIiwKICAgICJzdGF0ZSI6ICJncmFudGVkIiwKICAgICJkZWNpZGVkQXQiOiAxODAwMDAwMDAwMDAxLAogICAgInBlcm1pc3Npb24iOiB7CiAgICAgICJpZCI6ICIwZTliN2I0My0wNTYxLTQ0YjItYjg4MS1lMzJmMzBlYzg2NjYiLAogICAgICAia2luZCI6ICJwYXJ0eSIsCiAgICAgICJyZXN1bHRfZm9ybSI6IG51bGwsCiAgICAgICJncmFudGVlIjogImdpdmVyLW9uZSIsCiAgICAgICJzY29wZSI6IFsKICAgICAgICAiZHVwbGljYXRlX2NoZWNrIgogICAgICBdLAogICAgICAicHVycG9zZSI6ICJBdm9pZCBwcm9wb3NpbmcgYSBwcm9kdWN0IHlvdSBhbHJlYWR5IGhhdmUiLAogICAgICAiZ3JhbnRlZF9hdCI6IDE4MDAwMDAwMDAwMDEsCiAgICAgICJleHBpcmVzX2F0IjogMTgwMDAwMDAxMDAwMSwKICAgICAgImFza2VkX2Zyb20iOiAiOWE2ZmNiOTUtNGU3ZS00ZTllLTg0ZjYtNmYyOWIwZWE0MDI3IiwKICAgICAgInJldm9rZWRfYXQiOiAxODAwMDAwMDAwMDAxCiAgICB9CiAgfQp9Cg==")!
    static var value: [String: Any] { try! JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
    static func data(_ key: String) -> Data { try! JSONSerialization.data(withJSONObject: value[key]!) }
}
private struct RequestFixtureVault: MemberSessionVault {
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? {
        let object: [String: Any] = ["token": "amr1_" + String(repeating: "A", count: 43), "info": RequestFixture.value["session"]!]
        return try JSONDecoder().decode(StoredMemberSession.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {}
    func remove(environment: MemberEnvironment, household: String) throws {}
}
private actor RequestFixtureTransport: MemberHTTPTransport {
    var outcome: [String: Any]?
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        let path = request.url!.path
        if path.hasSuffix("/grant") { outcome = RequestFixture.value["granted"] as? [String: Any]; throw URLError(.networkConnectionLost) }
        if path.hasSuffix("/cancel") { outcome = RequestFixture.value["review"] as? [String: Any]; outcome?["state"] = "cancelled"; outcome?["decidedAt"] = 1_800_000_000_001 as Int64 }
        let value: Any
        if path == "/auth/session" { value = RequestFixture.value["session"]! }
        else if path == "/member/permissions/requests" { value = ["household": (RequestFixture.value["session"] as! [String: Any])["household"]!, "checkedAt": 1_800_000_000_001 as Int64, "requests": [outcome ?? RequestFixture.value["review"] as! [String: Any]]] as [String: Any] }
        else { value = outcome ?? RequestFixture.value["review"] as! [String: Any] }
        return .init(url: request.url!, status: 200, contentType: "application/json", cacheControl: "no-store", data: try JSONSerialization.data(withJSONObject: value))
    }
}
@MainActor private final class RequestFixtureModel: ObservableObject {
    let client: MemberClient
    let permissions: MemberPermissionRequests
    @Published var ready = false
    init() {
        client = MemberClient(environment: try! .init(name: "test", origin: URL(string: "https://unit.example")!), transport: RequestFixtureTransport(), vault: RequestFixtureVault(), now: { 1_800_000_000_001 })
        permissions = MemberPermissionRequests(service: client, now: { 1_800_000_000_001 })
    }
    func start() async {
        let session = try! JSONDecoder().decode(MemberSessionInfo.self, from: RequestFixture.data("session"))
        _ = try? await client.restore(household: session.household); permissions.setSession(session); ready = true
    }
}
struct MemberRequestFixtureView: View {
    @StateObject private var model = RequestFixtureModel()
    var body: some View {
        Group { if model.ready { MemberPermissionRequestsView(currentTime: { 1_800_000_000_001 }, model: model.permissions) } else { ProgressView("Loading fixture") } }
        .safeAreaInset(edge: .top) { Text("Synthetic permission fixture. No external access.").font(.caption) }
        .task { await model.start() }
    }
}
#endif
