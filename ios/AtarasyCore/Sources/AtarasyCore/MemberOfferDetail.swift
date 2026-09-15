import Foundation

public struct MemberOfferDetail: Decodable, Equatable, Sendable {
    public struct PriceBand: Decodable, Equatable, Sendable { public let min: Int64; public let max: Int64 }
    public struct Candidate: Decodable, Equatable, Sendable {
        public let id: String; public let product: String; public let quantity: Int64; public let unitPrice: Int64
        public let merchant: String; public let maker: String; public let ships: String
        public let category: String?; public let predictedConversion: Double?; public let isExploration: Bool
        public let givenBy: String?; public let valence: String; public let decidedAt: Int64?; public let keptAs: String?; public let lineage: String?
        /// §3, question 48. What the collection named this line, or nil where none did or the engine predates the field.
        public let collectedAs: String?
    }
    public struct Disclosure: Decodable, Equatable, Sendable {
        public struct Item: Decodable, Equatable, Sendable { public let label: String; public let value: String }
        public let merchant: String; public let product: String?; public let version: String
        public let items: [Item]; public let signature: String
    }
    public let id: String; public let binding: String; public let household: String; public let presenter: String
    public let presenterAttested: Bool; public let purpose: String; public let priceBand: PriceBand?; public let giver: String?
    public let configVersion: String; public let presentedAt: Int64?; public let expiresAt: Int64; public let state: String
    public let explorationFloorMet: Bool; public let mandate: String
    public let candidates: [Candidate]; public let disclosures: [Disclosure]
    /// Whether the engine sent `collected_as`, which is what lets a nil there mean "no collection named it".
    public private(set) var collectedAsSupplied: Bool? = nil

    public static func decode(_ data: Data, expectedID: String, household: String, presenter: String? = nil) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set("id binding household presenter presenter_attested purpose price_band giver config_version presented_at expires_at state exploration_floor_met mandate candidates disclosures".split(separator: " ").map(String.init)),
              let candidates = object["candidates"] as? [[String: Any]],
              candidates.allSatisfy({ Set($0.keys).subtracting(["collected_as"]) == Set("id product quantity unit_price merchant maker ships category predicted_conversion is_exploration given_by valence decided_at kept_as lineage".split(separator: " ").map(String.init)) }),
              let disclosures = object["disclosures"] as? [[String: Any]],
              disclosures.allSatisfy({ block in
                  guard Set(block.keys) == Set(["merchant", "product", "version", "items", "signature"]), let items = block["items"] as? [[String: Any]] else { return false }
                  return items.allSatisfy { Set($0.keys) == Set(["label", "value"]) }
              }) else { throw MemberFailure.malformed }
        if let band = object["price_band"] as? [String: Any], Set(band.keys) != Set(["min", "max"]) { throw MemberFailure.malformed }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var value: Self
        do { value = try decoder.decode(Self.self, from: data) } catch { throw MemberFailure.malformed }
        value.collectedAsSupplied = try ReviewValidation.collectedAs(candidates)
        func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
        guard !expectedID.isEmpty, same(value.id, expectedID), same(value.household, household), presenter.map({ same(value.presenter, $0) }) ?? true else { throw MemberFailure.scopeMismatch }
        func safe(_ n: Int64) -> Bool { n >= 0 && n <= 9_007_199_254_740_991 }
        let states = ["drafted", "presented", "decided", "expired", "withdrawn", "settled"]
        var ids = Set<Data>()
        guard ["digital", "physical"].contains(value.binding), states.contains(value.state),
              ["gift", "replenish", "trial", "ceremonial", "assortment"].contains(value.purpose),
              !value.presenter.isEmpty, !value.household.isEmpty, !value.configVersion.isEmpty, !value.mandate.isEmpty,
              safe(value.expiresAt), value.presentedAt.map(safe) ?? true,
              value.candidates.allSatisfy({ c in
                  !c.id.isEmpty && ids.insert(Data(c.id.utf8)).inserted && !c.product.isEmpty && !c.merchant.isEmpty && !c.maker.isEmpty && !c.ships.isEmpty && c.quantity > 0 && safe(c.quantity) && safe(c.unitPrice) && ["offered", "kept", "returned", "consumed", "defaulted", "lost"].contains(c.valence) && (c.decidedAt.map(safe) ?? true) && (c.predictedConversion.map { $0.isFinite && (0...1).contains($0) } ?? true) && (c.keptAs.map { ["self", "gift", "order"].contains($0) } ?? true) && (c.givenBy.map { !$0.isEmpty } ?? true)
              }), value.disclosures.allSatisfy({ d in
                  !d.merchant.isEmpty && !d.version.isEmpty && !d.signature.isEmpty && value.candidates.contains { c in same(c.merchant, d.merchant) && (d.product.map { same(c.product, $0) } ?? true) }
              }) else { throw MemberFailure.malformed }
        if let band = value.priceBand { guard safe(band.min), safe(band.max), band.min <= band.max else { throw MemberFailure.malformed } }
        guard (value.purpose == "ceremonial") == (value.priceBand != nil && value.giver?.isEmpty == false), value.purpose == "ceremonial" || (value.priceBand == nil && value.giver == nil) else { throw MemberFailure.malformed }
        return value
    }

    /// §3, questions 46 and 48. What a `lost` line says. Not in the box may be disputed on the statement;
    /// a line the deadline made `lost` is on no statement; where the engine sent no `collected_as` the two
    /// cannot be told apart and the sentence names both. The web hub carries the same words (`src/shared/screen.ts`).
    public static func lostOutcome(_ collectedAs: String?, supplied: Bool) -> String {
        if supplied && collectedAs == "missing" {
            return "Not in the box: the collection did not find it. Never charged to you, and you can dispute it on the statement if it was there."
        }
        if supplied && collectedAs == nil { return "Not collected by the deadline. Never charged to you." }
        return "Not returned: the collection did not find it in the box, or it was not collected by the deadline. Never charged to you."
    }
}
