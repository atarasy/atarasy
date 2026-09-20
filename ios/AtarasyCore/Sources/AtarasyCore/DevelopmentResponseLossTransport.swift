import Foundation

/// Opt-in development acceptance fault. No assertion is changed or replayed.
/// The underlying service completes, then one successful submit response is lost.
public actor DevelopmentResponseLossTransport: MemberHTTPTransport {
    private let base: any MemberHTTPTransport
    private let origin: URL
    private var claimed = false
    private let onDrop: @Sendable () -> Void
    public init(base: any MemberHTTPTransport, environment: MemberEnvironment, onDrop: @escaping @Sendable () -> Void = {}) throws {
        guard environment.name == "development", environment.origin.absoluteString == "https://api-dev.vox.delivery" else { throw MemberFailure.invalidInput }
        self.base = base; origin = environment.origin; self.onDrop = onDrop
    }
    public func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        let eligible = !claimed && request.httpMethod == "POST" && request.url?.scheme == origin.scheme && request.url?.host == origin.host && request.url?.port == origin.port && request.url?.path.range(of: "^/member/operations/[a-f0-9-]{36}/submit$", options: .regularExpression) != nil
        // Reserve before suspension so concurrent submissions cannot both be intercepted.
        if eligible { claimed = true }
        let reply = try await base.send(request)
        if eligible && reply.status == 200 { onDrop(); throw URLError(.networkConnectionLost) }
        return reply
    }
}
