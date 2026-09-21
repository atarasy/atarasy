import Foundation
import CryptoKit

public struct MemberRecoveryKeyStatus: Codable, Equatable, Sendable {
    public let profile: String; public let household: String; public let publicKey: String?; public let updatedAt: Int64?
}
public struct MemberRecoveryParticipantKey: Codable, Equatable, Sendable {
    public let profile: String; public let household: String; public let publicKey: String; public let keyDigest: String; public let updatedAt: Int64
}
public struct MemberRecoveryConfigurationDraft: Codable, Equatable, Sendable {
    public let epoch: Int64; public let recoverer: String; public let keyDigest: String; public let hostShare: String; public let recovererPacket: String; public let noticeChannel: String
    public init(epoch: Int64, recoverer: String, keyDigest: String, hostShare: String, recovererPacket: String, noticeChannel: String) { self.epoch = epoch; self.recoverer = recoverer; self.keyDigest = keyDigest; self.hostShare = hostShare; self.recovererPacket = recovererPacket; self.noticeChannel = noticeChannel }
}
public struct MemberRecoveryConfiguration: Codable, Equatable, Sendable {
    public let profile: String; public let owner: String; public let configured: Bool; public let recoverer: String?; public let recovererKeyDigest: String?; public let keyDigest: String?; public let epoch: Int64?; public let createdAt: Int64?; public let updatedAt: Int64?
}
public struct MemberRecoveryRequest: Codable, Equatable, Identifiable, Sendable {
    public let profile: String; public let id: String; public let owner: String; public let recoverer: String; public let epoch: Int64; public let requesterPublicKey: String; public let state: String; public let createdAt: Int64; public let updatedAt: Int64
    public let recovererPacket: String?; public let release: String?; public let hostShare: String?; public let keyDigest: String?
}
public struct MemberRecoveryLogEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let owner: String; public let recovery: String; public let recoverer: String; public let state: String; public let occurredAt: Int64; public let deliveredAt: Int64?; public let receipt: String?
}
public struct MemberRecoveryLog: Codable, Equatable, Sendable { public let profile: String; public let owner: String; public let events: [MemberRecoveryLogEvent] }

public struct PreparedMemberRecoveryKey: Sendable { public let publicKey: String; public let ceremony: MemberCeremony; let sessionID: String; let credentialID: String }
public struct PreparedMemberRecoveryConfiguration: Sendable { public let draft: MemberRecoveryConfigurationDraft; public let recovererKeyDigest: String; public let ceremony: MemberCeremony; let sessionID: String; let credentialID: String }
public struct PreparedMemberRecoveryApproval: Sendable { public let request: MemberRecoveryRequest; public let release: String; public let ceremony: MemberCeremony; let sessionID: String; let credentialID: String }

