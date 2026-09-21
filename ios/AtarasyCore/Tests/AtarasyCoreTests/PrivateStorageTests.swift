import XCTest
@testable import AtarasyCore

private final class MemoryOperationKeys: MemberOperationKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func key(scope: String, create: Bool) throws -> Data? { lock.withLock { if let value = values[scope] { return value }; guard create else { return nil }; let value = Data(repeating: UInt8(values.count + 1), count: 32); values[scope] = value; return value } }
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
        let hosted = try await service.encodedRecord(id); XCTAssertFalse(hosted.contains("private purchase")); XCTAssertFalse(hosted.contains(session.household))
        await node.lock(); let locked = await node.state; XCTAssertEqual(locked, .locked); await XCTAssertThrowsErrorAsync { _ = try await node.read(id: id) }
        let reinstalled = MemberPrivateNode(environment: env, service: service, vault: MemoryOperationKeys())
        let reopened = try await reinstalled.open(session: session); XCTAssertEqual(reopened, .recoveryRequired)
        await XCTAssertThrowsErrorAsync { _ = try await reinstalled.read(id: id) }
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
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}
