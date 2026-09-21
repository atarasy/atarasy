import Foundation
import CryptoKit
import Security

public enum MemberRecoveryParticipant: String, Codable, Sendable { case device, recoverer, host }

public struct MemberRecoveryShare: Equatable, Sendable {
    public let participant: MemberRecoveryParticipant
    public let bytes: Data
    public init(participant: MemberRecoveryParticipant, bytes: Data) throws {
        guard bytes.count == 64 else { throw MemberFailure.malformed }
        self.participant = participant; self.bytes = bytes
    }
}

/// Information-theoretic replicated sharing for a 32-byte ledger key. Random A and B and
/// C = key xor A xor B are placed as device(A,B), recoverer(B,C), host(C,A). One share lacks
/// one uniformly random component; every distinct pair reconstructs the key.
public enum MemberRecoveryShares {
    private static func random(_ count: Int) throws -> Data {
        var value = Data(count: count)
        let status = value.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MemberFailure.storage }
        return value
    }
    private static func xor(_ values: Data...) -> Data {
        Data((0..<values[0].count).map { index in values.reduce(UInt8(0)) { $0 ^ $1[index] } })
    }
    public static func split(key: Data) throws -> [MemberRecoveryShare] {
        guard key.count == 32 else { throw MemberFailure.invalidInput }
        let a = try random(32), b = try random(32), c = xor(key, a, b)
        return [try .init(participant: .device, bytes: a + b), try .init(participant: .recoverer, bytes: b + c), try .init(participant: .host, bytes: c + a)]
    }
    private static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public static func recover(_ first: MemberRecoveryShare, _ second: MemberRecoveryShare) throws -> Data {
        guard first.participant != second.participant else { throw MemberFailure.invalidInput }
        let shares = Dictionary(uniqueKeysWithValues: [first, second].map { ($0.participant, ($0.bytes.prefix(32), $0.bytes.suffix(32))) })
        let a: Data, b: Data, c: Data
        switch (first.participant, second.participant) {
        case (.device, .recoverer), (.recoverer, .device):
            let device = shares[.device]!, recoverer = shares[.recoverer]!
            guard same(Data(device.1), Data(recoverer.0)) else { throw MemberFailure.storage }
            a = Data(device.0); b = Data(device.1); c = Data(recoverer.1)
        case (.device, .host), (.host, .device):
            let device = shares[.device]!, host = shares[.host]!
            guard same(Data(device.0), Data(host.1)) else { throw MemberFailure.storage }
            a = Data(device.0); b = Data(device.1); c = Data(host.0)
        case (.recoverer, .host), (.host, .recoverer):
            let recoverer = shares[.recoverer]!, host = shares[.host]!
            guard same(Data(recoverer.1), Data(host.0)) else { throw MemberFailure.storage }
            a = Data(host.1); b = Data(recoverer.0); c = Data(recoverer.1)
        default: throw MemberFailure.invalidInput
        }
        return xor(a, b, c)
    }
    public static func digest(_ key: Data) throws -> String {
        guard key.count == 32 else { throw MemberFailure.invalidInput }
        return MemberRecoveryCodec.b64(Data(SHA256.hash(data: key)))
    }
}

public struct MemberRecoveryKeyPair: Sendable {
    private let key: P256.KeyAgreement.PrivateKey
    public init() { key = P256.KeyAgreement.PrivateKey() }
    public init(rawRepresentation: Data) throws { key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation) }
    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKey: String { MemberRecoveryCodec.b64(key.publicKey.x963Representation) }
    fileprivate var privateKey: P256.KeyAgreement.PrivateKey { key }
}

public struct MemberRecoveryPacketContext: Sendable {
    public let purpose: String
    public let owner: String
    public let recoverer: String
    public let reference: String
    public let epoch: Int64
    public init(purpose: String, owner: String, recoverer: String, reference: String, epoch: Int64) {
        self.purpose = purpose; self.owner = owner; self.recoverer = recoverer; self.reference = reference; self.epoch = epoch
    }
}

private struct MemberRecoveryPacket: Codable {
    let profile: String
    let ephemeralPublicKey: String
    let salt: String
    let nonce: String
    let ciphertext: String
}

enum MemberRecoveryCodec {
    static func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func data(_ value: String) throws -> Data {
        guard value.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil, value.count % 4 != 1 else { throw MemberFailure.malformed }
        var fixed = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        fixed += String(repeating: "=", count: (4 - fixed.count % 4) % 4)
        guard let data = Data(base64Encoded: fixed), b64(data) == value else { throw MemberFailure.malformed }
        return data
    }
    static func canonical(_ values: [String]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try! encoder.encode(values)
    }
}

