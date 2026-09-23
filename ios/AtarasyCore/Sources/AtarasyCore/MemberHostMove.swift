import Foundation
import CryptoKit
import Combine

public struct MemberHostExport: Sendable {
    public let id: String; public let household: String; public let sourceOrigin: URL; public let targetOrigin: URL
    public let digest: String; public let archive: String; public let privateRecords: [MemberPrivateNodeRecord]
}
public struct MemberHostImportReceipt: Codable, Equatable, Sendable {
    public let profile: String; public let move: String; public let household: String; public let sourceOrigin: String; public let targetOrigin: String
    public let archiveDigest: String; public let nodeDigest: String; public let privateRecords: Int; public let importedAt: Int64
}
public struct MemberHostImportAttestation: Sendable {
    public let receipt: MemberHostImportReceipt; let wire: MemberJSON
}
public struct PreparedMemberHostImportAttestation: Sendable { public let receipt: MemberHostImportReceipt; public let ceremony: MemberCeremony; let digest: String }
public struct PreparedMemberHostRetirement: Sendable { public let ceremony: MemberCeremony; public let targetOrigin: URL; let move: String; let attestation: MemberJSON }
public struct MemberHostRetirement: Codable, Equatable, Sendable { public let profile: String; public let move: String; public let household: String; public let targetOrigin: String; public let archiveDigest: String; public let receiptDigest: String; public let retiredAt: Int64 }

public protocol MemberHostMoveService: Sendable {
    func loginOptions() async throws -> MemberCeremony
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo
    func offers(presenter: String) async throws -> [MemberOfferSummary]
    func offerDetail(id: String) async throws -> MemberOfferDetail
    func settlement(offerID: String) async throws -> ProtocolSettlement
    func permissionList() async throws -> MemberPermissionList
    func exportHostMove(to target: MemberEnvironment) async throws -> MemberHostExport
    func importHostMove(_ export: MemberHostExport, privateRecords: [MemberPrivateNodeRecord]) async throws -> MemberHostImportReceipt
    func hostImportStatus(digest: String) async throws -> MemberHostImportReceipt
    func prepareHostImportAttestation(digest: String) async throws -> PreparedMemberHostImportAttestation
    func attestHostImport(_ prepared: PreparedMemberHostImportAttestation, assertion: MemberPasskeyResponse) async throws -> MemberHostImportAttestation
    func prepareHostRetirement(move: String, attestation: MemberHostImportAttestation) async throws -> PreparedMemberHostRetirement
    func retireHost(_ prepared: PreparedMemberHostRetirement, assertion: MemberPasskeyResponse) async throws -> MemberHostRetirement
}
extension MemberClient: MemberHostMoveService {}

