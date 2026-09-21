import Foundation

/// An unsigned claim is shown for review; it has no effect until the member signs it.
public struct MemberMandate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let household: String
    public let ceilingOutOfNetwork: Int64
    public let ceilingDaily: Int64?
    public let coolingSeconds: Int64?
    public let coSigners: [String]
    public let lapsesAt: Int64
    public let version: Int64
    enum CodingKeys: String, CodingKey {
        case id, household, version
        case ceilingOutOfNetwork = "ceiling_out_of_network", ceilingDaily = "ceiling_daily"
        case coolingSeconds = "cooling_seconds", coSigners = "co_signers", lapsesAt = "lapses_at"
    }
    public init(id: String, household: String, ceilingOutOfNetwork: Int64, ceilingDaily: Int64?, coolingSeconds: Int64?, coSigners: [String], lapsesAt: Int64, version: Int64) {
        self.id = id; self.household = household; self.ceilingOutOfNetwork = ceilingOutOfNetwork; self.ceilingDaily = ceilingDaily; self.coolingSeconds = coolingSeconds; self.coSigners = coSigners; self.lapsesAt = lapsesAt; self.version = version
    }
    public func canonical(host: String) throws -> String {
        try Canonical.mandate(Mandate(id: id, household: household, ceilingOutOfNetwork: ceilingOutOfNetwork, ceilingDaily: ceilingDaily, coolingSeconds: coolingSeconds, coSigners: coSigners, lapsesAt: lapsesAt, version: version), host: host)
    }
}
public struct MemberMandateReview: Sendable {
    public let mandate: MemberMandate
    public let host: String
    public let ceremony: MemberCeremony
    let sessionID: String
    let credentialID: String
}

public struct MemberMandateChange: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let before: MemberMandate
    public let mandate: MemberMandate
    public let requiredSigners: [String]
    public let signedBy: [String]
    public let state: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public init(id: String, before: MemberMandate, mandate: MemberMandate, requiredSigners: [String], signedBy: [String], state: String, createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.before = before; self.mandate = mandate; self.requiredSigners = requiredSigners; self.signedBy = signedBy; self.state = state; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct PreparedMemberMandateChange: Sendable {
    public let change: MemberMandateChange
    public let ceremony: MemberCeremony
    let sessionID: String
    let credentialID: String
    public init(change: MemberMandateChange, ceremony: MemberCeremony, sessionID: String, credentialID: String) {
        self.change = change; self.ceremony = ceremony; self.sessionID = sessionID; self.credentialID = credentialID
    }
}