private enum RecoveryWire {
    static let requestKeys: Set<String> = ["profile", "id", "owner", "recoverer", "epoch", "requesterPublicKey", "state", "createdAt", "updatedAt", "recovererPacket", "release", "hostShare", "keyDigest"]
    static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys else { throw MemberFailure.malformed }
        return object
    }
    static func b64(_ value: String, count: ClosedRange<Int>) -> Bool { guard let data = try? PasskeyBytes.decode(value, maximum: count.upperBound) else { return false }; return count.contains(data.count) }
    static func key(_ value: String) -> Bool { guard let data = try? PasskeyBytes.decode(value, maximum: 65) else { return false }; return data.count == 65 && data.first == 4 }
    static func keyDigest(_ value: String) -> String { PasskeyBytes.encode(Data(SHA256.hash(data: MemberRecoveryCodec.canonical(["atarasy.member-recovery-key.1", value])))) }
    static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func ceremony(_ object: [String: Any], environment: MemberEnvironment, now: Int64) throws -> (MemberCeremony, String) {
        guard let id = object["id"] as? String, let expires = object["expiresAt"] as? NSNumber, expires.int64Value > now, Double(expires.int64Value) == expires.doubleValue,
              let publicKey = object["publicKey"] as? [String: Any], Set(publicKey.keys) == ["challenge", "rpId", "timeout", "userVerification", "allowCredentials"] else { throw MemberFailure.malformed }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "expiresAt": expires, "publicKey": publicKey]), ceremony = try JSONDecoder().decode(MemberCeremony.self, from: data)
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .recovery, now: now)
        guard options.allowedCredentialIDs.count == 1 else { throw MemberFailure.malformed }
        return (ceremony, PasskeyBytes.encode(options.allowedCredentialIDs[0]))
    }
    static func validate(_ value: MemberRecoveryConfiguration, household: String) throws {
        guard value.profile == "atarasy.member-recovery-configuration.1", value.owner == household else { throw MemberFailure.scopeMismatch }
        if value.configured {
            guard let recoverer = value.recoverer, !recoverer.isEmpty, recoverer != household, let recovererKeyDigest = value.recovererKeyDigest, b64(recovererKeyDigest, count: 32...32), let keyDigest = value.keyDigest, b64(keyDigest, count: 32...32), let epoch = value.epoch, epoch > 0, let created = value.createdAt, let updated = value.updatedAt, created >= 0, updated >= created else { throw MemberFailure.malformed }
        } else if value.recoverer != nil || value.recovererKeyDigest != nil || value.keyDigest != nil || value.epoch != nil || value.createdAt != nil || value.updatedAt != nil { throw MemberFailure.malformed }
    }
    static func validate(_ value: MemberRecoveryRequest, household: String) throws {
        guard value.profile == "atarasy.member-recovery-request.1", uuid(value.id), value.epoch > 0, key(value.requesterPublicKey), ["pending", "approved", "completed", "cancelled"].contains(value.state), value.createdAt >= 0, value.updatedAt >= value.createdAt, value.owner == household || value.recoverer == household else { throw MemberFailure.scopeMismatch }
        if household == value.owner {
            guard value.recovererPacket == nil else { throw MemberFailure.scopeMismatch }
            if value.state == "completed" { guard let release = value.release, b64(release, count: 96...2048), let host = value.hostShare, b64(host, count: 64...64), let digest = value.keyDigest, b64(digest, count: 32...32) else { throw MemberFailure.malformed } }
            else if value.release != nil || value.hostShare != nil || value.keyDigest != nil { throw MemberFailure.scopeMismatch }
        } else {
            guard value.hostShare == nil, value.keyDigest == nil, let packet = value.recovererPacket, b64(packet, count: 96...2048) else { throw MemberFailure.scopeMismatch }
            if let release = value.release, !b64(release, count: 96...2048) { throw MemberFailure.malformed }
        }
    }
    static func request(_ data: Data, household: String) throws -> MemberRecoveryRequest {
        _ = try object(data, keys: requestKeys)
        let value: MemberRecoveryRequest
        do { value = try JSONDecoder().decode(MemberRecoveryRequest.self, from: data) } catch { throw MemberFailure.malformed }
        try validate(value, household: household)
        return value
    }
    static func validateAssertion(_ assertion: MemberPasskeyResponse, ceremony: MemberCeremony, credential: String, environment: MemberEnvironment) throws {
        guard assertion.id == credential, case .string(let encoded) = assertion.response["clientDataJSON"], let expected = ceremony.publicKey["challenge"] else { throw MemberFailure.scopeMismatch }
        let bytes = try PasskeyBytes.decode(encoded, maximum: 8192)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["type"] as? String == "webauthn.get", object["origin"] as? String == environment.origin.absoluteString, case .string(let challenge) = expected, object["challenge"] as? String == challenge else { throw MemberFailure.scopeMismatch }
    }
}

