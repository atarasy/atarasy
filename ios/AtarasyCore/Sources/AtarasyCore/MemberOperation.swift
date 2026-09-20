import Foundation

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
    func save(_ handle: MemberOperationHandle) throws
    func load(id: String) throws -> MemberOperationHandle?
    /// Atomically persists attempted=true with the digest of the signature about to be sent,
    /// or refuses an already attempted operation.
    func claim(_ handle: MemberOperationHandle, confirmation: String) throws
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
