import Foundation
import CryptoKit
import Security

/// Durable correlation only. Contains neither bearer credentials nor assertions: what was
/// signed is kept as a digest, so a read-back can tell this device's settlement from another's.
public struct MemberOperationHandle: Codable, Equatable, Sendable {
    public let id: String
    public let environment: String
    public let origin: URL
    public let sessionID: String
    public let household: String
    public let presenter: String
    public let offer: String
    public let canonical: String
    public let expiresAt: Int64
    public let requestDigest: String
    public let reviewedRevision: String
    public let challenge: String
    public let credentialID: String
    public let attempted: Bool
    /// SHA-256 of the assertion signature this device submitted. Nil before a submission, and
    /// on handles saved by builds that did not record it.
    public private(set) var confirmationFingerprint: String? = nil
    /// The same operation, ignoring the session that prepared it. Re-preparing after signing in
    /// again returns the same operation id, and the new session id alone must not refuse it.
    public private(set) var profile: String? = nil
    public private(set) var digitalTermsDigest: String? = nil
    public private(set) var withdrawalDecisionID: String? = nil
    public private(set) var withdrawalNextIncarnation: Int64? = nil
    public var operationProfile: String { profile ?? "atarasy.member-statement-authorisation.1" }
    func sameOperation(_ other: Self) -> Bool {
        withdrawalDecisionID == other.withdrawalDecisionID && withdrawalNextIncarnation == other.withdrawalNextIncarnation && operationProfile == other.operationProfile && digitalTermsDigest == other.digitalTermsDigest && id == other.id && environment == other.environment && origin == other.origin && household == other.household &&
        presenter == other.presenter && offer == other.offer && canonical == other.canonical && expiresAt == other.expiresAt &&
        requestDigest == other.requestDigest && reviewedRevision == other.reviewedRevision && challenge == other.challenge &&
        credentialID == other.credentialID && attempted == other.attempted && confirmationFingerprint == other.confirmationFingerprint
    }
    func markedAttempted(confirmation: String) -> Self {
        Self(id: id, environment: environment, origin: origin, sessionID: sessionID, household: household, presenter: presenter, offer: offer, canonical: canonical, expiresAt: expiresAt, requestDigest: requestDigest, reviewedRevision: reviewedRevision, challenge: challenge, credentialID: credentialID, attempted: true, confirmationFingerprint: Canonical.digest(confirmation), profile: profile, digitalTermsDigest: digitalTermsDigest, withdrawalDecisionID: withdrawalDecisionID, withdrawalNextIncarnation: withdrawalNextIncarnation)
    }
}
public struct MemberPreparedOperation: Decodable, Sendable {
    public let profile: String
    public let operationID: String
    public let requestDigest: String
    public let reviewedRevision: String
    public let expiresAt: Int64
    public let canonical: String
    public let review: MemberJSON
    public let operationState: String
    public let publicKey: [String: MemberJSON]
    public let authorisation: String
}
public enum MemberOperationOutcome: Equatable, Sendable {
    case committed(ProtocolSettlement)
    /// A settlement stands for this offer, but not by the signature this device submitted.
    case settledElsewhere(ProtocolSettlement)
    /// A settlement stands, and this handle was saved by a build that did not record the signature
    /// it sent, so whether it is this device's approval cannot be said.
    case settledUnverified(ProtocolSettlement)
    case pending(String)
    case unresolved
}
public protocol MemberOperationStore: Sendable {
    /// §14.3. Every operation of a household this device holds goes when the account is deleted.
    func removeAll(household: String) throws
    func save(_ handle: MemberOperationHandle) throws
    func load(id: String) throws -> MemberOperationHandle?
    func handles() throws -> [MemberOperationHandle]
    /// Atomically persists attempted=true with the digest of the signature about to be sent,
    /// or refuses an already attempted operation.
    func claim(_ handle: MemberOperationHandle, confirmation: String) throws
}
public extension MemberOperationStore {
    func handles() throws -> [MemberOperationHandle] { [] }
    func removeAll(household: String) throws {}
}

public protocol MemberOperationKeyVault: Sendable {
    func key(scope: String, create: Bool) throws -> Data?
    func install(key: Data, scope: String) throws
    /// §14.3. Removes a scope's key, so the journal it decrypted cannot be read again.
    func forget(scope: String) throws
}
public extension MemberOperationKeyVault { func forget(scope: String) throws {} }

