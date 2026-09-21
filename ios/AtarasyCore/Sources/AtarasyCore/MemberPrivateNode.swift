import Foundation
import CryptoKit

public struct MemberPrivateNodeEnvelope: Codable, Equatable, Sendable {
    public let profile: String
    public let nonce: String
    public let ciphertext: String
    public init(profile: String = "atarasy.private-node-record.1", nonce: String, ciphertext: String) { self.profile = profile; self.nonce = nonce; self.ciphertext = ciphertext }
}
public struct MemberPrivateNodeRecord: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int64
    public let updatedAt: Int64
    public let envelope: MemberPrivateNodeEnvelope
}
public struct MemberPrivateNodeIndex: Codable, Equatable, Sendable {
    public let profile: String
    public let checkedAt: Int64
    public let records: [MemberPrivateNodeRecord]
}

public protocol MemberPrivateNodeService: Sendable {
    func privateNodeRecords() async throws -> MemberPrivateNodeIndex
    func privateNodeRecord(id: String) async throws -> MemberPrivateNodeRecord
    func writePrivateNodeRecord(id: String, expectedRevision: Int64, envelope: MemberPrivateNodeEnvelope) async throws -> MemberPrivateNodeRecord
}
extension MemberClient: MemberPrivateNodeService {}

private func validatePrivateEnvelopeObject(_ value: Any) -> Bool {
    guard let object = value as? [String: Any], Set(object.keys) == ["profile", "nonce", "ciphertext"], object["profile"] as? String == "atarasy.private-node-record.1",
          let nonce = object["nonce"] as? String, let ciphertext = object["ciphertext"] as? String,
          (try? PrivateNodeCodec.data(nonce).count) == 12, let bytes = try? PrivateNodeCodec.data(ciphertext), bytes.count > 16, bytes.count <= 12_304 else { return false }
    return true
}
private func validatePrivateRecordObject(_ value: Any) -> Bool {
    guard let object = value as? [String: Any], Set(object.keys) == ["id", "revision", "updatedAt", "envelope"], let id = object["id"] as? String,
          UUID(uuidString: id)?.uuidString.lowercased() == id, let revision = object["revision"] as? NSNumber, let updated = object["updatedAt"] as? NSNumber,
          CFGetTypeID(revision) != CFBooleanGetTypeID(), CFGetTypeID(updated) != CFBooleanGetTypeID(), revision.int64Value > 0, updated.int64Value >= 0,
          Double(revision.int64Value) == revision.doubleValue, Double(updated.int64Value) == updated.doubleValue, validatePrivateEnvelopeObject(object["envelope"] as Any) else { return false }
    return true
}

public extension MemberClient {
    func privateNodeRecords() async throws -> MemberPrivateNodeIndex {
        let (reply, _) = try await read("/member/private-node/records")
        guard let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any], Set(object.keys) == ["profile", "checkedAt", "records"], object["profile"] as? String == "atarasy.private-node-index.1",
              let rows = object["records"] as? [Any], rows.count <= 10_000, rows.allSatisfy(validatePrivateRecordObject),
              let checked = object["checkedAt"] as? NSNumber, CFGetTypeID(checked) != CFBooleanGetTypeID(), checked.int64Value >= 0, Double(checked.int64Value) == checked.doubleValue else { throw MemberFailure.malformed }
        let value = try decode(MemberPrivateNodeIndex.self, reply)
        guard Set(value.records.map(\.id)).count == value.records.count, value.records.map(\.id) == value.records.map(\.id).sorted() else { throw MemberFailure.malformed }
        return value
    }
    func privateNodeRecord(id: String) async throws -> MemberPrivateNodeRecord {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw MemberFailure.invalidInput }
        let (reply, _) = try await read("/member/private-node/records/" + id)
        guard let object = try? JSONSerialization.jsonObject(with: reply.data), validatePrivateRecordObject(object) else { throw MemberFailure.malformed }
        let value = try decode(MemberPrivateNodeRecord.self, reply); guard value.id == id else { throw MemberFailure.scopeMismatch }; return value
    }
    func writePrivateNodeRecord(id: String, expectedRevision: Int64, envelope: MemberPrivateNodeEnvelope) async throws -> MemberPrivateNodeRecord {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id, expectedRevision >= 0, expectedRevision < 9_007_199_254_740_991,
              let envelopeObject = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)), validatePrivateEnvelopeObject(envelopeObject) else { throw MemberFailure.invalidInput }
        struct Request: Encodable { let expectedRevision: Int64; let envelope: MemberPrivateNodeEnvelope }
        let (reply, _) = try await read("/member/private-node/records/" + id, body: JSONEncoder().encode(Request(expectedRevision: expectedRevision, envelope: envelope)))
        guard let object = try? JSONSerialization.jsonObject(with: reply.data), validatePrivateRecordObject(object) else { throw MemberFailure.malformed }
        let value = try decode(MemberPrivateNodeRecord.self, reply)
        guard value.id == id, value.revision == expectedRevision + 1, value.envelope == envelope else { throw MemberFailure.scopeMismatch }
        return value
    }
}

