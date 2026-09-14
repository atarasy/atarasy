#if ATARASY_UI_TEST_FIXTURES
import SwiftUI
import AtarasyCore

// Only the UITesting configuration includes this synthetic flow. No network or authenticator.
private actor StatementFixtureService: MemberStatementService {
    private var prepared: MemberPreparedOperation?
    func prepareStatement(_ local: PreparedMemberStatement, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedOperation) {
        let id = UUID().uuidString.lowercased(), challenge = Canonical.challenge("UI fixture only")
        let digest = Canonical.digest("UI fixture only")
        var statement = try MemberReviewFixtureData.value("physical-known-carriage")
        statement.removeValue(forKey: "challenge"); statement["offer"] = local.offer; statement["household"] = local.household
        let mandate: [String: Any] = ["id":"mandate-1","household":local.household,"ceiling_out_of_network":5000,"ceiling_daily":10000,"cooling_seconds":60,"co_signers":[] as [String],"lapses_at":4000,"version":1]
        let key: [String: Any] = ["challenge":challenge,"rpId":"unit.example","userVerification":"required","allowCredentials":[["type":"public-key","id":"YQ"]]]
        let value: [String: Any] = ["profile":"atarasy.member-statement-authorisation.1","operationID":id,"requestDigest":digest,"reviewedRevision":digest,"expiresAt":2000,"canonical":local.canonical,"review":["statement":statement,"mandate":mandate,"disputed":local.disputed],"operationState":"prepared","publicKey":key,"authorisation":"prepared"]
        let h: [String: Any] = ["id":id,"environment":local.environment.name,"origin":local.environment.origin.absoluteString,"sessionID":local.sessionID,"household":local.household,"presenter":local.presenter,"offer":local.offer,"canonical":local.canonical,"expiresAt":2000,"requestDigest":digest,"reviewedRevision":digest,"challenge":challenge,"credentialID":"YQ","attempted":false]
        let handle = try JSONDecoder().decode(MemberOperationHandle.self, from: JSONSerialization.data(withJSONObject: h))
        let result = try JSONDecoder().decode(MemberPreparedOperation.self, from: JSONSerialization.data(withJSONObject: value))
        try store.save(handle); prepared = result; return (handle,result)
    }
    func operationReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedOperation { guard let prepared else { throw MemberFailure.unavailable }; return prepared }
    func submitStatement(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberOperationOutcome { try store.claim(handle, confirmation: "YQ"); return .unresolved }
    func operationOutcome(_ handle: MemberOperationHandle) async -> MemberOperationOutcome { .pending("prepared") }
    func cancelOperation(_ handle: MemberOperationHandle) async throws {}
}
@MainActor private final class StatementFixturePasskeys: MemberPasskeyAuthorising {
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse { .assertion(id:"YQ",clientDataJSON:"YQ",authenticatorData:"YQ",signature:"YQ",userHandle:"YQ") }
}
struct MemberStatementFixtureView: View {
    @StateObject private var flow: MemberStatementFlow
    private let detail: MemberOfferDetail
    private let statement: MemberStatement
    init() {
        detail = try! MemberReviewFixtureData.detail(id: "fixture-member-physical")
        guard case .statement(let statement) = try! MemberReviewFixtureData.review(detail: detail) else { fatalError("Statement fixture") }
        self.statement = statement
        let environment = try! MemberEnvironment(name: "ui-fixture", origin: URL(string:"https://unit.example")!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("statement-ui-fixture")
        if ProcessInfo.processInfo.arguments.contains("--fresh") { try? FileManager.default.removeItem(at: directory) }
        let store = try! FileMemberOperationStore(directory: directory)
        let flow = MemberStatementFlow(environment: environment, service: StatementFixtureService(), passkeys: StatementFixturePasskeys(), store: store, now: { 1000 })
        let info = try! JSONDecoder().decode(MemberSessionInfo.self, from: Data(#"{"id":"test-session","household":"test-household","presenters":["Available source"],"expiresAt":5000}"#.utf8))
        flow.setSession(info); _flow = StateObject(wrappedValue: flow)
    }
    var body: some View {
        MemberStatementScreen(flow: flow, detail: detail, statement: statement)
            .safeAreaInset(edge: .top) { Text("UI fixture · no real signing or network").font(.caption).padding(.vertical, 4).frame(maxWidth: .infinity).background(.background).accessibilityIdentifier("statementFixtureLabel") }
    }
}
#endif