/// A per-installation identifier kept outside Keychain. Reinstalling creates a new value, so
/// Keychain items that survive app deletion are not silently treated as this installation's keys.
public struct MemberInstallationIdentity: Sendable {
    public let value: String
    public init(file: URL) throws {
        guard file.isFileURL else { throw MemberFailure.storage }
        if FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard UUID(uuidString: text)?.uuidString.lowercased() == text else { throw MemberFailure.storage }
            value = text
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let generated = UUID().uuidString.lowercased()
            try Data(generated.utf8).write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            value = generated
        }
    }
}

public final class KeychainMemberOperationKeyVault: MemberOperationKeyVault, Sendable {
    private let service: String
    public init(namespace: String, installation: MemberInstallationIdentity) throws {
        guard !namespace.isEmpty else { throw MemberFailure.invalidInput }
        service = namespace + ".private-node." + installation.value
    }
    private func query(_ scope: String) throws -> [String: Any] {
        guard scope.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: scope, kSecAttrSynchronizable as String: false]
    }
    public func key(scope: String, create: Bool) throws -> Data? {
        var q = try query(scope); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 32 { return key }
        guard status == errSecItemNotFound else { throw MemberFailure.storage }
        guard create else { return nil }
        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes in SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw MemberFailure.storage }
        try install(key: key, scope: scope)
        return key
    }
    public func forget(scope: String) throws {
        let status = SecItemDelete(try query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MemberFailure.storage }
    }
    public func install(key: Data, scope: String) throws {
        guard key.count == 32 else { throw MemberFailure.invalidInput }
        var read = try query(scope); read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var existing: CFTypeRef?; let found = SecItemCopyMatching(read as CFDictionary, &existing)
        if found == errSecSuccess { guard existing as? Data == key else { throw MemberFailure.storage }; return }
        guard found == errSecItemNotFound else { throw MemberFailure.storage }
        var add = try query(scope); add[kSecValueData as String] = key; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem {
            existing = nil; guard SecItemCopyMatching(read as CFDictionary, &existing) == errSecSuccess, existing as? Data == key else { throw MemberFailure.storage }; return
        }
        guard added == errSecSuccess else { throw MemberFailure.storage }
    }
}

private struct ProtectedOperationEnvelope: Codable {
    let profile: String
    let scope: String
    let nonce: String
    let ciphertext: String
}

