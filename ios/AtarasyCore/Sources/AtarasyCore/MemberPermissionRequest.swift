import Foundation
import Combine

public struct MemberPermissionRequest: Codable, Equatable, Identifiable, Sendable {
    public struct Terms: Codable, Equatable, Sendable {
        public struct Requester: Codable, Equatable, Sendable { public let id: String; public let name: String }
        public struct Field: Codable, Equatable, Sendable { public let id: String; public let label: String }
        public let profile: String; public let requestID: String; public let household: String
        public let action: String; public let requester: Requester; public let purpose: String; public let fields: [Field]
        public let createdAt: Int64; public let reviewExpiresAt: Int64; public let accessExpiresAt: Int64
        // This profile hashes JSON.stringify of the issuer's fixed property order.
        func canonical() -> String {
            func q(_ s: String) -> String {
                "\"" + s.unicodeScalars.map { c -> String in
                    switch c.value { case 34: return "\\\""; case 92: return "\\\\"; case 8: return "\\b"; case 9: return "\\t"; case 10: return "\\n"; case 12: return "\\f"; case 13: return "\\r"; case 0..<32: return String(format: "\\u%04x", c.value); default: return String(c) }
                }.joined() + "\""
            }
            return "{\"profile\":\(q(profile)),\"requestID\":\(q(requestID)),\"household\":\(q(household)),\"action\":\(q(action)),\"requester\":{\"id\":\(q(requester.id)),\"name\":\(q(requester.name))},\"purpose\":\(q(purpose)),\"fields\":[" + fields.map { "{\"id\":\(q($0.id)),\"label\":\(q($0.label))}" }.joined(separator: ",") + "],\"createdAt\":\(createdAt),\"reviewExpiresAt\":\(reviewExpiresAt),\"accessExpiresAt\":\(accessExpiresAt)}"
        }
    }
    public let terms: Terms; public let digest: String; public let state: String
    public let decidedAt: Int64?; public let permission: MemberPermission?
    public var id: String { terms.requestID }
    public func canDecide(at now: Int64) -> Bool { state == "pending" && terms.createdAt <= now && terms.reviewExpiresAt > now }
    static func decode(_ raw: MemberJSON, household: String) throws -> Self {
        func keys(_ raw: MemberJSON?, _ keys: Set<String>) throws -> [String: MemberJSON] {
            guard case .object(let o) = raw, Set(o.keys) == keys else { throw MemberFailure.malformed }; return o
        }
        let object = try keys(raw, ["terms", "digest", "state", "decidedAt", "permission"])
        let terms = try keys(object["terms"], ["profile", "requestID", "household", "action", "requester", "purpose", "fields", "createdAt", "reviewExpiresAt", "accessExpiresAt"])
        _ = try keys(terms["requester"], ["id", "name"])
        guard case .array(let fields) = terms["fields"], fields.count == 1 else { throw MemberFailure.malformed }
        _ = try keys(fields[0], ["id", "label"])
        let row = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(raw)), t = row.terms
        func text(_ s: String) -> Bool { !s.isEmpty && s.utf16.count <= 512 && s.trimmingCharacters(in: .whitespacesAndNewlines) == s && !s.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
        guard t.profile == "atarasy.permission-review.1", UUID(uuidString: t.requestID)?.uuidString.lowercased() == t.requestID,
              Data(t.household.utf8) == Data(household.utf8), [t.household,t.action,t.requester.id,t.requester.name,t.purpose].allSatisfy(text), t.requester.id != household,
              t.fields == [.init(id: "duplicate_check", label: "Whether you already have a product")],
              [t.createdAt,t.reviewExpiresAt,t.accessExpiresAt].allSatisfy(ReviewValidation.safe), t.createdAt < t.reviewExpiresAt, t.reviewExpiresAt <= t.accessExpiresAt,
              Canonical.digest(t.canonical()) == row.digest, ["pending","expired","cancelled","granted"].contains(row.state) else { throw MemberFailure.scopeMismatch }
        if ["pending","expired"].contains(row.state) { guard row.decidedAt == nil, row.permission == nil else { throw MemberFailure.malformed } }
        else {
            guard let decided = row.decidedAt, ReviewValidation.safe(decided), decided >= t.createdAt, decided < t.reviewExpiresAt else { throw MemberFailure.malformed }
            if row.state == "cancelled" { guard row.permission == nil else { throw MemberFailure.malformed } }
            else {
                let p = try MemberPermission.decode(object["permission"]!, household: household)
                guard p.kind == "party", p.grantee == t.requester.id, p.scope == t.fields.map(\.id), Data(p.purpose.utf8) == Data(t.purpose.utf8), p.granted_at == decided, p.expires_at == t.accessExpiresAt else { throw MemberFailure.scopeMismatch }
            }
        }
        return row
    }
}
public protocol MemberPermissionRequestService: Sendable {
    func permissionRequests() async throws -> [MemberPermissionRequest]
    func permissionRequest(_ id: String) async throws -> MemberPermissionRequest
    func decidePermissionRequest(_ review: MemberPermissionRequest, grant: Bool) async throws -> MemberPermissionRequest
}
extension MemberClient: MemberPermissionRequestService {}

@MainActor public final class MemberPermissionRequests: ObservableObject {
    @Published public private(set) var rows: [MemberPermissionRequest] = []
    @Published public private(set) var review: MemberPermissionRequest?
    @Published public private(set) var busy = false
    @Published public private(set) var ready = false
    @Published public private(set) var notice = ""
    private let service: any MemberPermissionRequestService
    private let now: () -> Int64
    private var session: MemberSessionInfo?
    private var generation: UInt64 = 0
    public init(service: any MemberPermissionRequestService, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.service = service; self.now = now }
    public func setSession(_ value: MemberSessionInfo?) { generation &+= 1; session = value; rows = []; review = nil; ready = false; notice = "" }
    public func leave() { generation &+= 1; review = nil; ready = false }
    public func refresh() async {
        guard !busy, !Task.isCancelled, let session, session.expiresAt > now() else { return }
        let current = generation; busy = true; ready = false; review = nil; defer { busy = false }
        do {
            let result = try await service.permissionRequests()
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            rows = result; notice = L("Requests checked.")
        } catch { if current == generation { notice = L("Requests could not be checked. Refresh to try again.") } }
    }
    public func open(_ id: String) async {
        guard !busy, !Task.isCancelled, let session, session.expiresAt > now() else { return }
        let current = generation; busy = true; ready = false; review = nil; defer { busy = false }
        do {
            let result = try await service.permissionRequest(id)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            review = result; ready = result.canDecide(at: now()); notice = ""
        } catch { if current == generation { notice = L("This request could not be checked.") } }
    }
    public func decide(grant: Bool) async {
        guard !busy, !Task.isCancelled, ready, let review, review.canDecide(at: now()), let session, session.expiresAt > now() else { return }
        let current = generation; busy = true; ready = false; defer { busy = false }
        do {
            let result = try await service.decidePermissionRequest(review, grant: grant)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            self.review = result; notice = grant ? "Permission decision recorded. Check the current access status below." : "Request cancelled. No permission was granted."
        } catch { if current == generation { notice = L("We could not confirm the result. Check this request again before doing anything else.") } }
    }
}