private enum HostMoveWire {
    static let digestPattern = "^[A-Za-z0-9_-]{43}\\z"
    static func archiveBytes(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= 8_000_000, value.count % 4 != 1, value.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else { throw MemberFailure.malformed }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.count <= 6_000_000, PasskeyBytes.encode(bytes) == value else { throw MemberFailure.malformed }; return bytes
    }
    static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(value.keys) == keys else { throw MemberFailure.malformed }; return value
    }
    static func whole(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        let result = number.int64Value
        return result >= 0 && number.doubleValue == Double(result) ? result : nil
    }
    static func url(_ value: String) throws -> URL { guard let raw = URL(string: value), let result = try? MemberEnvironment(name: "move", origin: raw).origin, result.absoluteString == value else { throw MemberFailure.malformed }; return result }
    static func receipt(_ json: MemberJSON, household: String, source: URL? = nil, target: URL? = nil) throws -> MemberHostImportReceipt {
        guard case .object(let object) = json, Set(object.keys) == ["profile", "move", "household", "sourceOrigin", "targetOrigin", "archiveDigest", "nodeDigest", "privateRecords", "importedAt"] else { throw MemberFailure.malformed }
        let value = try JSONDecoder().decode(MemberHostImportReceipt.self, from: JSONEncoder().encode(json))
        let sourceURL = try url(value.sourceOrigin), targetURL = try url(value.targetOrigin)
        guard value.profile == "atarasy.member-host-import-receipt.1", UUID(uuidString: value.move)?.uuidString.lowercased() == value.move, value.household == household,
              value.archiveDigest.range(of: digestPattern, options: .regularExpression) != nil, value.nodeDigest.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil,
              value.privateRecords >= 0 && value.privateRecords <= 10_000, value.importedAt >= 0,
              source.map({ $0 == sourceURL }) ?? true, target.map({ $0 == targetURL }) ?? true else { throw MemberFailure.scopeMismatch }
        return value
    }
    static func ceremony(_ object: [String: Any], environment: MemberEnvironment, now: Int64) throws -> MemberCeremony {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": object["id"] as Any, "expiresAt": object["expiresAt"] as Any, "publicKey": object["publicKey"] as Any]),
              let value = try? JSONDecoder().decode(MemberCeremony.self, from: data) else { throw MemberFailure.malformed }
        _ = try NativePasskeyOptions(ceremony: value, environment: environment, kind: .hostMove, now: now); return value
    }
    static func assertionID(_ value: MemberPasskeyResponse) throws -> String { guard value.id == value.rawId, !value.id.isEmpty else { throw MemberFailure.scopeMismatch }; return value.id }
}