/// Device-private operation journal. Filenames reveal random operation identifiers; file contents
/// reveal only a scope digest and authenticated ciphertext. The key is non-synchronizing and bound
/// to this app installation by the supplied vault.
public final class ProtectedFileMemberOperationStore: MemberOperationStore, @unchecked Sendable {
    private let directory: URL
    private let environment: MemberEnvironment
    private let vault: any MemberOperationKeyVault
    private let lock = NSLock()
    public init(directory: URL, environment: MemberEnvironment, vault: any MemberOperationKeyVault) throws {
        guard directory.isFileURL else { throw MemberFailure.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.directory = directory; self.environment = environment; self.vault = vault
    }
    private func path(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw MemberFailure.invalidInput }
        return directory.appendingPathComponent(id + ".private")
    }
    private func canonicalArray(_ values: [String]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try! encoder.encode(values)
    }
    private func scope(_ household: String) -> String {
        SHA256.hash(data: canonicalArray(["atarasy.private-node-scope.1", environment.name, environment.origin.absoluteString, household])).map { String(format: "%02x", $0) }.joined()
    }
    private func aad(id: String, scope: String) -> Data { canonicalArray(["atarasy.private-operation.1", scope, id]) }
    private func read(_ id: String) throws -> MemberOperationHandle? {
        let url = try path(id); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 524_288 else { throw MemberFailure.storage }
        let envelope = try JSONDecoder().decode(ProtectedOperationEnvelope.self, from: Data(contentsOf: url))
        guard envelope.profile == "atarasy.private-operation.1", envelope.scope.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil,
              let nonceData = Data(base64Encoded: envelope.nonce), nonceData.count == 12,
              let sealed = Data(base64Encoded: envelope.ciphertext), sealed.count > 16,
              let keyData = try vault.key(scope: envelope.scope, create: false), keyData.count == 32 else { throw MemberFailure.storage }
        let nonce = try AES.GCM.Nonce(data: nonceData), box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let clear = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: aad(id: id, scope: envelope.scope))
        let value = try JSONDecoder().decode(MemberOperationHandle.self, from: clear)
        guard value.id == id, value.environment == environment.name, value.origin == environment.origin, scope(value.household) == envelope.scope else { throw MemberFailure.storage }
        return value
    }
    private func write(_ handle: MemberOperationHandle) throws {
        guard handle.environment == environment.name, handle.origin == environment.origin else { throw MemberFailure.storage }
        let clear = try JSONEncoder().encode(handle); guard clear.count <= 262_144 else { throw MemberFailure.storage }
        let reference = scope(handle.household), key = try vault.key(scope: reference, create: true)
        guard let key, key.count == 32 else { throw MemberFailure.storage }
        let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: key), authenticating: aad(id: handle.id, scope: reference))
        let payload = sealed.ciphertext + sealed.tag
        let envelope = ProtectedOperationEnvelope(profile: "atarasy.private-operation.1", scope: reference, nonce: Data(sealed.nonce).base64EncodedString(), ciphertext: payload.base64EncodedString())
        let data = try JSONEncoder().encode(envelope); guard data.count <= 524_288 else { throw MemberFailure.storage }
        let url = try path(handle.id); try data.write(to: url, options: [.atomic, .completeFileProtection]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ handle: MemberOperationHandle) throws { try lock.withLock { if let old = try read(handle.id) { guard old.sameOperation(handle) else { throw MemberFailure.storage } } else { try write(handle) } } }
    public func removeAll(household: String) throws {
        try lock.withLock {
            let reference = scope(household)
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "private" {
                // The envelope names the scope in clear, so a journal whose key is
                // already gone is still removed with the household it belongs to.
                guard let data = try? Data(contentsOf: url),
                      let envelope = try? JSONDecoder().decode(ProtectedOperationEnvelope.self, from: data),
                      envelope.scope == reference else { continue }
                try FileManager.default.removeItem(at: url)
            }
            try vault.forget(scope: reference)
        }
    }
    public func load(id: String) throws -> MemberOperationHandle? { try lock.withLock { try read(id) } }
    public func handles() throws -> [MemberOperationHandle] { try lock.withLock { try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "private" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { guard let value = try read($0.deletingPathExtension().lastPathComponent) else { throw MemberFailure.storage }; return value } } }
    public func claim(_ handle: MemberOperationHandle, confirmation: String) throws { try lock.withLock { guard let current = try read(handle.id), current == handle, !current.attempted else { throw MemberFailure.busy }; try write(current.markedAttempted(confirmation: confirmation)) } }
}

/// One shared store instance per app process. An app-private directory is required.
/// Atomic replacement survives restart; this is not a multi-process dispatcher.
public final class FileMemberOperationStore: MemberOperationStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw MemberFailure.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw MemberFailure.storage }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.directory = directory
    }
    private func path(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw MemberFailure.invalidInput }
        return directory.appendingPathComponent(id + ".json")
    }
    private func read(_ id: String) throws -> MemberOperationHandle? {
        let url = try path(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 262_144 else { throw MemberFailure.storage }
        let value = try JSONDecoder().decode(MemberOperationHandle.self, from: Data(contentsOf: url))
        guard value.id == id else { throw MemberFailure.storage }
        return value
    }
    private func write(_ handle: MemberOperationHandle) throws {
        let data = try JSONEncoder().encode(handle)
        guard data.count <= 262_144 else { throw MemberFailure.storage }
        let url = try path(handle.id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func save(_ handle: MemberOperationHandle) throws {
        try lock.withLock {
            if let existing = try read(handle.id) {
                guard existing.sameOperation(handle) else { throw MemberFailure.storage }
            } else { try write(handle) }
        }
    }
    public func load(id: String) throws -> MemberOperationHandle? { try lock.withLock { try read(id) } }
    public func handles() throws -> [MemberOperationHandle] {
        try lock.withLock {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard urls.count <= 10_000 else { throw MemberFailure.storage }
            return try urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                guard let handle = try read($0.deletingPathExtension().lastPathComponent) else { throw MemberFailure.storage }
                return handle
            }
        }
    }
    public func claim(_ handle: MemberOperationHandle, confirmation: String) throws {
        try lock.withLock {
            guard let current = try read(handle.id), current == handle, !current.attempted else { throw MemberFailure.busy }
            try write(current.markedAttempted(confirmation: confirmation))
        }
    }
}
