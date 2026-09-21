import Foundation

public let memberDecisionProfile = "atarasy.member-decision-authorisation.1"
func digitalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func digitalDigest<T: Encodable>(_ value: T) throws -> String {
    Canonical.digest(String(decoding: try digitalJSON(value), as: UTF8.self))
}
/// Hash only immutable offer terms, so a recorded decision can change state and decision timestamps.
func digitalTermsDigest(_ detail: MemberOfferDetail) throws -> String {
    guard var object = try JSONSerialization.jsonObject(with: digitalJSON(detail)) as? [String: Any],
          var candidates = object["candidates"] as? [[String: Any]] else { throw MemberFailure.malformed }
    for key in ["state", "decidedAt", "collectedAsSupplied"] { object.removeValue(forKey: key) }
    for i in candidates.indices {
        for key in ["valence", "decidedAt", "keptAs", "lineage", "collectedAs"] { candidates[i].removeValue(forKey: key) }
    }
    object["candidates"] = candidates.sorted { ($0["id"] as! String).utf16.lexicographicallyPrecedes(($1["id"] as! String).utf16) }
    return Canonical.digest(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
}

public struct PreparedMemberDecision: Sendable {
    public let environment: MemberEnvironment
    public let session: MemberSessionInfo
    public let detail: MemberOfferDetail
    public let approval: MemberApproval
    public let decisions: [Decision]
    public let canonical: String
    public let summary: MemberDigitalDraft.Summary
    public init(environment: MemberEnvironment, session: MemberSessionInfo, detail: MemberOfferDetail, draft: MemberDigitalDraft, now: Int64) throws {
        guard session.expiresAt > now, detail.expiresAt > now, detail.state == "presented", detail.binding == "digital",
              ReviewValidation.same(session.household, detail.household), session.presenters.contains(where: { ReviewValidation.same($0, detail.presenter) }),
              ReviewValidation.same(draft.approval.offer, detail.id), ReviewValidation.same(draft.approval.presenter, detail.presenter) else { throw MemberFailure.scopeMismatch }
        self.environment = environment; self.session = session; self.detail = detail; approval = draft.approval
        decisions = try draft.decisions(now: now); summary = try draft.summary(now: now)
        canonical = try Canonical.decisions(offer: detail.id, lines: decisions)
    }
}
public struct MemberPreparedDecision: Decodable, Sendable {
    public let profile: String
    public let operationID: String
    public let requestDigest: String
    public let reviewedRevision: String
    public let expiresAt: Int64
    public let canonical: String
    public let review: MemberJSON
    public let operationState: String
    public let publicKey: [String: MemberJSON]

    func validate(environment: MemberEnvironment, canonical expected: String, profile expectedProfile: String = memberDecisionProfile) throws {
        guard profile == expectedProfile, UUID(uuidString: operationID)?.uuidString.lowercased() == operationID,
              [requestDigest, reviewedRevision].allSatisfy({ $0.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil }),
              ReviewValidation.same(canonical, expected), ReviewValidation.safe(expiresAt),
              ["prepared", "dispatching", "uncertain", "committed", "cancelled", "refused"].contains(operationState),
              Set(publicKey.keys) == ["challenge", "rpId", "userVerification", "allowCredentials"],
              publicKey["rpId"] == .string(environment.origin.host!), publicKey["userVerification"] == .string("required"),
              case .array(let allowed) = publicKey["allowCredentials"], allowed.count == 1,
              case .object(let credential) = allowed[0], Set(credential.keys) == ["type", "id"],
              credential["type"] == .string("public-key"), case .string(let id) = credential["id"], !id.isEmpty else { throw MemberFailure.malformed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let scope = MemberJSON.array([.integer(1), .string(environment.name), .string(environment.origin.absoluteString), .string(environment.origin.host!)])
        let scopeText = String(decoding: try encoder.encode(scope), as: UTF8.self)
        let envelope = MemberJSON.array([.string(profile), .string(scopeText), .string(operationID), .string(requestDigest), .string(reviewedRevision)])
        guard publicKey["challenge"] == .string(Canonical.challenge(String(decoding: try encoder.encode(envelope), as: UTF8.self))) else { throw MemberFailure.scopeMismatch }
    }
}
public struct FrozenMemberDecision: Sendable {
    public let approval: MemberApproval
    public let mandate: Mandate
    public let decisions: [Decision]
    public let goods: Int64
    public let carriage: Int64
    public let total: Int64
    public init(_ prepared: MemberPreparedDecision, local: PreparedMemberDecision, now: Int64) throws {
        try prepared.validate(environment: local.environment, canonical: local.canonical)
        guard case .object(let view) = prepared.review, Set(view.keys) == ["approval", "mandate", "decisions", "goods", "carriage", "total"],
              let approvalJSON = view["approval"], let mandateJSON = view["mandate"], case .array(let rows) = view["decisions"],
              case .integer(let goods) = view["goods"], case .integer(let carriage) = view["carriage"], case .integer(let total) = view["total"] else { throw MemberFailure.malformed }
        approval = try MemberApproval.decode(JSONEncoder().encode(approvalJSON), detail: local.detail)
        mandate = try ReferenceResponseReader.mandate(status: 200, contentType: "application/json", data: JSONEncoder().encode(mandateJSON), expectedID: local.detail.mandate, expectedHousehold: local.detail.household)
        decisions = try rows.map { row in
            guard case .object(let d) = row, case .string(let id) = d["candidate"], case .string(let valence) = d["valence"] else { throw MemberFailure.malformed }
            if valence == "kept" {
                guard Set(d.keys) == ["candidate", "valence", "kept_as"], d["kept_as"] == .string("self") else { throw MemberFailure.malformed }
                return Decision(candidate: id, valence: valence, keptAs: "self")
            }
            guard valence == "returned", Set(d.keys) == ["candidate", "valence"] else { throw MemberFailure.malformed }
            return Decision(candidate: id, valence: valence)
        }
        guard try digitalJSON(approval) == digitalJSON(local.approval),
              ReviewValidation.same(try Canonical.decisions(offer: local.detail.id, lines: decisions), local.canonical),
              goods == local.summary.goods, carriage == local.summary.carriage, total == local.summary.total,
              prepared.expiresAt > now, prepared.expiresAt <= local.session.expiresAt, prepared.expiresAt <= local.detail.expiresAt,
              prepared.expiresAt <= mandate.lapsesAt, prepared.expiresAt <= (approval.mandate.lapsesAt ?? Canonical.maximumInteger) else { throw MemberFailure.scopeMismatch }
        self.goods = goods; self.carriage = carriage; self.total = total
    }
}
public enum MemberDecisionOutcome: Equatable, Sendable {
    /// The saved operation's historical decision, not provider payment or current offer status.
    case recorded(MemberOfferDetail)
    case pending(String)
    case unresolved
}
