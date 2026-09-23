import Foundation

public struct MemberOfferDetail: Codable, Equatable, Sendable {
    public struct PriceBand: Codable, Equatable, Sendable { public let min: Int64; public let max: Int64 }
    public struct Candidate: Codable, Equatable, Sendable {
        public let id: String; public let product: String; public let quantity: Int64; public let unitPrice: Int64
        public let merchant: String; public let maker: String; public let ships: String
        public let category: String?; public let predictedConversion: Double?; public let isExploration: Bool
        public let givenBy: String?; public let valence: String; public let decidedAt: Int64?; public let keptAs: String?; public let lineage: String?
        /// §3, question 48. What the collection named this line, or nil where none did or the engine predates the field.
        public let collectedAs: String?
        /// Catalogue revision 3 (vault `80` D-1). The merchant's display name and variant, absent
        /// where the catalogue gave none; plain text rendered in the hub's own type (clause 54).
        public let name: String?
        public let variant: String?
    }
    public struct Disclosure: Codable, Equatable, Sendable {
        public struct Item: Codable, Equatable, Sendable { public let label: String; public let value: String }
        /// Question 72, decided 2026-09-22. The merchant's own contact, shown beside its
        /// return terms; nil where it gave none. Rendered exactly as signed.
        public struct Contact: Codable, Equatable, Sendable { public let kind: String; public let value: String }
        public let merchant: String; public let product: String?; public let version: String
        public let items: [Item]; public let signature: String
        public let contact: Contact?
    }
    public let id: String; public let binding: String; public let household: String; public let presenter: String
    public let presenterAttested: Bool; public let purpose: String; public let priceBand: PriceBand?; public let giver: String?
    public let configVersion: String; public let presentedAt: Int64?; public let expiresAt: Int64; public let state: String
    /// Q68: absent on older engines; never infer it from a candidate timestamp.
    public private(set) var decidedAt: Int64? = nil
    public let explorationFloorMet: Bool; public let mandate: String
    public let candidates: [Candidate]; public let disclosures: [Disclosure]
    /// Whether the engine sent `collected_as`, which is what lets a nil there mean "no collection named it".
    public private(set) var collectedAsSupplied: Bool? = nil

    public static func decode(_ data: Data, expectedID: String, household: String, presenter: String? = nil) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).subtracting(["decided_at"]) == Set("id binding household presenter presenter_attested purpose price_band giver config_version presented_at expires_at state exploration_floor_met mandate candidates disclosures".split(separator: " ").map(String.init)),
              let candidates = object["candidates"] as? [[String: Any]],
              candidates.allSatisfy({ Set($0.keys).subtracting(["collected_as", "name", "variant"]) == Set("id product quantity unit_price merchant maker ships category predicted_conversion is_exploration given_by valence decided_at kept_as lineage".split(separator: " ").map(String.init)) }),
              let disclosures = object["disclosures"] as? [[String: Any]],
              disclosures.allSatisfy({ block in
                  guard Set(block.keys).subtracting(["contact"]) == Set(["merchant", "product", "version", "items", "signature"]),
                        let items = block["items"] as? [[String: Any]],
                        validDisclosureContact(block["contact"]) else { return false }
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
              safe(value.expiresAt), value.presentedAt.map(safe) ?? true, value.decidedAt.map(safe) ?? true,
              value.candidates.allSatisfy({ c in
                  !c.id.isEmpty && ids.insert(Data(c.id.utf8)).inserted && !c.product.isEmpty && !c.merchant.isEmpty && !c.maker.isEmpty && !c.ships.isEmpty && c.quantity > 0 && safe(c.quantity) && safe(c.unitPrice) && ["offered", "kept", "returned", "consumed", "defaulted", "lost"].contains(c.valence) && (c.decidedAt.map(safe) ?? true) && (c.predictedConversion.map { $0.isFinite && (0...1).contains($0) } ?? true) && (c.keptAs.map { ["self", "gift", "order"].contains($0) } ?? true) && (c.givenBy.map { !$0.isEmpty } ?? true) && ReviewValidation.displayText(c.name, max: 120) && ReviewValidation.displayText(c.variant, max: 60)
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

/// Question 72. Shape only, matching the engine's own check: absent or explicitly
/// null is no contact at all; present must be exactly `kind` (one of three) and
/// `value` (non-empty, at most 256 UTF-8 bytes), the same limit the engine enforces
/// before it will sign one. Shared by `MemberOfferDetail.decode` and `ReviewValidation`.
func validDisclosureContact(_ raw: Any?) -> Bool {
    guard let raw, !(raw is NSNull) else { return true }
    guard let c = raw as? [String: Any], Set(c.keys) == Set(["kind", "value"]),
          let kind = c["kind"] as? String, ["email", "tel", "url"].contains(kind),
          let value = c["value"] as? String, !value.isEmpty, value.utf8.count <= 256
    else { return false }
    return true
}

extension MemberOfferDetail.Disclosure.Contact {
    /// The plain link a tap opens: `mailto:`, `tel:` or the url itself. Nothing here
    /// composes a message or sends anything; the tap, if there is one, is the
    /// household's own (§10a.7). `nil` only where the signed value cannot form a URL.
    public var url: URL? {
        let scheme: String
        switch kind {
        case "email": scheme = "mailto:"
        case "tel": scheme = "tel:"
        // Only https is a link: the engine refuses any other scheme at
        // registration, and a host that did not would otherwise hand the
        // screen a `javascript:` or `file:` link.
        default: return URL(string: value).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "+-._@")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return URL(string: scheme + encoded)
    }
}
