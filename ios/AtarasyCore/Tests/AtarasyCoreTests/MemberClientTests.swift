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
    private func recoveryFixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "member-recovery-runtime", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func fixtureData(_ root: [String: Any], _ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: try XCTUnwrap(root[key])) }
    private func fixtureSession(_ root: [String: Any], _ key: String) throws -> MemberSessionInfo { try JSONDecoder().decode(MemberSessionInfo.self, from: fixtureData(root, key)) }
    private func fixtureAssertion(_ prepared: [String: Any]) throws -> MemberPasskeyResponse {
        let publicKey = try XCTUnwrap(prepared["publicKey"] as? [String: Any]), challenge = try XCTUnwrap(publicKey["challenge"] as? String), allowed = try XCTUnwrap(publicKey["allowCredentials"] as? [[String: Any]]), credential = try XCTUnwrap(allowed.first?["id"] as? String)
        let client = try JSONSerialization.data(withJSONObject: ["type": "webauthn.get", "origin": env.origin.absoluteString, "challenge": challenge])
        return .assertion(id: credential, clientDataJSON: PasskeyBytes.encode(client), authenticatorData: "YQ", signature: "Yg", userHandle: "Yw")
    }

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
    func testDeviceLockFencesLateReadsWithoutRevokingTheSavedSession() async throws {
        let v = try vault(), script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 200, data: offer())], holdAt: 1)
        let client = MemberClient(environment: env, transport: script, vault: v, now: { 1000 }); _ = try await client.restore(household: "own")
        let read = Task { try await client.offer(id: "offer") }; await script.waitForHold(); await client.lockLocalAccess(); await script.release()
        do { _ = try await read.value; XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .superseded) }
        do { _ = try await client.offer(id: "offer"); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .expired) }
        XCTAssertNotNil(try v.load(environment: env, household: "own"))
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
    func testPrivateNodeClientValidatesOpaqueRecordsAndSendsNoPlaintext() async throws {
        let id = "33333333-3333-4333-8333-333333333333", key = Data(repeating: 4, count: 32), clear = Data("member private record".utf8)
        let crypto = try MemberPrivateNodeCrypto(key: key), envelope = try crypto.seal(clear, environment: env, household: info.household, id: id, revision: 1)
        let record = MemberPrivateNodeRecord(id: id, revision: 1, updatedAt: 1001, envelope: envelope)
        let index = MemberPrivateNodeIndex(profile: "atarasy.private-node-index.1", checkedAt: 1000, records: [])
        let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 200, data: try data(index)), .init(status: 200, data: try data(record)), .init(status: 200, data: try data(record))])
        let client = MemberClient(environment: env, transport: script, vault: try vault(), now: { 1000 }); _ = try await client.restore(household: "own")
        let listed = try await client.privateNodeRecords(); XCTAssertEqual(listed.records, [])
        let written = try await client.writePrivateNodeRecord(id: id, expectedRevision: 0, envelope: envelope); XCTAssertEqual(written, record)
        let read = try await client.privateNodeRecord(id: id); XCTAssertEqual(read, record)
        let requests = await script.requests, body = try XCTUnwrap(requests[2].httpBody), text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("member private record")); XCTAssertFalse(text.contains(info.household)); XCTAssertEqual(requests[2].url?.path, "/member/private-node/records/" + id)
    }
    func testPrivateNodeClientRejectsUnsortedDuplicateAndPlaintextShapedHostResponses() async throws {
        let id = "44444444-4444-4444-8444-444444444444", envelope = MemberPrivateNodeEnvelope(nonce: Data(repeating: 1, count: 12).base64EncodedString(), ciphertext: Data(repeating: 2, count: 32).base64EncodedString())
        let row: [String: Any] = ["id": id, "revision": 1, "updatedAt": 1000, "envelope": ["profile": envelope.profile, "nonce": envelope.nonce, "ciphertext": envelope.ciphertext]]
        for records in [[row, row], [["id": id, "revision": 1, "updatedAt": 1000, "envelope": ["profile": envelope.profile, "nonce": envelope.nonce, "ciphertext": envelope.ciphertext, "plaintext": "secret"]]]] {
            let response = try JSONSerialization.data(withJSONObject: ["profile": "atarasy.private-node-index.1", "checkedAt": 1000, "records": records])
            let script = MemberScript([.init(status: 200, data: try data(info)), .init(status: 200, data: response)]), client = MemberClient(environment: env, transport: script, vault: try vault(), now: { 1000 })
            _ = try await client.restore(household: "own")
            do { _ = try await client.privateNodeRecords(); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .malformed) }
        }
    }
    func testActualValenceRecoveryOwnerResponsesStayScopedAndRevealSharesOnlyAfterNotice() async throws {
        let root = try recoveryFixture(), owner = try fixtureSession(root, "ownerSession"), requesterKey = ((root["created"] as! [String: Any])["requesterPublicKey"] as! String)
        let script = MemberScript([.init(status: 200, data: try fixtureData(root, "ownerSession")), .init(status: 200, data: try fixtureData(root, "configured")), .init(status: 201, data: try fixtureData(root, "created")), .init(status: 200, data: try fixtureData(root, "completed")), .init(status: 200, data: try fixtureData(root, "finalLog"))])
        let client = MemberClient(environment: env, transport: script, vault: try vault(owner), now: { 1_800_000_000_001 }); _ = try await client.restore(household: owner.household)
        let configuration = try await client.recoveryConfiguration(); XCTAssertTrue(configuration.configured); XCTAssertEqual(configuration.owner, owner.household)
        let created = try await client.createRecoveryRequest(requesterPublicKey: requesterKey); XCTAssertEqual(created.state, "pending"); XCTAssertNil(created.hostShare); XCTAssertNil(created.release)
        let completed = try await client.recoveryRequest(id: created.id); XCTAssertEqual(completed.state, "completed"); XCTAssertNotNil(completed.hostShare); XCTAssertNotNil(completed.release); XCTAssertNil(completed.recovererPacket)
        let log = try await client.recoveryLog(); XCTAssertEqual(log.events.first?.state, "completed")
        let requests = await script.requests, createBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(createBody.keys), ["requesterPublicKey"]); XCTAssertFalse(String(decoding: requests[2].httpBody!, as: UTF8.self).contains(try XCTUnwrap(completed.hostShare)))
    }
    func testActualValenceRecoveryApprovalBindsDisplayedReleaseAndNeverReturnsTheHostShare() async throws {
        let root = try recoveryFixture(), recoverer = try fixtureSession(root, "recovererSession"), preparedObject = root["preparedApproval"] as! [String: Any], release = preparedObject["release"] as! String
        let script = MemberScript([.init(status: 200, data: try fixtureData(root, "recovererSession")), .init(status: 200, data: try fixtureData(root, "preparedApproval")), .init(status: 200, data: try fixtureData(root, "approved"))])
        let client = MemberClient(environment: env, transport: script, vault: try vault(recoverer), now: { 1_800_000_000_001 }); _ = try await client.restore(household: recoverer.household)
        let requestID = ((preparedObject["request"] as! [String: Any])["id"] as! String), prepared = try await client.prepareRecoveryApproval(id: requestID, release: release)
        let approved = try await client.approveRecovery(prepared, assertion: try fixtureAssertion(preparedObject)); XCTAssertEqual(approved.state, "approved"); XCTAssertNil(approved.hostShare); XCTAssertNil(approved.keyDigest); XCTAssertNotNil(approved.recovererPacket)
        let requests = await script.requests, approvalBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(approvalBody.keys), ["preparation", "release", "assertion"]); XCTAssertEqual(approvalBody["release"] as? String, release); XCTAssertFalse(String(decoding: requests[2].httpBody!, as: UTF8.self).contains((root["configuration"] as! [String: Any])["hostShare"] as! String))
    }
    func testRecoveryClientRejectsAHostShareProjectedToTheRecoverer() async throws {
        let root = try recoveryFixture(), recoverer = try fixtureSession(root, "recovererSession"), completed = root["completed"] as! [String: Any]
        let script = MemberScript([.init(status: 200, data: try fixtureData(root, "recovererSession")), .init(status: 200, data: try JSONSerialization.data(withJSONObject: completed))]), client = MemberClient(environment: env, transport: script, vault: try vault(recoverer), now: { 1_800_000_000_001 })
        _ = try await client.restore(household: recoverer.household)
        do { _ = try await client.recoveryRequest(id: completed["id"] as! String); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .scopeMismatch) }
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

    private var mandateHousehold: String { "key:" + String(repeating: "A", count: 43) }
    private func unsignedMandate(_ ceiling: Int64 = 1200) -> MemberMandate {
        MemberMandate(id: mandateHousehold + ".1", household: mandateHousehold, ceilingOutOfNetwork: ceiling, ceilingDaily: nil, coolingSeconds: nil, coSigners: [], lapsesAt: 4000, version: 1)
    }
    private func preparedMandateData(_ m: MemberMandate, challenge: String? = nil, host: String = "unit.example") throws -> Data {
        let object: [String: Any] = ["mandate": try JSONSerialization.jsonObject(with: data(m)), "publicKey": ["challenge": try challenge ?? Canonical.challenge(m.canonical(host: host)), "rpId": host, "userVerification": "required", "allowCredentials": [["type": "public-key", "id": "YQ"]]]]
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func mandateClient(_ rest: [MemberScript.Step]) throws -> (MemberClient, MemberScript) {
        let info = MemberSessionInfo(id: "mandate-session", household: mandateHousehold, presenters: [], expiresAt: 5000)
        let script = MemberScript([.init(status: 200, data: try data(info))] + rest)
        return (MemberClient(environment: env, transport: script, vault: try vault(info), now: { 1000 }), script)
    }
    private func mandateAssertion(_ m: MemberMandate, origin: String = "https://unit.example", credential: String = "YQ") throws -> MemberPasskeyResponse {
        let client = try JSONSerialization.data(withJSONObject: ["type": "webauthn.get", "origin": origin, "challenge": Canonical.challenge(m.canonical(host: "unit.example"))])
        return .assertion(id: credential, clientDataJSON: PasskeyBytes.encode(client), authenticatorData: "Yw", signature: "ZA", userHandle: "ZQ")
    }
    func testMandateReadsExactTermsAndSubmitsNamedClaimOnce() async throws {
        let m = unsignedMandate()
        let (client, script) = try mandateClient([.init(status: 200, data: data(["mandates": [m]])), .init(status: 200, data: preparedMandateData(m)), .init(status: 200, data: data(m))])
        _ = try await client.restore(household: mandateHousehold)
        let list = try await client.unsignedMandates(); XCTAssertEqual(list, [m])
        let review = try await client.prepareMandate(list[0])
        XCTAssertEqual(review.host, "unit.example")
        try await client.submitMandate(review, assertion: mandateAssertion(m))
        do { try await client.submitMandate(review, assertion: mandateAssertion(m)); XCTFail("replayed") } catch {}
        let requests = await script.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[3].url?.path, "/member/mandates/submit")
        let body = try JSONSerialization.jsonObject(with: requests[3].httpBody!) as! [String: Any]
        XCTAssertEqual(body["mandate"] as? String, m.id)
        XCTAssertEqual(Set(body.keys), ["mandate", "assertion"])
        let wire = try XCTUnwrap(body["assertion"] as? [String: String])
        XCTAssertEqual(Set(wire.keys), ["client_data_json", "authenticator_data", "signature"])
        XCTAssertEqual(wire["authenticator_data"], "Yw==")
        XCTAssertEqual(wire["signature"], "ZA==")
        let clientBytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(wire["client_data_json"])))
        let clientData = try XCTUnwrap(JSONSerialization.jsonObject(with: clientBytes) as? [String: String])
        XCTAssertEqual(clientData["challenge"], try Canonical.challenge(m.canonical(host: "unit.example")))
    }
    func testMandateRejectsSubstitutedTermsChallengeAndHostBeforeSigning() async throws {
        let m = unsignedMandate()
        for response in [try preparedMandateData(unsignedMandate(9999), challenge: Canonical.challenge(m.canonical(host: "unit.example"))), try preparedMandateData(m, challenge: String(repeating: "A", count: 43)), try preparedMandateData(m, host: "foreign.example")] {
            let (client, script) = try mandateClient([.init(status: 200, data: response)])
            _ = try await client.restore(household: mandateHousehold)
            do { _ = try await client.prepareMandate(m); XCTFail("substitution accepted") } catch {}
            let requests = await script.requests; XCTAssertEqual(requests.count, 2)
        }
    }
    func testMandateRejectsWrongCredentialAndOriginWithoutSubmitting() async throws {
        let m = unsignedMandate()
        let (client, script) = try mandateClient([.init(status: 200, data: preparedMandateData(m))])
        _ = try await client.restore(household: mandateHousehold)
        let review = try await client.prepareMandate(m)
        for assertion in [try mandateAssertion(m, credential: "Yg"), try mandateAssertion(m, origin: "https://foreign.example")] {
            do { try await client.submitMandate(review, assertion: assertion); XCTFail("foreign assertion") } catch {}
        }
        let requests = await script.requests; XCTAssertEqual(requests.count, 2)
    }
    func testLostMandateResponseCannotReplayTheSubmission() async throws {
        let m = unsignedMandate()
        let (client, script) = try mandateClient([.init(status: 200, data: preparedMandateData(m)), .init(status: 200, data: Data(), fails: true)])
        _ = try await client.restore(household: mandateHousehold)
        let review = try await client.prepareMandate(m)
        do { try await client.submitMandate(review, assertion: mandateAssertion(m)); XCTFail() } catch { XCTAssertEqual(error as? MemberFailure, .uncertainVerification) }
        do { try await client.submitMandate(review, assertion: mandateAssertion(m)); XCTFail() } catch {}
        let requests = await script.requests; XCTAssertEqual(requests.count, 3)
    }
    func testSignOutInvalidatesMandatePreparedUnderThatSession() async throws {
        let m = unsignedMandate()
        let (client, script) = try mandateClient([.init(status: 200, data: preparedMandateData(m)), .init(status: 204, data: Data())])
        _ = try await client.restore(household: mandateHousehold)
        let review = try await client.prepareMandate(m); _ = try await client.logout()
        do { try await client.submitMandate(review, assertion: mandateAssertion(m)); XCTFail() } catch {}
        let requests = await script.requests; XCTAssertEqual(requests.count, 3)
    }
    func testDialsReadsEffectiveVersionAndSubmitsFixedZeroCosignerChangeOnce() async throws {
        let before = unsignedMandate(), after = MemberMandate(id: before.id, household: before.household, ceilingOutOfNetwork: 0, ceilingDaily: 0, coolingSeconds: 60, coSigners: [], lapsesAt: 3500, version: 2)
        let change = MemberMandateChange(id: "11111111-1111-4111-8111-111111111111", before: before, mandate: after, requiredSigners: [mandateHousehold], signedBy: [], state: "pending", createdAt: 1000, updatedAt: 1000)
        var prepared = try JSONSerialization.jsonObject(with: data(change)) as! [String: Any]
        prepared["publicKey"] = ["challenge": try Canonical.challenge(after.canonical(host: "unit.example")), "rpId": "unit.example", "userVerification": "required", "allowCredentials": [["type": "public-key", "id": "YQ"]]]
        let completed = MemberMandateChange(id: change.id, before: before, mandate: after, requiredSigners: change.requiredSigners, signedBy: change.requiredSigners, state: "effective", createdAt: 1000, updatedAt: 1001)
        let (client, script) = try mandateClient([
            .init(status: 200, data: data(["mandates": [before]])),
            .init(status: 200, data: data(["changes": [MemberMandateChange]() ])),
            .init(status: 201, data: try JSONSerialization.data(withJSONObject: prepared)),
            .init(status: 200, data: data(completed))
        ])
        _ = try await client.restore(household: mandateHousehold)
        let effective = try await client.effectiveMandates(), changes = try await client.mandateChanges()
        XCTAssertEqual(effective, [before]); XCTAssertTrue(changes.isEmpty)
        let review = try await client.prepareMandateChange(after)
        XCTAssertEqual(review.change, change)
        let result = try await client.submitMandateChange(review, assertion: mandateAssertion(after))
        XCTAssertEqual(result, completed)
        do { _ = try await client.submitMandateChange(review, assertion: mandateAssertion(after)); XCTFail("replayed") } catch {}
        let requests = await script.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/auth/session", "/member/mandates/effective", "/member/mandates/changes", "/member/mandates/changes", "/member/mandates/changes/" + change.id + "/submit"])
        let body = try JSONSerialization.jsonObject(with: requests[4].httpBody!) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["assertion"])
    }

}
