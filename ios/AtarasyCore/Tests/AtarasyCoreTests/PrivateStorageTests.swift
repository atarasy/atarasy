import CryptoKit
import XCTest
@testable import AtarasyCore

private final class MemoryOperationKeys: MemberOperationKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func key(scope: String, create: Bool) throws -> Data? { lock.withLock { if let value = values[scope] { return value }; guard create else { return nil }; let value = Data(repeating: UInt8(values.count + 1), count: 32); values[scope] = value; return value } }
    func install(key: Data, scope: String) throws { try lock.withLock { if let old = values[scope], old != key { throw MemberFailure.storage }; values[scope] = key } }
    func removeAll() { lock.withLock { values = [:] } }
    var count: Int { lock.withLock { values.count } }
}
private actor MemoryPrivateNodeService: MemberPrivateNodeService {
    var records: [String: MemberPrivateNodeRecord] = [:]
    func privateNodeRecords() async throws -> MemberPrivateNodeIndex { .init(profile: "atarasy.private-node-index.1", checkedAt: 1_800_000_000_000, records: records.values.sorted { $0.id < $1.id }) }
    func privateNodeRecord(id: String) async throws -> MemberPrivateNodeRecord { guard let value = records[id] else { throw MemberFailure.http(404) }; return value }
    func writePrivateNodeRecord(id: String, expectedRevision: Int64, envelope: MemberPrivateNodeEnvelope) async throws -> MemberPrivateNodeRecord {
        guard (records[id]?.revision ?? 0) == expectedRevision else { throw MemberFailure.http(409) }
        let value = MemberPrivateNodeRecord(id: id, revision: expectedRevision + 1, updatedAt: 1_800_000_000_001, envelope: envelope); records[id] = value; return value
    }
    func encodedRecord(_ id: String) throws -> String { String(decoding: try JSONEncoder().encode(records[id]), as: UTF8.self) }
}
private final class MemoryRecoveryMaterials: MemberRecoveryMaterialVault, @unchecked Sendable {
    private let lock = NSLock(); private var agreement: [String: MemberRecoveryKeyPair] = [:], requester: [String: MemberRecoveryKeyPair] = [:], shares: [String: MemberRecoveryShare] = [:]
    func agreementKey(scope: String, create: Bool) throws -> MemberRecoveryKeyPair? { lock.withLock { if let value = agreement[scope] { return value }; guard create else { return nil }; let value = MemberRecoveryKeyPair(); agreement[scope] = value; return value } }
    func requesterKey(scope: String, create: Bool) throws -> MemberRecoveryKeyPair? { lock.withLock { if let value = requester[scope] { return value }; guard create else { return nil }; let value = MemberRecoveryKeyPair(); requester[scope] = value; return value } }
    func saveDeviceShare(_ share: MemberRecoveryShare, scope: String, epoch: Int64) throws { lock.withLock { shares[scope + "." + String(epoch)] = share } }
    func deviceShare(scope: String, epoch: Int64) throws -> MemberRecoveryShare? { lock.withLock { shares[scope + "." + String(epoch)] } }
    func removeRequesterKey(scope: String) throws { _ = lock.withLock { requester.removeValue(forKey: scope) } }
}
private actor CompletedRecoveryService: MemberRecoveryService {
    let request: MemberRecoveryRequest; let storedLog: MemberRecoveryLog
    init(request: MemberRecoveryRequest) { self.request = request; storedLog = .init(profile: "atarasy.member-recovery-log.1", owner: request.owner, events: [.init(id: "99999999-9999-4999-8999-999999999999", owner: request.owner, recovery: request.id, recoverer: request.recoverer, state: "completed", occurredAt: 1_800_000_000_000, deliveredAt: 1_800_000_000_001, receipt: "delivered")]) }
    func recoveryRequest(id: String) async throws -> MemberRecoveryRequest { guard id == request.id else { throw MemberFailure.unavailable }; return request }
    func recoveryRequests() async throws -> [MemberRecoveryRequest] { [request] }
    func recoveryLog() async throws -> MemberRecoveryLog { storedLog }
    func recoveryKeyStatus() async throws -> MemberRecoveryKeyStatus { throw MemberFailure.unavailable }
    func prepareRecoveryKey(_ key: String) async throws -> PreparedMemberRecoveryKey { throw MemberFailure.unavailable }
    func registerRecoveryKey(_ prepared: PreparedMemberRecoveryKey, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryKeyStatus { throw MemberFailure.unavailable }
    func recoveryParticipant(_ household: String) async throws -> MemberRecoveryParticipantKey { throw MemberFailure.unavailable }
    func recoveryConfiguration() async throws -> MemberRecoveryConfiguration { throw MemberFailure.unavailable }
    func prepareRecoveryConfiguration(_ draft: MemberRecoveryConfigurationDraft, recovererKeyDigest: String) async throws -> PreparedMemberRecoveryConfiguration { throw MemberFailure.unavailable }
    func submitRecoveryConfiguration(_ prepared: PreparedMemberRecoveryConfiguration, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryConfiguration { throw MemberFailure.unavailable }
    func createRecoveryRequest(requesterPublicKey: String) async throws -> MemberRecoveryRequest { throw MemberFailure.unavailable }
    func prepareRecoveryApproval(id: String, release: String) async throws -> PreparedMemberRecoveryApproval { throw MemberFailure.unavailable }
    func approveRecovery(_ prepared: PreparedMemberRecoveryApproval, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryRequest { throw MemberFailure.unavailable }
}
@MainActor private final class NoRecoveryPasskeys: MemberPasskeyAuthorising {
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse { throw MemberFailure.unavailable }
}

final class PrivateStorageTests: XCTestCase {
    private func base64url(_ value: String) throws -> Data {
        var fixed = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); fixed += String(repeating: "=", count: (4 - fixed.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: fixed))
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func handle(environment: MemberEnvironment, household: String = "key:private-household") -> MemberOperationHandle {
        MemberOperationHandle(id: "11111111-1111-4111-8111-111111111111", environment: environment.name, origin: environment.origin, sessionID: "private-session", household: household, presenter: "private-presenter", offer: "private-offer", canonical: "PRIVATE-CANONICAL-CONTENT", expiresAt: 1_900_000_000_000, requestDigest: String(repeating: "a", count: 64), reviewedRevision: String(repeating: "b", count: 64), challenge: String(repeating: "C", count: 43), credentialID: "private-credential", attempted: false)
    }
    func testProtectedOperationJournalContainsNoPlaintextAndReopensWithSameInstallationKey() async throws {
        let env = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!), keys = MemoryOperationKeys(), dir = try directory(), value = handle(environment: env)
        let store = try ProtectedFileMemberOperationStore(directory: dir, environment: env, vault: keys)
        try store.save(value)
        let file = dir.appendingPathComponent(value.id + ".private"), bytes = try Data(contentsOf: file), text = String(decoding: bytes, as: UTF8.self)
        for secret in [value.household, value.presenter, value.offer, value.canonical, value.credentialID] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertEqual(try ProtectedFileMemberOperationStore(directory: dir, environment: env, vault: keys).load(id: value.id), value)
        try store.claim(value, confirmation: "submitted-signature")
        XCTAssertTrue(try XCTUnwrap(store.load(id: value.id)).attempted)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let node = MemberPrivateNode(environment: env, service: MemoryPrivateNodeService(), vault: keys)
        let opened = try await node.open(session: .init(id: "session", household: value.household, presenters: [], expiresAt: 1_900_000_000_000))
        XCTAssertEqual(opened, .ready)
        XCTAssertEqual(keys.count, 1)
    }
    func testMissingInstallationKeyAndTamperedCiphertextNeverYieldAHandle() throws {
        let env = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!), keys = MemoryOperationKeys(), dir = try directory(), value = handle(environment: env)
        let store = try ProtectedFileMemberOperationStore(directory: dir, environment: env, vault: keys); try store.save(value); keys.removeAll()
        XCTAssertThrowsError(try store.load(id: value.id))
        let replacement = MemoryOperationKeys(), newStore = try ProtectedFileMemberOperationStore(directory: dir, environment: env, vault: replacement)
        XCTAssertThrowsError(try newStore.load(id: value.id))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(value.id + ".private"))) as? [String: Any])
        object["ciphertext"] = Data(repeating: 9, count: 64).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent(value.id + ".private"), options: .atomic)
        XCTAssertThrowsError(try newStore.load(id: value.id))
    }
    func testOperationJournalRefusesAnotherEnvironmentAndInstallationIdentityChangesOnlyWithItsFile() throws {
        let env = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!), other = try MemberEnvironment(name: "test", origin: URL(string: "https://other.example")!), dir = try directory()
        let store = try ProtectedFileMemberOperationStore(directory: dir.appendingPathComponent("records"), environment: env, vault: MemoryOperationKeys())
        XCTAssertThrowsError(try store.save(handle(environment: other)))
        let firstFile = dir.appendingPathComponent("first/id"), secondFile = dir.appendingPathComponent("second/id")
        let first = try MemberInstallationIdentity(file: firstFile), reopened = try MemberInstallationIdentity(file: firstFile), second = try MemberInstallationIdentity(file: secondFile)
        XCTAssertEqual(first.value, reopened.value); XCTAssertNotEqual(first.value, second.value)
    }
    func testPrivateNodeEncryptsBeforeHostStorageAndMissingDeviceKeyRequiresRecovery() async throws {
        let env = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!), session = MemberSessionInfo(id: "private-session", household: "key:private-household", presenters: [], expiresAt: 1_900_000_000_000)
        let service = MemoryPrivateNodeService(), keys = MemoryOperationKeys(), node = MemberPrivateNode(environment: env, service: service, vault: keys)
        let opened = try await node.open(session: session); XCTAssertEqual(opened, .ready)
        let id = "22222222-2222-4222-8222-222222222222", secret = Data("private purchase and note".utf8)
        let written = try await node.write(id: id, expectedRevision: 0, clear: secret); XCTAssertEqual(written.revision, 1)
        let clear = try await node.read(id: id); XCTAssertEqual(clear, secret)
        let recoveryKey = try await node.recoveryKey(session: session)
        let hosted = try await service.encodedRecord(id); XCTAssertFalse(hosted.contains("private purchase")); XCTAssertFalse(hosted.contains(session.household))
        await node.lock(); let locked = await node.state; XCTAssertEqual(locked, .locked); await XCTAssertThrowsErrorAsync { _ = try await node.read(id: id) }
        let replacement = MemoryOperationKeys(), reinstalled = MemberPrivateNode(environment: env, service: service, vault: replacement)
        let reopened = try await reinstalled.open(session: session); XCTAssertEqual(reopened, .recoveryRequired)
        await XCTAssertThrowsErrorAsync { _ = try await reinstalled.read(id: id) }
        await XCTAssertThrowsErrorAsync { try await reinstalled.installRecoveredKey(Data(repeating: 9, count: 32), session: session) }
        XCTAssertEqual(replacement.count, 0)
        try await reinstalled.installRecoveredKey(recoveryKey, session: session)
        let recoveredState = await reinstalled.state, recoveredClear = try await reinstalled.read(id: id)
        XCTAssertEqual(recoveredState, .ready); XCTAssertEqual(recoveredClear, secret)
    }
    func testActualValenceAESRecordDecryptsWithTheNativeProfile() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "member-private-node-runtime", withExtension: "json", subdirectory: "Fixtures")), data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]), environmentObject = root["environment"] as! [String: Any]
        XCTAssertEqual(root["profile"] as? String, "atarasy.private-node-fixture.1")
        let environment = try MemberEnvironment(name: environmentObject["name"] as! String, origin: URL(string: environmentObject["origin"] as! String)!)
        let recordData = try JSONSerialization.data(withJSONObject: root["record"]!), record = try JSONDecoder().decode(MemberPrivateNodeRecord.self, from: recordData)
        let clear = try MemberPrivateNodeCrypto(key: base64url(root["key"] as! String)).open(record, environment: environment, household: root["household"] as! String)
        XCTAssertEqual(clear, try base64url(root["clear"] as! String))
        var changed = recordData; changed[changed.index(before: changed.endIndex)] ^= 1
        XCTAssertThrowsError(try JSONDecoder().decode(MemberPrivateNodeRecord.self, from: changed))
    }
    func testRecoverySharesRequireTwoDistinctParticipantsAndEveryPairRestoresTheLedgerKey() throws {
        let key = Data((0..<32).map(UInt8.init)), shares = try MemberRecoveryShares.split(key: key)
        XCTAssertEqual(shares.map(\.participant), [.device, .recoverer, .host])
        XCTAssertEqual(try MemberRecoveryShares.recover(shares[0], shares[1]), key)
        XCTAssertEqual(try MemberRecoveryShares.recover(shares[0], shares[2]), key)
        XCTAssertEqual(try MemberRecoveryShares.recover(shares[1], shares[2]), key)
        XCTAssertThrowsError(try MemberRecoveryShares.recover(shares[0], shares[0]))
        var changed = shares[0].bytes; changed[changed.index(before: changed.endIndex)] ^= 1
        XCTAssertThrowsError(try MemberRecoveryShares.recover(.init(participant: .device, bytes: changed), shares[1]))
        XCTAssertEqual(try MemberRecoveryCodec.data(MemberRecoveryShares.digest(key)).count, 32)
    }
    func testRecoveryPacketIsEndToEndEncryptedAndBoundToTheExactCeremony() throws {
        let recipient = MemberRecoveryKeyPair(), other = MemberRecoveryKeyPair(), clear = Data(repeating: 7, count: 64)
        let context = MemberRecoveryPacketContext(purpose: "recoverer-share", owner: "key:owner", recoverer: "key:recoverer", reference: "configuration-1", epoch: 1)
        let packet = try MemberRecoveryPackets.seal(clear, recipientPublicKey: recipient.publicKey, context: context)
        let hosted = try MemberRecoveryCodec.data(packet)
        XCTAssertGreaterThanOrEqual(hosted.count, 96); XCTAssertLessThanOrEqual(hosted.count, 2048)
        XCTAssertFalse(String(decoding: hosted, as: UTF8.self).contains(MemberRecoveryCodec.b64(clear)))
        XCTAssertEqual(try MemberRecoveryPackets.open(packet, recipient: recipient, context: context), clear)
        XCTAssertThrowsError(try MemberRecoveryPackets.open(packet, recipient: other, context: context))
        let changed = MemberRecoveryPacketContext(purpose: context.purpose, owner: context.owner, recoverer: context.recoverer, reference: "other", epoch: context.epoch)
        XCTAssertThrowsError(try MemberRecoveryPackets.open(packet, recipient: recipient, context: changed))
    }
    @MainActor func testCompletedRecoveryFlowReconstructsVerifiesAndInstallsTheKeyOnAReplacementDevice() async throws {
        let environment = try MemberEnvironment(name: "test", origin: URL(string: "https://unit.example")!), session = MemberSessionInfo(id: "session", household: "key:recovery-owner", presenters: [], expiresAt: 1_900_000_000_000), host = MemoryPrivateNodeService(), originalKeys = MemoryOperationKeys(), original = MemberPrivateNode(environment: environment, service: host, vault: originalKeys)
        let originalState = try await original.open(session: session); XCTAssertEqual(originalState, .ready); let key = try await original.recoveryKey(session: session)
        let replacementKeys = MemoryOperationKeys(), replacement = MemberPrivateNode(environment: environment, service: host, vault: replacementKeys), replacementState = try await replacement.open(session: session); XCTAssertEqual(replacementState, .recoveryRequired)
        let shares = try MemberRecoveryShares.split(key: key), recoverer = try XCTUnwrap(shares.first { $0.participant == .recoverer }), hostShare = try XCTUnwrap(shares.first { $0.participant == .host }), materials = MemoryRecoveryMaterials()
        let scope = SHA256.hash(data: MemberRecoveryCodec.canonical(["atarasy.private-node-scope.1", environment.name, environment.origin.absoluteString, session.household])).map { String(format: "%02x", $0) }.joined(), requester = try XCTUnwrap(materials.requesterKey(scope: scope, create: true)), id = "88888888-8888-4888-8888-888888888888", recovererID = "key:recovery-helper"
        let context = MemberRecoveryPacketContext(purpose: "requester-release", owner: session.household, recoverer: recovererID, reference: id, epoch: 1), release = try MemberRecoveryPackets.seal(recoverer.bytes, recipientPublicKey: requester.publicKey, context: context)
        let request = MemberRecoveryRequest(profile: "atarasy.member-recovery-request.1", id: id, owner: session.household, recoverer: recovererID, epoch: 1, requesterPublicKey: requester.publicKey, state: "completed", createdAt: 1_800_000_000_000, updatedAt: 1_800_000_000_001, recovererPacket: nil, release: release, hostShare: MemberRecoveryCodec.b64(hostShare.bytes), keyDigest: try MemberRecoveryShares.digest(key))
        let service = CompletedRecoveryService(request: request), flow = MemberRecoveryFlow(environment: environment, service: service, privateNode: replacement, passkeys: NoRecoveryPasskeys(), vault: materials, noticeChannel: nil)
        flow.setSession(session); await flow.finish(request)
        let state = await replacement.state; XCTAssertEqual(state, .ready); XCTAssertEqual(replacementKeys.count, 1); XCTAssertNil(try materials.requesterKey(scope: scope, create: false)); XCTAssertTrue(flow.notice.contains("completed"))
    }
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}
