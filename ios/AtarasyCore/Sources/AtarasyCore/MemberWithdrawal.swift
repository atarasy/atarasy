import Foundation

public let memberWithdrawalProfile = "atarasy.member-withdrawal-authorisation.1"
func rawDigitalOffer(_ value: MemberJSON, handle: MemberOperationHandle) throws -> MemberOfferDetail {
    guard case .object(var object) = value, case .integer(let reminders) = object.removeValue(forKey: "reminders_sent"), (0...1).contains(reminders) else { throw MemberFailure.malformed }
    return try MemberOfferDetail.decode(JSONEncoder().encode(MemberJSON.object(object)), expectedID: handle.offer, household: handle.household, presenter: handle.presenter)
}
public struct FrozenMemberWithdrawal: Sendable {
    public let original: MemberOfferDetail
    public let approval: MemberApproval
    public let decisions: [Decision]
    public let mandate: Mandate
    public let goods: Int64
    public let carriage: Int64
    public let total: Int64
    public let coolingEndsAt: Int64
    public let nextIncarnation: Int64
    public init(_ prepared: MemberPreparedDecision, originalHandle: MemberOperationHandle, original: MemberOfferDetail, originalReview: MemberPreparedDecision, environment: MemberEnvironment, session: MemberSessionInfo, now: Int64) throws {
        guard originalHandle.operationProfile == memberDecisionProfile, original.binding == "digital", original.state == "decided", let decidedAt = original.decidedAt,
              prepared.operationState == "prepared", prepared.expiresAt > now, prepared.expiresAt <= session.expiresAt,
              session.household == original.household, session.presenters.contains(original.presenter),
              case .object(let view) = prepared.review, Set(view.keys) == ["decisionOperationID", "incarnation", "offer", "decisionReview", "mandate", "eligibility"],
              view["decisionOperationID"] == .string(originalHandle.id), case .integer(let incarnation) = view["incarnation"], incarnation >= 0, incarnation < Canonical.maximumInteger,
              let offerJSON = view["offer"], let decisionReview = view["decisionReview"], let mandateJSON = view["mandate"],
              case .object(let eligibility) = view["eligibility"], Set(eligibility.keys) == ["offer", "decidedAt", "decisionRevision", "canonical", "coolingEndsAt"],
              eligibility["offer"] == .string(original.id), eligibility["decidedAt"] == .integer(decidedAt),
              case .string(let revision) = eligibility["decisionRevision"], revision.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil,
              case .integer(let coolingEndsAt) = eligibility["coolingEndsAt"], ReviewValidation.safe(coolingEndsAt), coolingEndsAt > now, prepared.expiresAt <= coolingEndsAt,
              try rawDigitalOffer(offerJSON, handle: originalHandle) == original, try digitalJSON(decisionReview) == digitalJSON(originalReview.review) else { throw MemberFailure.scopeMismatch }
        let canonical = ["valence.member-withdrawal.1", original.id, String(decidedAt), revision].joined(separator: "\n")
        guard eligibility["canonical"] == .string(canonical) else { throw MemberFailure.scopeMismatch }
        try prepared.validate(environment: environment, canonical: canonical, profile: memberWithdrawalProfile)
        try originalReview.validate(environment: environment, canonical: originalHandle.canonical)
        guard originalReview.operationID == originalHandle.id, originalReview.operationState == "committed", originalReview.requestDigest == originalHandle.requestDigest,
              originalReview.reviewedRevision == originalHandle.reviewedRevision, case .object(let decision) = decisionReview,
              Set(decision.keys) == ["approval", "mandate", "decisions", "goods", "carriage", "total"], let approvalJSON = decision["approval"] else { throw MemberFailure.scopeMismatch }
        // The approval is the original pre-decision view. Reconstruct only the
        // mutable decision fields for its normal immutable-term validation.
        guard case .object(var before) = offerJSON, case .array(let candidates) = before["candidates"] else { throw MemberFailure.malformed }
        before["state"] = .string("presented"); before["decided_at"] = .null
        before["candidates"] = .array(try candidates.map { candidate in
            guard case .object(var c) = candidate else { throw MemberFailure.malformed }
            c["valence"] = .string("offered"); c["decided_at"] = .null; c["kept_as"] = .null; c["lineage"] = .null
            return .object(c)
        })
        let detail = try rawDigitalOffer(.object(before), handle: originalHandle)
        approval = try MemberApproval.decode(JSONEncoder().encode(approvalJSON), detail: detail)
        var draft = MemberDigitalDraft(approval: approval)
        for candidate in original.candidates {
            guard candidate.decidedAt == decidedAt, candidate.lineage == nil,
                  (candidate.valence == "kept" && candidate.keptAs == "self") || (candidate.valence == "returned" && candidate.keptAs == nil) else { throw MemberFailure.scopeMismatch }
            try draft.choose(candidate.valence == "kept" ? .keep : .decline, candidate: candidate.id)
        }
        decisions = try draft.decisions(now: min(decidedAt, original.expiresAt - 1))
        let summary = try draft.summary(now: min(decidedAt, original.expiresAt - 1))
        let expectedRows: [MemberJSON] = decisions.map { d in
            var row: [String: MemberJSON] = ["candidate": .string(d.candidate), "valence": .string(d.valence)]
            if let keptAs = d.keptAs { row["kept_as"] = .string(keptAs) }; return .object(row)
        }
        guard try Canonical.decisions(offer: original.id, lines: decisions) == originalHandle.canonical,
              case .array(let rows) = decision["decisions"], Set(try rows.map { try digitalDigest($0) }) == Set(try expectedRows.map { try digitalDigest($0) }), rows.count == expectedRows.count,
              decision["goods"] == .integer(summary.goods), decision["carriage"] == .integer(summary.carriage), decision["total"] == .integer(summary.total) else { throw MemberFailure.scopeMismatch }
        mandate = try ReferenceResponseReader.mandate(status: 200, contentType: "application/json", data: JSONEncoder().encode(mandateJSON), expectedID: original.mandate, expectedHousehold: original.household)
        self.original = original; goods = summary.goods; carriage = summary.carriage; total = summary.total; self.coolingEndsAt = coolingEndsAt; nextIncarnation = incarnation + 1
    }
}
public enum MemberWithdrawalOutcome: Equatable, Sendable {
    case recorded(MemberOfferDetail)
    case pending(String)
    case unresolved
}
