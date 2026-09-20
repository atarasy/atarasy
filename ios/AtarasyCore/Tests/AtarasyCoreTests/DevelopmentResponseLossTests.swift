import XCTest
@testable import AtarasyCore

private actor AcceptanceTransport: MemberHTTPTransport {
    var paths: [String] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        paths.append(request.url!.path)
        return MemberHTTPReply(url: request.url!, status: status, contentType: "application/json", cacheControl: "no-store", data: Data("{}".utf8))
    }
}
@MainActor final class DevelopmentResponseLossTests: XCTestCase {
    let origin = URL(string: "https://api-dev.vox.delivery")!
    func request(_ path: String, method: String = "POST") -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: origin)!.absoluteURL); r.httpMethod = method; return r
    }
    let submit = "/member/operations/00000000-0000-0000-0000-000000000000/submit"
    func testCompletesExactlyOneSubmissionBeforeDiscardingOnlyItsResponse() async throws {
        let base = AcceptanceTransport()
        let transport = try DevelopmentResponseLossTransport(base: base, environment: MemberEnvironment(name: "development", origin: origin))
        _ = try await transport.send(request("/auth/login/verify"))
        do { _ = try await transport.send(request(submit)); XCTFail("response should be lost") } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let paths = await base.paths; XCTAssertEqual(paths, ["/auth/login/verify", submit])
        _ = try await transport.send(request(submit))
        _ = try await transport.send(request(submit.replacingOccurrences(of: "/submit", with: "/outcome"), method: "GET"))
        let after = await base.paths; XCTAssertEqual(after.count, 4)
    }
    func testRefusesOtherOriginsAndEnvironments() throws {
        for environment in [try MemberEnvironment(name: "production", origin: origin), try MemberEnvironment(name: "development", origin: URL(string: "https://other.example")!)] {
            XCTAssertThrowsError(try DevelopmentResponseLossTransport(base: AcceptanceTransport(), environment: environment))
        }
    }
    func testServerRefusalIsNotReportedAsDiscardedSuccess() async throws {
        let transport = try DevelopmentResponseLossTransport(base: AcceptanceTransport(status: 404), environment: MemberEnvironment(name: "development", origin: origin))
        let reply = try await transport.send(request(submit)); XCTAssertEqual(reply.status, 404)
    }
}
