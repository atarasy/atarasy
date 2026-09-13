import Foundation
import XCTest
@testable import AtarasyCore

private final class TestMemberVault: MemberSessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: StoredMemberSession] = [:]
    let failRemoval: Bool
    init(failRemoval: Bool = false) { self.failRemoval = failRemoval }
    private func key(_ e: MemberEnvironment, _ household: String) -> String { [e.name, e.origin.absoluteString, Data(household.utf8).base64EncodedString()].joined(separator: "|") }
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { lock.withLock { values[key(environment, household)] } }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws { lock.withLock { values[key(environment, session.info.household)] = session } }
    func remove(environment: MemberEnvironment, household: String) throws {
        if failRemoval { throw MemberFailure.storage }
        _ = lock.withLock { values.removeValue(forKey: key(environment, household)) }
    }
}
private final class MemberTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: Int64 = 1000
    func now() -> Int64 { lock.withLock { time } }
    func set(_ n: Int64) { lock.withLock { time = n } }
}
private actor MemberScript: MemberHTTPTransport {
    struct Step: Sendable { let status: Int; let data: Data; var type: String? = "application/json"; var cache: String? = "no-store"; var fails = false }
    let steps: [Step]; let holdAt: Int?
    var requests: [URLRequest] = []
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ steps: [Step], holdAt: Int? = nil) { self.steps = steps; self.holdAt = holdAt }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        let i = requests.count; requests.append(request)
        if holdAt == i {
            await withCheckedContinuation { held = $0; waiters.forEach { $0.resume() }; waiters.removeAll() }
        }
        guard i < steps.count else { throw MemberFailure.unavailable }
        let step = steps[i]; if step.fails { throw URLError(.networkConnectionLost) }
        return MemberHTTPReply(url: request.url!, status: step.status, contentType: step.type, cacheControl: step.cache, data: step.data)
    }
    func waitForHold() async { if held != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { held?.resume(); held = nil }
}
@MainActor final class MemberClientTests: XCTestCase {
    private let token = "amr1_" + String(repeating: "A", count: 43)
    private var env: MemberEnvironment { try! MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!) }
    private var info: MemberSessionInfo { MemberSessionInfo(id: "session", household: "own", presenters: ["presenter"], expiresAt: 5000) }
    private func data<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private var flow: MemberCeremony { MemberCeremony(id: "00000000-0000-0000-0000-000000000000", expiresAt: 2000, publicKey: [:]) }
    private var assertion: MemberPasskeyResponse { .assertion(id: "YQ", clientDataJSON: "Yg", authenticatorData: "Yw", signature: "ZA", userHandle: "ZQ") }
    private func vault(_ info: MemberSessionInfo? = nil, failRemoval: Bool = false) throws -> TestMemberVault {
        let v = TestMemberVault(failRemoval: failRemoval); try v.save(StoredMemberSession(token: token, info: info ?? self.info), environment: env); return v
    }
    private func offer(_ household: String = "own") -> Data { Data("{\"id\":\"offer\",\"household\":\"\(household)\",\"presenter\":\"presenter\",\"binding\":\"digital\",\"state\":\"drafted\"}".utf8) }

    func testVerifiedLoginInspectsBeforeSavingAndBindsBearerToNamedOrigin() async throws {
        let grant = Data("{\"id\":\"session\",\"token\":\"\(token)\",\"expiresAt\":5000}".utf8)
        let script = MemberScript([.init(status: 200, data: grant), .init(status: 200, data: try data(info)), .init(status: 200, data: offer())])
        let v = TestMemberVault(); let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        let logged = try await client.login(ceremony: flow, response: assertion); XCTAssertEqual(logged.household, "own")
        XCTAssertEqual(try v.load(environment: env, household: "own")?.info, info)
        let read = try await client.offer(id: "offer"); XCTAssertEqual(read.id, "offer")
        let requests = await script.requests
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization")); XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "unit.example" && $0.value(forHTTPHeaderField: "Cookie") == nil })
        let object = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["id", "response"])
    }
    func testDifferentInspectionCannotPersistTheIssuedSession() async throws {
        let bad = MemberSessionInfo(id: "substituted", household: "foreign", presenters: [], expiresAt: 5000)
        let grant = Data("{\"id\":\"session\",\"token\":\"\(token)\",\"expiresAt\":5000}".utf8)
        let script = MemberScript([.init(status: 200, data: grant), .init(status: 200, data: try data(bad))]); let v = TestMemberVault()
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        do { _ = try await client.login(ceremony: flow, response: assertion); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .uncertainVerification) }
        XCTAssertNil(try v.load(environment: env, household: "foreign"))
    }
    func testRestoreScopeExpiryAndForeignOfferRefusal() async throws {
        let v = try vault(); let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 200, data: offer("foreign"))])
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        let absent = try await client.restore(household: "other"); XCTAssertNil(absent)
        _ = try await client.restore(household: "own")
        do { _ = try await client.offer(id: "offer"); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .scopeMismatch) }
        let other = try MemberEnvironment(name: "production", origin: env.origin); XCTAssertNil(try v.load(environment: other, household: "own"))
        let expired = MemberClient(environment: env, transport: script, vault: v, now: { 5000 })
        do { _ = try await expired.restore(household: "own"); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .expired) }
        XCTAssertNil(try v.load(environment: env, household: "own"))
    }
    func testLogoutClearsLocallyEvenIfRemoteAcknowledgementIsLost() async throws {
        let v = try vault(); let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 0, data: Data(), fails: true)])
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 }); _ = try await client.restore(household: "own")
        do { _ = try await client.logout(); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .remoteLogoutUnconfirmed) }
        XCTAssertNil(try v.load(environment: env, household: "own"))
        do { _ = try await client.offer(id: "offer"); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .expired) }
        let requests = await script.requests; XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].httpBody, Data("{}".utf8))
    }
    func testEmpty204AndLocalStorageFailureHaveDistinctOutcomes() async throws {
        for fails in [false, true] {
            let v = try vault(failRemoval: fails); let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 204, data: Data(), type: nil)])
            let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 }); _ = try await client.restore(household: "own")
            do { let result = try await client.logout(); if fails { XCTFail() }; if case .revoked = result {} else { XCTFail() } }
            catch { XCTAssertTrue(fails); XCTAssertEqual(error as? MemberFailure, .storage) }
            let calls = await script.requests.count; XCTAssertEqual(calls, fails ? 1 : 2)
        }
    }
    func testReadSuspendedAcrossLogoutCannotReturnOldAccountData() async throws {
        let v = try vault(); let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 200, data: offer()), .init(status: 204, data: Data(), type: nil)], holdAt: 1)
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 }); _ = try await client.restore(household: "own")
        let read = Task { try await client.offer(id: "offer") }; await script.waitForHold()
        _ = try await client.logout(); await script.release()
        do { _ = try await read.value; XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .superseded) }
    }
    func testInFlightLoginCannotRestoreAfterLogoutAndSecondLoginIsRefused() async throws {
        let grant = Data("{\"id\":\"session\",\"token\":\"\(token)\",\"expiresAt\":5000}".utf8)
        let script = MemberScript([.init(status: 200, data: grant)], holdAt: 0); let v = TestMemberVault()
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        let pending = Task { try await client.login(ceremony: flow, response: assertion) }; await script.waitForHold()
        do { _ = try await client.login(ceremony: flow, response: assertion); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .busy) }
        _ = try await client.logout(); await script.release()
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .superseded) }
        XCTAssertNil(try v.load(environment: env, household: "own"))
    }
    func testExpiryDuringReadAnd401InvalidateOnlyTheCurrentAccount() async throws {
        for status in [200, 401] {
            let clock = MemberTestClock(), v = try vault()
            let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: status, data: offer())], holdAt: 1)
            let client = MemberClient(environment: env, transport: script, vault: v, now: { clock.now() }); _ = try await client.restore(household: "own")
            let read = Task { try await client.offer(id: "offer") }; await script.waitForHold(); if status == 200 { clock.set(5000) }; await script.release()
            do { _ = try await read.value; XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, status == 200 ? .expired : .http(401)) }
            XCTAssertNil(try v.load(environment: env, household: "own"))
        }
    }
    func testVerificationLossIsNotRetriedAndMalformedReadsAreNotEmptySuccess() async throws {
        let script = MemberScript([.init(status: 0, data: Data(), fails: true)]); let client = MemberClient(environment: env, transport: script, vault: TestMemberVault(), now: { 1000 })
        do { _ = try await client.login(ceremony: flow, response: assertion); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .uncertainVerification) }
        let calls = await script.requests.count; XCTAssertEqual(calls, 1)
        let readScript = MemberScript([.init(status: 200, data: try data(info)), .init(status: 200, data: Data("[]".utf8))]); let reader = MemberClient(environment: env, transport: readScript, vault: try vault(), now: { 1000 }); _ = try await reader.restore(household: "own")
        do { _ = try await reader.offers(presenter: "presenter"); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .malformed) }
    }
    func testOptionsValidateRPAndDoNotSendStoredCredentials() async throws {
        let payload = Data("{\"id\":\"\(flow.id)\",\"expiresAt\":2000,\"publicKey\":{\"challenge\":\"\(String(repeating: "A", count: 43))\",\"rpId\":\"foreign.example\",\"allowCredentials\":[],\"userVerification\":\"required\"}}".utf8)
        let script = MemberScript([.init(status: 200, data: payload)]); let client = MemberClient(environment: env, transport: script, vault: try vault(), now: { 1000 })
        do { _ = try await client.loginOptions(); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .scopeMismatch) }
        let requests = await script.requests; XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        do { _ = try await client.offer(id: "a/b"); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .invalidInput) }
    }
    private func captured(_ name: String) throws -> MemberScript.Step {
        let url = Bundle.module.url(forResource: "member-auth-responses", withExtension: "json", subdirectory: "Fixtures")!
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let entry = (root["cases"] as! [String: [String: Any]])[name]!
        let value = entry["value"]!
        return .init(status: entry["status"] as! Int, data: value is NSNull ? Data() : try JSONSerialization.data(withJSONObject: value), type: entry["contentType"] as? String, cache: entry["cacheControl"] as? String)
    }
    func testSevenCapturedServiceResponsesDecodeAcrossTheNativeLifecycle() async throws {
        let names = ["registration-options", "registered", "login-options", "session-issued", "session-info", "logout", "revoked"]
        let script = MemberScript(try names.map { try captured($0) }), v = TestMemberVault()
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        let registration = try await client.registrationOptions(invitation: "aen1_" + String(repeating: "A", count: 43))
        try await client.register(ceremony: registration, response: .registration(id: "YQ", clientDataJSON: "Yg", attestationObject: "Yw"))
        let challenge = try await client.loginOptions()
        let session = try await client.login(ceremony: challenge, response: assertion)
        XCTAssertEqual(session.household, "household-fixture")
        let stored = try XCTUnwrap(v.load(environment: env, household: session.household))
        _ = try await client.logout()
        // A restored stale local record must still be checked against server revocation.
        try v.save(stored, environment: env)
        do { _ = try await client.restore(household: session.household); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .http(401)) }
        XCTAssertNil(try v.load(environment: env, household: session.household))
        let requests = await script.requests; XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests[0].url?.path, "/auth/enrollment/options")
        XCTAssertEqual(requests[5].url?.path, "/auth/logout")
    }
    func testListQueryPreservesLiteralPlusAndReservedCharacters() async throws {
        let special = MemberSessionInfo(id: "session", household: "own+one", presenters: ["shop+tea&rice"], expiresAt: 5000)
        let v = try vault(special), script = MemberScript([.init(status: 200, data: try data(special)), .init(status: 200, data: Data("{\"offers\":[]}".utf8))])
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        _ = try await client.restore(household: special.household)
        _ = try await client.offers(presenter: special.presenters[0])
        let requests = await script.requests
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "household=own%2Bone&presenter=shop%2Btea%26rice")
    }

    func testLate401FromPreviousAccountCannotEraseTheNewAccount() async throws {
        let v = try vault()
        let other = MemberSessionInfo(id: "other-session", household: "other", presenters: ["presenter"], expiresAt: 5000)
        try v.save(StoredMemberSession(token: "amr1_" + String(repeating: "B", count: 43), info: other), environment: env)
        let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 401, data: Data()), .init(status: 200, data: try data(other)), .init(status: 200, data: offer("other"))], holdAt: 1)
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 })
        _ = try await client.restore(household: "own")
        let pending = Task { try await client.offer(id: "offer") }; await script.waitForHold()
        _ = try await client.restore(household: "other"); await script.release()
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .superseded) }
        XCTAssertNotNil(try v.load(environment: env, household: "other"))
        let current = try await client.offer(id: "offer"); XCTAssertEqual(current.household, "other")
    }

}
