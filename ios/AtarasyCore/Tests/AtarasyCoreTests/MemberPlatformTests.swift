import Foundation
import XCTest
@testable import AtarasyCore

private final class ProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data("{}".utf8)
    private var redirect = false
    private var decisions = 0
    private var seen: [URLRequest] = []
    func reset(body: Data = Data("{}".utf8), redirect: Bool = false) { lock.withLock { self.body = body; self.redirect = redirect; seen = []; decisions = 0 } }
    func response(_ request: URLRequest) -> (Data, Bool) { lock.withLock { seen.append(request); return (body, redirect && request.url?.path == "/redirect") } }
    func deniedRedirect() { lock.withLock { decisions += 1 } }
    var redirectDecisions: Int { lock.withLock { decisions } }
    var requests: [URLRequest] { lock.withLock { seen } }
}
private final class ControlledMemberProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, redirect) = Self.state.response(request)
        if redirect {
            let target = URLRequest(url: URL(string: "https://foreign.example/target")!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.url!.absoluteString, "Cache-Control": "no-store"])!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store", "Set-Cookie": "fixture=ambient"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class MemberPlatformTests: XCTestCase {
    func testActualURLSessionDisablesCookieReuseAndBoundsResponseData() async throws {
        ControlledMemberProtocol.state.reset()
        let transport = try URLSessionMemberTransport(timeout: 2, maximumResponseBytes: 16, protocolClasses: [ControlledMemberProtocol.self])
        let request = URLRequest(url: URL(string: "https://unit.example/auth/session")!)
        for _ in 0..<2 { let response = try await transport.send(request); XCTAssertEqual(response.status, 200); XCTAssertEqual(response.data, Data("{}".utf8)) }
        XCTAssertTrue(ControlledMemberProtocol.state.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        ControlledMemberProtocol.state.reset(body: Data(repeating: 65, count: 17))
        do { _ = try await transport.send(request); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .malformed) }
    }
    func testActualURLSessionDoesNotFollowCrossOriginRedirect() async throws {
        ControlledMemberProtocol.state.reset(redirect: true)
        let transport = try URLSessionMemberTransport(timeout: 2, maximumResponseBytes: 16, protocolClasses: [ControlledMemberProtocol.self], redirectObserver: { ControlledMemberProtocol.state.deniedRedirect() })
        var request = URLRequest(url: URL(string: "https://unit.example/redirect")!)
        request.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization")
        // Foundation may terminate a custom URLProtocol redirect with an error
        // after the delegate refuses it. Both paths must avoid dispatching the target.
        do { let response = try await transport.send(request); XCTAssertEqual(response.status, 302) }
        catch { XCTAssertTrue(error is URLError) }
        XCTAssertEqual(ControlledMemberProtocol.state.redirectDecisions, 1)
        XCTAssertEqual(ControlledMemberProtocol.state.requests.count, 1)
        XCTAssertEqual(ControlledMemberProtocol.state.requests.first?.url?.host, "unit.example")
    }
    func testKeychainRoundTripScopeIsolationAndExactUnicodeAccountKeys() throws {
        let store = try KeychainMemberSessionVault(namespace: "dev.atarasy.unit." + UUID().uuidString)
        let env = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!)
        let other = try MemberEnvironment(name: "test", origin: URL(string: "https://other.example")!)
        let info = MemberSessionInfo(id: "fixture", household: "é", presenters: ["presenter"], expiresAt: 5000)
        let session = StoredMemberSession(token: "amr1_" + String(repeating: "A", count: 43), info: info)
        defer { try? store.remove(environment: env, household: info.household) }
        do { try store.save(session, environment: env) }
        catch { throw XCTSkip("Host Keychain access unavailable; simulator/device entitlement evidence is still required.") }
        XCTAssertEqual(try store.load(environment: env, household: "é")?.info.id, "fixture")
        XCTAssertNil(try store.load(environment: env, household: "e\u{301}"))
        XCTAssertNil(try store.load(environment: other, household: "é"))
        try store.remove(environment: env, household: "é")
        XCTAssertNil(try store.load(environment: env, household: "é"))
    }
    func testEnvironmentRejectsNonHTTPSAndAmbiguousOrInjectedComponents() throws {
        for value in ["http://unit.example", "https://user:password@unit.example", "https://unit.example/path", "https://unit.example?x=1", "https://unit.example#part"] {
            XCTAssertThrowsError(try MemberEnvironment(name: "test", origin: URL(string: value)!))
        }
        XCTAssertThrowsError(try MemberEnvironment(name: "test\n", origin: URL(string: "https://unit.example")!))
    }
}
