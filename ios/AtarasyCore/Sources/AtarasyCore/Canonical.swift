import Foundation
import CryptoKit

public enum ContractError: Error { case invalidValue, invalidTransition }
public struct Decision: Codable, Equatable, Sendable {
    public var candidate: String
    public var valence: String
    public var keptAs: String?
    public var lineage: String?
    public init(candidate: String, valence: String, keptAs: String? = nil, lineage: String? = nil) { self.candidate=candidate; self.valence=valence; self.keptAs=keptAs; self.lineage=lineage }
}
public struct StatementLine: Codable, Equatable, Sendable {
    public var candidate: String
    public var valence: String
    public var amount: Int64
    public var disputed: Bool
    public init(candidate: String, valence: String, amount: Int64, disputed: Bool) { self.candidate=candidate; self.valence=valence; self.amount=amount; self.disputed=disputed }
}
public struct Mandate: Codable, Sendable {
    public var id: String; public var household: String
    public var ceilingOutOfNetwork: Int64; public var ceilingDaily: Int64?; public var coolingSeconds: Int64?
    public var coSigners: [String]; public var lapsesAt: Int64; public var version: Int64
}
public enum Canonical {
    public static let maximumInteger: Int64 = 9_007_199_254_740_991
    private static func integer(_ v: Int64) throws { guard (0...maximumInteger).contains(v) else { throw ContractError.invalidValue } }
    private static func identifier(_ v: String) throws { guard !v.isEmpty, !v.contains("\n"), !v.contains("\r"), !v.contains(":") else { throw ContractError.invalidValue } }
    private static func ordered(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }
    private static func encoded(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        return value.utf8.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }
    public static func decisions(offer: String, lines: [Decision]) throws -> String {
        try identifier(offer)
        guard Set(lines.map { Data($0.candidate.utf8) }).count == lines.count else { throw ContractError.invalidValue }
        for line in lines { try identifier(line.candidate); guard ["kept","returned"].contains(line.valence) else { throw ContractError.invalidValue }; if let asValue=line.keptAs { guard ["self","gift","order"].contains(asValue) else { throw ContractError.invalidValue } }; if let lineage=line.lineage { try identifier(lineage) } }
        return ([offer] + lines.sorted { ordered($0.candidate,$1.candidate) }.map { "\($0.candidate):\($0.valence):\($0.keptAs ?? ""):\($0.lineage ?? "")" }).joined(separator: "\n")
    }
    public static func statement(offer: String, carriage: Int64?, lines: [StatementLine]) throws -> String {
        try identifier(offer); guard let carriage else { throw ContractError.invalidValue }; try integer(carriage)
        guard Set(lines.map { Data($0.candidate.utf8) }).count == lines.count else { throw ContractError.invalidValue }
        for line in lines { try identifier(line.candidate); try integer(line.amount); guard ["kept","defaulted","consumed"].contains(line.valence), !line.disputed || line.valence == "consumed" else { throw ContractError.invalidValue } }
        return (["valence.statement.1",offer,String(carriage)] + lines.sorted { ordered($0.candidate,$1.candidate) }.map { "\($0.candidate):\($0.valence):\($0.amount):\($0.disputed ? "disputed" : "")" }).joined(separator:"\n")
    }
    public static func mandate(_ m: Mandate) throws -> String {
        try identifier(m.id); try identifier(m.household)
        for value in [m.ceilingOutOfNetwork,m.ceilingDaily,m.coolingSeconds,m.lapsesAt,m.version].compactMap({$0}) { try integer(value) }
        guard m.version >= 1 else { throw ContractError.invalidValue }
        return [m.id,m.household,String(m.ceilingOutOfNetwork),m.ceilingDaily.map(String.init) ?? "",m.coolingSeconds.map(String.init) ?? "",m.coSigners.sorted(by:ordered).map(encoded).joined(separator:","),String(m.lapsesAt),String(m.version)].joined(separator:"\n")
    }
    public static func digest(_ text: String) -> String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
    public static func challenge(_ text: String) -> String { Data(SHA256.hash(data:Data(text.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
}
