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