private enum PrivateNodeCodec {
    private static func canonicalArray(_ values: [String]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try! encoder.encode(values)
    }
    static func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func data(_ value: String) throws -> Data {
        guard value.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil, value.count % 4 != 1 else { throw MemberFailure.malformed }
        var fixed = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        fixed += String(repeating: "=", count: (4 - fixed.count % 4) % 4)
        guard let result = Data(base64Encoded: fixed), b64(result) == value else { throw MemberFailure.malformed }
        return result
    }
    static func scope(environment: MemberEnvironment, household: String) -> String {
        SHA256.hash(data: canonicalArray(["atarasy.private-node-scope.1", environment.name, environment.origin.absoluteString, household])).map { String(format: "%02x", $0) }.joined()
    }
    static func aad(environment: MemberEnvironment, household: String, id: String, revision: Int64) -> Data {
        canonicalArray(["atarasy.private-node-record.1", environment.name, environment.origin.absoluteString, household, id, String(revision)])
    }
}

public struct MemberPrivateNodeCrypto: Sendable {
    private let key: SymmetricKey
    public init(key: Data) throws { guard key.count == 32 else { throw MemberFailure.storage }; self.key = SymmetricKey(data: key) }
    public func seal(_ clear: Data, environment: MemberEnvironment, household: String, id: String, revision: Int64) throws -> MemberPrivateNodeEnvelope {
        guard !clear.isEmpty, clear.count <= 12_288, UUID(uuidString: id)?.uuidString.lowercased() == id, revision > 0 else { throw MemberFailure.invalidInput }
        let sealed = try AES.GCM.seal(clear, using: key, authenticating: PrivateNodeCodec.aad(environment: environment, household: household, id: id, revision: revision))
        return .init(nonce: PrivateNodeCodec.b64(Data(sealed.nonce)), ciphertext: PrivateNodeCodec.b64(sealed.ciphertext + sealed.tag))
    }
    public func open(_ record: MemberPrivateNodeRecord, environment: MemberEnvironment, household: String) throws -> Data {
        guard record.envelope.profile == "atarasy.private-node-record.1", UUID(uuidString: record.id)?.uuidString.lowercased() == record.id, record.revision > 0 else { throw MemberFailure.malformed }
        let nonceData = try PrivateNodeCodec.data(record.envelope.nonce), sealed = try PrivateNodeCodec.data(record.envelope.ciphertext)
        guard nonceData.count == 12, sealed.count > 16, sealed.count <= 12_304 else { throw MemberFailure.malformed }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: PrivateNodeCodec.aad(environment: environment, household: household, id: record.id, revision: record.revision))
    }
}

public enum MemberPrivateNodeState: Equatable, Sendable { case locked, ready, recoveryRequired }

