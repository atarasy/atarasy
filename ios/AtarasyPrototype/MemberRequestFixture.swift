#if ATARASY_UI_TEST_FIXTURES
import Foundation
import SwiftUI
import AtarasyCore
private enum RequestFixture {
    static var value: [String: Any] {
        let url = Bundle.main.url(forResource: "member-permission-request-runtime", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
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
