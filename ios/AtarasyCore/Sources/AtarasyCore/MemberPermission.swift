import Foundation
import Combine

public struct MemberPermission: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let result_form: String?
    public let grantee: String
    public let scope: [String]
    public let purpose: String
    public let granted_at: Int64
    public let expires_at: Int64
    public let asked_from: String
    public let revoked_at: Int64?
    public func status(at now: Int64) -> String { revoked_at != nil ? "Revoked" : expires_at <= now ? "Expired" : "Active" }
    func sameGrant(_ other: Self) -> Bool {
        id == other.id && kind == other.kind && result_form == other.result_form && grantee == other.grantee && scope == other.scope && purpose == other.purpose && granted_at == other.granted_at && expires_at == other.expires_at && asked_from == other.asked_from
    }
    static func decode(_ value: MemberJSON, household: String) throws -> Self {
        guard case .object(let object) = value, Set(object.keys) == ["id", "kind", "result_form", "grantee", "scope", "purpose", "granted_at", "expires_at", "asked_from", "revoked_at"] else { throw MemberFailure.malformed }
        let row = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        guard UUID(uuidString: row.id)?.uuidString.lowercased() == row.id, ["party", "computation"].contains(row.kind),
              row.kind == "computation" ? row.result_form == "aggregate" : row.result_form == nil,
              !row.grantee.isEmpty, row.grantee != household, !row.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !row.asked_from.isEmpty, !row.scope.isEmpty, row.scope.allSatisfy({ !$0.isEmpty }), Set(row.scope).count == row.scope.count,
              ReviewValidation.safe(row.granted_at), ReviewValidation.safe(row.expires_at), row.expires_at > row.granted_at,
              row.revoked_at.map({ ReviewValidation.safe($0) && $0 >= row.granted_at }) ?? true else { throw MemberFailure.malformed }
        return row
    }
}
public struct MemberPermissionList: Sendable {
    public let household: String
    public let checkedAt: Int64
    public let permissions: [MemberPermission]
}
public protocol MemberPermissionService: Sendable {
    func permissionList() async throws -> MemberPermissionList
    func revokePermission(_ permission: MemberPermission) async throws -> MemberPermission
}
extension MemberClient: MemberPermissionService {}

@MainActor public final class MemberPermissions: ObservableObject {
    @Published public private(set) var rows: [MemberPermission] = []
    @Published public private(set) var selected: MemberPermission?
    @Published public private(set) var busy = false
    @Published public private(set) var loaded = false
    @Published public private(set) var notice = ""
    private let service: any MemberPermissionService
    private let now: () -> Int64
    private var session: MemberSessionInfo?
    private var generation: UInt64 = 0
    public init(service: any MemberPermissionService, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) { self.service = service; self.now = now }
    public func setSession(_ value: MemberSessionInfo?) { generation &+= 1; session = value; rows = []; selected = nil; loaded = false; notice = "" }
    public func leave() { generation &+= 1; selected = nil }
    public func select(_ value: MemberPermission) { guard !busy, loaded, rows.contains(value), value.revoked_at == nil, value.expires_at > now(), let session, session.expiresAt > now() else { return }; selected = value }
    public func cancel() { selected = nil }
    public func refresh() async {
        guard !busy, !Task.isCancelled, let session, session.expiresAt > now() else { return }
        busy = true; loaded = false; selected = nil; let current = generation; defer { busy = false }
        do {
            let result = try await service.permissionList()
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), result.household == session.household else { return }
            rows = result.permissions; loaded = true; notice = "Permissions checked. Expired and revoked records remain in your history."
        } catch { if current == generation { notice = "Permissions could not be checked. Refresh to confirm current access." } }
    }
    public func revoke(_ confirmed: MemberPermission? = nil) async {
        guard !busy, !Task.isCancelled, loaded, let selected = confirmed ?? selected, rows.contains(selected), let session, session.expiresAt > now() else { return }
        busy = true; self.selected = nil; loaded = false; let current = generation; defer { busy = false }
        do {
            let result = try await service.revokePermission(selected)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            guard result.sameGrant(selected), result.revoked_at != nil else { throw MemberFailure.scopeMismatch }
            rows = rows.map { $0.id == result.id ? result : $0 }; notice = "Permission revoked. Refresh to check the full list." 
        } catch { if current == generation { notice = "The result could not be confirmed. Refresh permissions before taking another action." } }
    }
}