/// Owns decrypted node access for one foreground account. A missing local key is created only for
/// an empty node. If ciphertext already exists, a reinstall or new device must enter recovery.
public actor MemberPrivateNode {
    private static let bootstrapID = "00000000-0000-4000-8000-000000000019"
    private static let bootstrap = Data("{\"profile\":\"atarasy.private-node-bootstrap.1\"}".utf8)
    private let environment: MemberEnvironment
    private let service: any MemberPrivateNodeService
    private let vault: any MemberOperationKeyVault
    private var session: MemberSessionInfo?
    private var crypto: MemberPrivateNodeCrypto?
    public private(set) var state: MemberPrivateNodeState = .locked
    public init(environment: MemberEnvironment, service: any MemberPrivateNodeService, vault: any MemberOperationKeyVault) { self.environment = environment; self.service = service; self.vault = vault }
    private func verify(_ records: [MemberPrivateNodeRecord], codec: MemberPrivateNodeCrypto, household: String) throws {
        for record in records {
            let clear = try codec.open(record, environment: environment, household: household)
            if record.id == Self.bootstrapID, clear != Self.bootstrap { throw MemberFailure.scopeMismatch }
        }
    }
    public func open(session: MemberSessionInfo) async throws -> MemberPrivateNodeState {
        lock(); let index = try await service.privateNodeRecords(), reference = PrivateNodeCodec.scope(environment: environment, household: session.household)
        var key = try vault.key(scope: reference, create: false)
        if key == nil {
            guard index.records.isEmpty else { state = .recoveryRequired; return state }
            key = try vault.key(scope: reference, create: true)
        }
        guard let key else { throw MemberFailure.storage }
        let codec = try MemberPrivateNodeCrypto(key: key)
        if index.records.isEmpty {
            let envelope = try codec.seal(Self.bootstrap, environment: environment, household: session.household, id: Self.bootstrapID, revision: 1)
            let record = try await service.writePrivateNodeRecord(id: Self.bootstrapID, expectedRevision: 0, envelope: envelope)
            guard try codec.open(record, environment: environment, household: session.household) == Self.bootstrap else { throw MemberFailure.scopeMismatch }
        } else {
            try verify(index.records, codec: codec, household: session.household)
        }
        self.session = session; crypto = codec; state = .ready; return state
    }
    public func write(id: String = UUID().uuidString.lowercased(), expectedRevision: Int64, clear: Data) async throws -> MemberPrivateNodeRecord {
        guard state == .ready, let session, let crypto else { throw MemberFailure.storage }
        let envelope = try crypto.seal(clear, environment: environment, household: session.household, id: id, revision: expectedRevision + 1)
        let record = try await service.writePrivateNodeRecord(id: id, expectedRevision: expectedRevision, envelope: envelope)
        guard try crypto.open(record, environment: environment, household: session.household) == clear else { throw MemberFailure.scopeMismatch }
        return record
    }
    public func read(id: String) async throws -> Data {
        guard state == .ready, let session, let crypto else { throw MemberFailure.storage }
        return try crypto.open(await service.privateNodeRecord(id: id), environment: environment, household: session.household)
    }
    public func recoveryKey(session: MemberSessionInfo) throws -> Data {
        guard state == .ready, self.session?.id == session.id, self.session?.household == session.household,
              let key = try vault.key(scope: PrivateNodeCodec.scope(environment: environment, household: session.household), create: false) else { throw MemberFailure.storage }
        return key
    }
    public func installRecoveredKey(_ key: Data, session: MemberSessionInfo) async throws {
        guard state == .recoveryRequired, key.count == 32 else { throw MemberFailure.storage }
        let index = try await service.privateNodeRecords(); guard !index.records.isEmpty else { throw MemberFailure.storage }
        let codec = try MemberPrivateNodeCrypto(key: key); try verify(index.records, codec: codec, household: session.household)
        try vault.install(key: key, scope: PrivateNodeCodec.scope(environment: environment, household: session.household))
        self.session = session; crypto = codec; state = .ready
    }
    public func lock() { session = nil; crypto = nil; state = .locked }
}