public extension MemberClient {
    func exportHostMove(to target: MemberEnvironment) async throws -> MemberHostExport {
        guard target.origin != environment.origin else { throw MemberFailure.invalidInput }
        struct Input: Encodable { let targetOrigin: String }
        let (reply, info) = try await read("/member/host-move/export", body: JSONEncoder().encode(Input(targetOrigin: target.origin.absoluteString)))
        let object = try HostMoveWire.object(reply.data, keys: ["profile", "id", "household", "sourceOrigin", "targetOrigin", "digest", "archive", "createdAt"])
        guard reply.status == 201, object["profile"] as? String == "atarasy.member-host-export.1", object["household"] as? String == info.household,
              object["sourceOrigin"] as? String == environment.origin.absoluteString, object["targetOrigin"] as? String == target.origin.absoluteString, HostMoveWire.whole(object["createdAt"]) != nil,
              let id = object["id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id, let encoded = object["archive"] as? String,
              let suppliedDigest = object["digest"] as? String, suppliedDigest.range(of: HostMoveWire.digestPattern, options: .regularExpression) != nil,
              let bytes = try? HostMoveWire.archiveBytes(encoded), PasskeyBytes.encode(Data(SHA256.hash(data: bytes))) == suppliedDigest else { throw MemberFailure.malformed }
        guard let archive = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(archive.keys) == ["profile", "move", "household", "sourceOrigin", "targetOrigin", "exportedAt", "node", "privateRecords", "recovery"],
              archive["profile"] as? String == "atarasy.member-host-archive.1", archive["move"] as? String == id, archive["household"] as? String == info.household,
              let sourceText = archive["sourceOrigin"] as? String, let targetText = archive["targetOrigin"] as? String, try HostMoveWire.url(sourceText) == environment.origin, try HostMoveWire.url(targetText) == target.origin,
              HostMoveWire.whole(archive["exportedAt"]) != nil,
              let rows = archive["privateRecords"] as? [Any], rows.count <= 10_000, rows.allSatisfy(validatePrivateRecordObject), let rowData = try? JSONSerialization.data(withJSONObject: rows), let records = try? JSONDecoder().decode([MemberPrivateNodeRecord].self, from: rowData), Set(records.map(\.id)).count == records.count else { throw MemberFailure.malformed }
        return .init(id: id, household: info.household, sourceOrigin: environment.origin, targetOrigin: target.origin, digest: suppliedDigest, archive: encoded, privateRecords: records)
    }
    func importHostMove(_ export: MemberHostExport, privateRecords: [MemberPrivateNodeRecord]) async throws -> MemberHostImportReceipt {
        struct Input: Encodable { let archive: String; let digest: String; let privateRecords: [MemberPrivateNodeRecord] }
        let (reply, info) = try await read("/member/host-move/import", body: JSONEncoder().encode(Input(archive: export.archive, digest: export.digest, privateRecords: privateRecords)))
        guard reply.status == 201 else { throw MemberFailure.http(reply.status) }
        let json = try JSONDecoder().decode(MemberJSON.self, from: reply.data), value = try HostMoveWire.receipt(json, household: info.household, source: export.sourceOrigin, target: environment.origin)
        guard value.move == export.id, value.archiveDigest == export.digest, value.privateRecords == privateRecords.count else { throw MemberFailure.scopeMismatch }; return value
    }
    func hostImportStatus(digest: String) async throws -> MemberHostImportReceipt {
        guard digest.range(of: HostMoveWire.digestPattern, options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
        let (reply, info) = try await read("/member/host-move/imports/" + digest), json = try JSONDecoder().decode(MemberJSON.self, from: reply.data)
        let value = try HostMoveWire.receipt(json, household: info.household, target: environment.origin); guard value.archiveDigest == digest else { throw MemberFailure.scopeMismatch }; return value
    }
    func prepareHostImportAttestation(digest: String) async throws -> PreparedMemberHostImportAttestation {
        guard digest.range(of: HostMoveWire.digestPattern, options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
        let (reply, info) = try await read("/member/host-move/imports/" + digest + "/prepare", body: Data("{}".utf8)), object = try HostMoveWire.object(reply.data, keys: ["profile", "receipt", "id", "expiresAt", "publicKey"])
        guard object["profile"] as? String == "atarasy.member-host-import-attestation-review.1", let receiptObject = object["receipt"], let receiptData = try? JSONSerialization.data(withJSONObject: receiptObject), let receiptJSON = try? JSONDecoder().decode(MemberJSON.self, from: receiptData) else { throw MemberFailure.malformed }
        let receipt = try HostMoveWire.receipt(receiptJSON, household: info.household, target: environment.origin); guard receipt.archiveDigest == digest else { throw MemberFailure.scopeMismatch }
        return .init(receipt: receipt, ceremony: try HostMoveWire.ceremony(object, environment: environment, now: now()), digest: digest)
    }
    func attestHostImport(_ prepared: PreparedMemberHostImportAttestation, assertion: MemberPasskeyResponse) async throws -> MemberHostImportAttestation {
        _ = try HostMoveWire.assertionID(assertion); struct Input: Encodable { let preparation: String; let assertion: MemberPasskeyResponse }
        let (reply, info) = try await read("/member/host-move/imports/" + prepared.digest + "/attest", body: JSONEncoder().encode(Input(preparation: prepared.ceremony.id, assertion: assertion)))
        let json = try JSONDecoder().decode(MemberJSON.self, from: reply.data)
        guard case .object(let object) = json, Set(object.keys) == ["profile", "receipt", "proof"], object["profile"] == .string("atarasy.member-host-import-attestation.1"), case .object(let proof) = object["proof"], Set(proof.keys) == ["credential", "assertion"], proof["credential"] == .string(assertion.id), let receiptJSON = object["receipt"] else { throw MemberFailure.malformed }
        let receipt = try HostMoveWire.receipt(receiptJSON, household: info.household, target: environment.origin); guard receipt == prepared.receipt else { throw MemberFailure.scopeMismatch }; return .init(receipt: receipt, wire: json)
    }
    func prepareHostRetirement(move: String, attestation: MemberHostImportAttestation) async throws -> PreparedMemberHostRetirement {
        guard UUID(uuidString: move)?.uuidString.lowercased() == move else { throw MemberFailure.invalidInput }
        struct Input: Encodable { let attestation: MemberJSON }
        let (reply, info) = try await read("/member/host-move/" + move + "/retirement/prepare", body: JSONEncoder().encode(Input(attestation: attestation.wire)))
        let object = try HostMoveWire.object(reply.data, keys: ["profile", "move", "attestation", "receiptDigest", "id", "expiresAt", "publicKey"])
        guard object["profile"] as? String == "atarasy.member-host-retirement-review.1", let moveObject = object["move"] as? [String: Any], moveObject["id"] as? String == move, moveObject["household"] as? String == info.household,
              let targetText = moveObject["targetOrigin"] as? String else { throw MemberFailure.scopeMismatch }
        return .init(ceremony: try HostMoveWire.ceremony(object, environment: environment, now: now()), targetOrigin: try HostMoveWire.url(targetText), move: move, attestation: attestation.wire)
    }
    func retireHost(_ prepared: PreparedMemberHostRetirement, assertion: MemberPasskeyResponse) async throws -> MemberHostRetirement {
        _ = try HostMoveWire.assertionID(assertion); struct Input: Encodable { let preparation: String; let attestation: MemberJSON; let assertion: MemberPasskeyResponse }
        let (reply, info) = try await read("/member/host-move/" + prepared.move + "/retirement/retire", body: JSONEncoder().encode(Input(preparation: prepared.ceremony.id, attestation: prepared.attestation, assertion: assertion)))
        let value = try decode(MemberHostRetirement.self, reply, keys: ["profile", "move", "household", "targetOrigin", "archiveDigest", "receiptDigest", "retiredAt"])
        guard value.profile == "atarasy.member-host-retirement.1", value.move == prepared.move, value.household == info.household, value.targetOrigin == prepared.targetOrigin.absoluteString, value.retiredAt >= 0 else { throw MemberFailure.scopeMismatch }
        try removeRetiredLocalSession(info); return value
    }
}

public enum MemberHostMovePhase: String, Sendable { case idle, signingIntoTarget, exporting, importing, verifying, readyToRetire, retiring, completed, sourceRetained, unresolved }

@MainActor public final class MemberHostMoveFlow: ObservableObject {
    @Published public private(set) var phase: MemberHostMovePhase = .idle
    @Published public private(set) var notice = ""
    @Published public private(set) var coverage = ""
    @Published public private(set) var targetReceipt: MemberHostImportReceipt?
    public var onRetired: (() -> Void)?
    private let sourceEnvironment: MemberEnvironment, targetEnvironment: MemberEnvironment
    private let source: any MemberHostMoveService, target: any MemberHostMoveService
    private let sourceNode: MemberPrivateNode, targetNode: MemberPrivateNode
    private let sourcePasskeys: any MemberPasskeyAuthorising, targetPasskeys: any MemberPasskeyAuthorising
    private var sourceSession: MemberSessionInfo?, targetSession: MemberSessionInfo?, exported: MemberHostExport?, attestation: MemberHostImportAttestation?
    public init(sourceEnvironment: MemberEnvironment, targetEnvironment: MemberEnvironment, source: any MemberHostMoveService, target: any MemberHostMoveService, sourceNode: MemberPrivateNode, targetNode: MemberPrivateNode, sourcePasskeys: any MemberPasskeyAuthorising, targetPasskeys: any MemberPasskeyAuthorising) {
        self.sourceEnvironment = sourceEnvironment; self.targetEnvironment = targetEnvironment; self.source = source; self.target = target; self.sourceNode = sourceNode; self.targetNode = targetNode; self.sourcePasskeys = sourcePasskeys; self.targetPasskeys = targetPasskeys
    }
    public func setSession(_ value: MemberSessionInfo?) { sourceSession = value; if value == nil { phase = .idle; targetReceipt = nil; exported = nil; attestation = nil; notice = ""; coverage = "" } }
    public func prepare() async {
        guard phase != .importing && phase != .verifying && phase != .retiring, let sourceSession else { return }
        var imported = false
        do {
            phase = .signingIntoTarget; notice = L("Sign in at the new host. Your current host stays active.")
            let login = try await target.loginOptions(), loginAssertion = try await targetPasskeys.authorise(login, kind: .assertion), targetSession = try await target.login(ceremony: login, response: loginAssertion)
            guard targetSession.household == sourceSession.household, targetSession.presenters.sorted() == sourceSession.presenters.sorted() else { throw MemberFailure.scopeMismatch }
            phase = .exporting
            async let sourcePermissions = source.permissionList(); let sourceOffers = try await surface(source, presenters: sourceSession.presenters)
            let export = try await source.exportHostMove(to: targetEnvironment), move = try await sourceNode.prepareMove(to: targetEnvironment, session: sourceSession)
            guard export.privateRecords == move.source else { throw MemberFailure.scopeMismatch }
            phase = .importing; let receipt = try await target.importHostMove(export, privateRecords: move.target); imported = true
            guard try await target.hostImportStatus(digest: export.digest) == receipt else { throw MemberFailure.scopeMismatch }
            let targetState = try await targetNode.open(session: targetSession); guard targetState == .recoveryRequired else { throw MemberFailure.scopeMismatch }
            try await targetNode.installRecoveredKey(move.key, session: targetSession)
            phase = .verifying
            let targetOffers = try await surface(target, presenters: targetSession.presenters), targetPermissions = try await target.permissionList(), originalPermissions = try await sourcePermissions
            guard sourceOffers == targetOffers, originalPermissions.household == targetPermissions.household, originalPermissions.permissions == targetPermissions.permissions, targetPermissions.household == sourceSession.household else { throw MemberFailure.scopeMismatch }
            let proofReview = try await target.prepareHostImportAttestation(digest: export.digest), proof = try await targetPasskeys.authorise(proofReview.ceremony, kind: .hostMove), attestation = try await target.attestHostImport(proofReview, assertion: proof)
            self.targetSession = targetSession; self.exported = export; self.attestation = attestation; targetReceipt = receipt
            coverage = "\(targetOffers.details.count) offers, \(targetPermissions.permissions.count) permissions and \(move.target.count) encrypted private records verified on \(targetEnvironment.origin.host ?? targetEnvironment.origin.absoluteString)."
            phase = .readyToRetire; notice = L("The new host has everything. Your current host stays active until you close it.")
        } catch is CancellationError { phase = imported ? .unresolved : .sourceRetained; notice = L("The move stopped. Your current host is unchanged.") }
        catch { phase = imported ? .unresolved : .sourceRetained; notice = imported ? "The target may contain an imported copy, but source access remains active. Verify the target before retirement." : "Nothing was retired. Source access remains active." }
    }
    public func retireSource() async {
        guard phase == .readyToRetire, let exported, let attestation else { return }
        do {
            phase = .retiring; let prepared = try await source.prepareHostRetirement(move: exported.id, attestation: attestation), assertion = try await sourcePasskeys.authorise(prepared.ceremony, kind: .hostMove)
            _ = try await source.retireHost(prepared, assertion: assertion); phase = .completed; notice = L("The move is complete, and your old host is closed."); onRetired?()
        } catch { phase = .unresolved; notice = L("We could not confirm that your old host was closed. Do not move again. Check both hosts first.") }
    }
    private struct Surface: Equatable { let summaries: [[MemberOfferSummary]]; let details: [String: MemberOfferDetail]; let settlements: [String: ProtocolSettlement] }
    private func surface(_ service: any MemberHostMoveService, presenters: [String]) async throws -> Surface {
        var summaries: [[MemberOfferSummary]] = [], details: [String: MemberOfferDetail] = [:], settlements: [String: ProtocolSettlement] = [:]
        for presenter in presenters.sorted() {
            let rows = try await service.offers(presenter: presenter).sorted { $0.id < $1.id }; summaries.append(rows)
            for row in rows { details[row.id] = try await service.offerDetail(id: row.id); if row.state == "settled" { settlements[row.id] = try await service.settlement(offerID: row.id) } }
        }
        return .init(summaries: summaries, details: details, settlements: settlements)
    }
}