public extension MemberClient {
    func recoveryKeyStatus() async throws -> MemberRecoveryKeyStatus {
        let (reply, info) = try await read("/member/recovery/key"); _ = try RecoveryWire.object(reply.data, keys: ["profile", "household", "publicKey", "updatedAt"])
        let value = try decode(MemberRecoveryKeyStatus.self, reply); guard value.profile == "atarasy.member-recovery-key.1", value.household == info.household, (value.publicKey == nil) == (value.updatedAt == nil), value.publicKey.map(RecoveryWire.key) ?? true, value.updatedAt.map({ $0 >= 0 }) ?? true else { throw MemberFailure.scopeMismatch }; return value
    }
    func prepareRecoveryKey(_ key: String) async throws -> PreparedMemberRecoveryKey {
        guard RecoveryWire.key(key) else { throw MemberFailure.invalidInput }
        let (reply, info) = try await read("/member/recovery/key/prepare", body: try JSONSerialization.data(withJSONObject: ["publicKey": key]))
        let object = try RecoveryWire.object(reply.data, keys: ["profile", "household", "recoveryPublicKey", "id", "expiresAt", "publicKey"])
        guard object["profile"] as? String == "atarasy.member-recovery-key-registration.1", object["household"] as? String == info.household, object["recoveryPublicKey"] as? String == key else { throw MemberFailure.scopeMismatch }
        let (ceremony, credential) = try RecoveryWire.ceremony(object, environment: environment, now: now()); return .init(publicKey: key, ceremony: ceremony, sessionID: info.id, credentialID: credential)
    }
    func registerRecoveryKey(_ prepared: PreparedMemberRecoveryKey, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryKeyStatus {
        _ = try requireActiveSession(prepared.sessionID)
        try RecoveryWire.validateAssertion(assertion, ceremony: prepared.ceremony, credential: prepared.credentialID, environment: environment)
        struct Input: Encodable { let preparation: String; let publicKey: String; let assertion: MemberPasskeyResponse }
        let (reply, info) = try await read("/member/recovery/key/register", body: JSONEncoder().encode(Input(preparation: prepared.ceremony.id, publicKey: prepared.publicKey, assertion: assertion)))
        let value = try decode(MemberRecoveryKeyStatus.self, reply, keys: ["profile", "household", "publicKey", "updatedAt"]); guard value.profile == "atarasy.member-recovery-key.1", value.household == info.household, value.publicKey == prepared.publicKey, RecoveryWire.key(prepared.publicKey), let updated = value.updatedAt, updated >= 0 else { throw MemberFailure.scopeMismatch }; return value
    }
    func recoveryParticipant(_ household: String) async throws -> MemberRecoveryParticipantKey {
        let (reply, _) = try await read("/member/recovery/participant", body: try JSONSerialization.data(withJSONObject: ["household": household]))
        let value = try decode(MemberRecoveryParticipantKey.self, reply, keys: ["profile", "household", "publicKey", "keyDigest", "updatedAt"])
        guard value.profile == "atarasy.member-recovery-participant.1", value.household == household, RecoveryWire.key(value.publicKey), value.keyDigest == RecoveryWire.keyDigest(value.publicKey), value.updatedAt >= 0 else { throw MemberFailure.scopeMismatch }; return value
    }
    func recoveryConfiguration() async throws -> MemberRecoveryConfiguration {
        let (reply, info) = try await read("/member/recovery/configuration"); let value = try decode(MemberRecoveryConfiguration.self, reply, keys: ["profile", "owner", "configured", "recoverer", "recovererKeyDigest", "keyDigest", "epoch", "createdAt", "updatedAt"]); try RecoveryWire.validate(value, household: info.household); return value
    }
    func prepareRecoveryConfiguration(_ draft: MemberRecoveryConfigurationDraft, recovererKeyDigest expectedRecovererKeyDigest: String) async throws -> PreparedMemberRecoveryConfiguration {
        guard RecoveryWire.b64(expectedRecovererKeyDigest, count: 32...32) else { throw MemberFailure.invalidInput }
        let (reply, info) = try await read("/member/recovery/configuration/prepare", body: JSONEncoder().encode(draft)); let object = try RecoveryWire.object(reply.data, keys: ["profile", "configuration", "id", "expiresAt", "publicKey"])
        guard object["profile"] as? String == "atarasy.member-recovery-configuration-review.1", let fixed = object["configuration"] as? [String: Any], Set(fixed.keys) == ["owner", "recoverer", "recovererKeyDigest", "keyDigest", "hostShare", "recovererPacket", "noticeChannel", "epoch"], fixed["owner"] as? String == info.household, fixed["recoverer"] as? String == draft.recoverer, fixed["recovererKeyDigest"] as? String == expectedRecovererKeyDigest, fixed["keyDigest"] as? String == draft.keyDigest, fixed["hostShare"] as? String == draft.hostShare, fixed["recovererPacket"] as? String == draft.recovererPacket, fixed["noticeChannel"] as? String == draft.noticeChannel, (fixed["epoch"] as? NSNumber)?.int64Value == draft.epoch else { throw MemberFailure.scopeMismatch }
        let (ceremony, credential) = try RecoveryWire.ceremony(object, environment: environment, now: now()); return .init(draft: draft, recovererKeyDigest: expectedRecovererKeyDigest, ceremony: ceremony, sessionID: info.id, credentialID: credential)
    }
    func submitRecoveryConfiguration(_ prepared: PreparedMemberRecoveryConfiguration, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryConfiguration {
        _ = try requireActiveSession(prepared.sessionID)
        try RecoveryWire.validateAssertion(assertion, ceremony: prepared.ceremony, credential: prepared.credentialID, environment: environment)
        struct Input: Encodable { let preparation: String; let configuration: MemberRecoveryConfigurationDraft; let assertion: MemberPasskeyResponse }
        let (reply, info) = try await read("/member/recovery/configuration/submit", body: JSONEncoder().encode(Input(preparation: prepared.ceremony.id, configuration: prepared.draft, assertion: assertion)))
        let value = try decode(MemberRecoveryConfiguration.self, reply, keys: ["profile", "owner", "configured", "recoverer", "recovererKeyDigest", "keyDigest", "epoch", "createdAt", "updatedAt"]); try RecoveryWire.validate(value, household: info.household); guard value.epoch == prepared.draft.epoch, value.recoverer == prepared.draft.recoverer, value.recovererKeyDigest == prepared.recovererKeyDigest, value.keyDigest == prepared.draft.keyDigest else { throw MemberFailure.scopeMismatch }; return value
    }
    func createRecoveryRequest(requesterPublicKey: String) async throws -> MemberRecoveryRequest {
        guard RecoveryWire.key(requesterPublicKey) else { throw MemberFailure.invalidInput }
        let (reply, info) = try await read("/member/recovery/requests", body: try JSONSerialization.data(withJSONObject: ["requesterPublicKey": requesterPublicKey])); guard reply.status == 201 else { throw MemberFailure.http(reply.status) }
        let value = try decode(MemberRecoveryRequest.self, reply, status: 201, keys: RecoveryWire.requestKeys); try RecoveryWire.validate(value, household: info.household); guard value.owner == info.household, value.requesterPublicKey == requesterPublicKey else { throw MemberFailure.scopeMismatch }; return value
    }
    func recoveryRequests() async throws -> [MemberRecoveryRequest] {
        let (reply, info) = try await read("/member/recovery/requests"); let object = try RecoveryWire.object(reply.data, keys: ["profile", "checkedAt", "requests"]); guard object["profile"] as? String == "atarasy.member-recovery-request-list.1" else { throw MemberFailure.malformed }
        struct List: Decodable { let profile: String; let checkedAt: Int64; let requests: [MemberRecoveryRequest] }; let list = try decode(List.self, reply)
        guard list.checkedAt >= 0, list.requests.count <= 100, Set(list.requests.map(\.id)).count == list.requests.count, list.requests.map(\.id) == list.requests.map(\.id).sorted() else { throw MemberFailure.malformed }
        for value in list.requests { try RecoveryWire.validate(value, household: info.household) }; return list.requests
    }
    func recoveryRequest(id: String) async throws -> MemberRecoveryRequest {
        guard RecoveryWire.uuid(id) else { throw MemberFailure.invalidInput }; let (reply, info) = try await read("/member/recovery/requests/" + id); let value = try decode(MemberRecoveryRequest.self, reply, keys: RecoveryWire.requestKeys); try RecoveryWire.validate(value, household: info.household); guard value.id == id else { throw MemberFailure.scopeMismatch }; return value
    }
    func prepareRecoveryApproval(id: String, release: String) async throws -> PreparedMemberRecoveryApproval {
        guard RecoveryWire.uuid(id), RecoveryWire.b64(release, count: 96...2048) else { throw MemberFailure.invalidInput }
        let body = try JSONSerialization.data(withJSONObject: ["release": release]), (reply, info) = try await read("/member/recovery/requests/" + id + "/prepare", body: body), object = try RecoveryWire.object(reply.data, keys: ["profile", "request", "release", "id", "expiresAt", "publicKey"])
        guard object["profile"] as? String == "atarasy.member-recovery-approval-review.1", object["release"] as? String == release, let requestObject = object["request"] as? [String: Any], Set(requestObject.keys) == RecoveryWire.requestKeys else { throw MemberFailure.scopeMismatch }
        let request = try RecoveryWire.request(JSONSerialization.data(withJSONObject: requestObject), household: info.household); guard request.id == id, request.recoverer == info.household else { throw MemberFailure.scopeMismatch }
        let (ceremony, credential) = try RecoveryWire.ceremony(object, environment: environment, now: now()); return .init(request: request, release: release, ceremony: ceremony, sessionID: info.id, credentialID: credential)
    }
    func approveRecovery(_ prepared: PreparedMemberRecoveryApproval, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryRequest {
        _ = try requireActiveSession(prepared.sessionID)
        try RecoveryWire.validateAssertion(assertion, ceremony: prepared.ceremony, credential: prepared.credentialID, environment: environment)
        struct Input: Encodable { let preparation: String; let release: String; let assertion: MemberPasskeyResponse }
        let (reply, info) = try await read("/member/recovery/requests/" + prepared.request.id + "/approve", body: JSONEncoder().encode(Input(preparation: prepared.ceremony.id, release: prepared.release, assertion: assertion)))
        let value = try decode(MemberRecoveryRequest.self, reply, keys: RecoveryWire.requestKeys); try RecoveryWire.validate(value, household: info.household); guard value.id == prepared.request.id, value.state == "approved" || value.state == "completed" else { throw MemberFailure.scopeMismatch }; return value
    }
    func recoveryLog() async throws -> MemberRecoveryLog {
        let (reply, info) = try await read("/member/recovery/log"); let value = try decode(MemberRecoveryLog.self, reply, keys: ["profile", "owner", "events"])
        guard value.profile == "atarasy.member-recovery-log.1", value.owner == info.household, value.events.count <= 1000, Set(value.events.map(\.id)).count == value.events.count else { throw MemberFailure.scopeMismatch }
        for event in value.events { guard RecoveryWire.uuid(event.id), RecoveryWire.uuid(event.recovery), event.owner == info.household, ["notice_pending", "completed"].contains(event.state), event.occurredAt >= 0, (event.state == "completed") == (event.deliveredAt != nil && event.receipt != nil) else { throw MemberFailure.malformed } }
        return value
    }
}