public enum MemberRecoveryPackets {
    private static func aad(_ context: MemberRecoveryPacketContext) throws -> Data {
        guard [context.purpose, context.owner, context.recoverer, context.reference].allSatisfy({ !$0.isEmpty }), context.epoch > 0 else { throw MemberFailure.invalidInput }
        return MemberRecoveryCodec.canonical(["atarasy.member-recovery-packet.1", context.purpose, context.owner, context.recoverer, context.reference, String(context.epoch)])
    }
    public static func seal(_ clear: Data, recipientPublicKey: String, context: MemberRecoveryPacketContext) throws -> String {
        guard !clear.isEmpty, clear.count <= 1024 else { throw MemberFailure.invalidInput }
        let recipientData = try MemberRecoveryCodec.data(recipientPublicKey), recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientData), ephemeral = P256.KeyAgreement.PrivateKey(), salt = try MemberRecoverySharesRandom.bytes(32)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient), key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: try aad(context), outputByteCount: 32)
        let box = try AES.GCM.seal(clear, using: key, authenticating: try aad(context))
        let packet = MemberRecoveryPacket(profile: "atarasy.member-recovery-packet.1", ephemeralPublicKey: MemberRecoveryCodec.b64(ephemeral.publicKey.x963Representation), salt: MemberRecoveryCodec.b64(salt), nonce: MemberRecoveryCodec.b64(Data(box.nonce)), ciphertext: MemberRecoveryCodec.b64(box.ciphertext + box.tag))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MemberRecoveryCodec.b64(try encoder.encode(packet))
    }
    public static func open(_ encoded: String, recipient: MemberRecoveryKeyPair, context: MemberRecoveryPacketContext) throws -> Data {
        let encodedData = try MemberRecoveryCodec.data(encoded)
        guard encodedData.count >= 96, encodedData.count <= 2048,
              let object = try? JSONSerialization.jsonObject(with: encodedData) as? [String: Any], Set(object.keys) == ["profile", "ephemeralPublicKey", "salt", "nonce", "ciphertext"] else { throw MemberFailure.malformed }
        let packet = try JSONDecoder().decode(MemberRecoveryPacket.self, from: encodedData)
        guard packet.profile == "atarasy.member-recovery-packet.1" else { throw MemberFailure.malformed }
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: MemberRecoveryCodec.data(packet.ephemeralPublicKey)), salt = try MemberRecoveryCodec.data(packet.salt), nonce = try MemberRecoveryCodec.data(packet.nonce), sealed = try MemberRecoveryCodec.data(packet.ciphertext)
        guard salt.count == 32, nonce.count == 12, sealed.count > 16, sealed.count <= 1040 else { throw MemberFailure.malformed }
        let shared = try recipient.privateKey.sharedSecretFromKeyAgreement(with: publicKey), key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: try aad(context), outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: .init(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: try aad(context))
    }
}

private enum MemberRecoverySharesRandom {
    static func bytes(_ count: Int) throws -> Data {
        var value = Data(count: count)
        guard value.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }) == errSecSuccess else { throw MemberFailure.storage }
        return value
    }
}

public protocol MemberRecoveryMaterialVault: Sendable {
    func agreementKey(scope: String, create: Bool) throws -> MemberRecoveryKeyPair?
    func requesterKey(scope: String, create: Bool) throws -> MemberRecoveryKeyPair?
    func saveDeviceShare(_ share: MemberRecoveryShare, scope: String, epoch: Int64) throws
    func deviceShare(scope: String, epoch: Int64) throws -> MemberRecoveryShare?
    func removeRequesterKey(scope: String) throws
}

public final class KeychainMemberRecoveryMaterialVault: MemberRecoveryMaterialVault, Sendable {
    private let service: String
    public init(namespace: String, installation: MemberInstallationIdentity) throws {
        guard !namespace.isEmpty else { throw MemberFailure.invalidInput }; service = namespace + ".recovery." + installation.value
    }
    private func account(_ kind: String, scope: String, epoch: Int64? = nil) throws -> String {
        guard scope.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
        return [kind, scope, epoch.map(String.init)].compactMap { $0 }.joined(separator: ".")
    }
    private func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MemberFailure.storage }; return data
    }
    private func write(_ data: Data, account: String) throws {
        if let old = try read(account) { guard old == data else { throw MemberFailure.storage }; return }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false, kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { guard try read(account) == data else { throw MemberFailure.storage }; return }
        guard status == errSecSuccess else { throw MemberFailure.storage }
    }
    private func pair(_ kind: String, scope: String, create: Bool) throws -> MemberRecoveryKeyPair? {
        let name = try account(kind, scope: scope)
        if let data = try read(name) { return try MemberRecoveryKeyPair(rawRepresentation: data) }
        guard create else { return nil }; let pair = MemberRecoveryKeyPair(); try write(pair.rawRepresentation, account: name); return pair
    }
    public func agreementKey(scope: String, create: Bool) throws -> MemberRecoveryKeyPair? { try pair("agreement", scope: scope, create: create) }
    public func requesterKey(scope: String, create: Bool) throws -> MemberRecoveryKeyPair? { try pair("requester", scope: scope, create: create) }
    public func saveDeviceShare(_ share: MemberRecoveryShare, scope: String, epoch: Int64) throws {
        guard share.participant == .device, epoch > 0 else { throw MemberFailure.invalidInput }; try write(share.bytes, account: account("device", scope: scope, epoch: epoch))
    }
    public func deviceShare(scope: String, epoch: Int64) throws -> MemberRecoveryShare? {
        guard epoch > 0 else { throw MemberFailure.invalidInput }; guard let bytes = try read(account("device", scope: scope, epoch: epoch)) else { return nil }; return try .init(participant: .device, bytes: bytes)
    }
    public func removeRequesterKey(scope: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: try account("requester", scope: scope), kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw MemberFailure.storage }
    }
}
