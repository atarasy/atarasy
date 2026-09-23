import Foundation

public enum MemberReview: Equatable, Sendable {
    case approval(MemberApproval)
    case statement(MemberStatement)
    /// A physical box that has already settled. There is nothing left to sign, so the
    /// settlement that stands is shown instead of a statement to prepare. §6.6: beside
    /// it, whatever corrections the merchant has appended, or nil where none were found,
    /// which is never treated as a reason to hide the settlement itself. The offer's own
    /// disclosures ride along so a correction_return (§6.6a) can show the merchant's signed
    /// contact or its return terms beside it; nothing here refetches them.
    case settlement(ProtocolSettlement, MemberCorrections?, [MemberOfferDetail.Disclosure])
}
public struct MemberDisclosureReference: Codable, Equatable, Sendable {
    public let merchant: String; public let product: String?
}
public struct MemberApproval: Codable, Equatable, Sendable {
    public struct MandateTerms: Codable, Equatable, Sendable {
        public let kind: String; public let scope: String; public let lapsesAt: Int64?
    }
    public struct Candidate: Codable, Equatable, Sendable {
        public let id: String; public let product: String; public let merchant: String; public let maker: String; public let ships: String
        public let givenBy: String?; public let quantity: Int64; public let unitPrice: Int64
        public let isExploration: Bool; public let valence: String
        public let alternatives: [String]; public let argumentAgainst: String; public let disclosure: MemberDisclosureReference
        public let name: String?; public let variant: String?
    }
    public struct Excluded: Codable, Equatable, Sendable { public let product: String; public let reason: String }
    public let offer: String; public let presenter: String; public let expiresAt: Int64; public let carriage: Int64?
    public let priceBand: MemberOfferDetail.PriceBand?; public let disclosures: [MemberOfferDetail.Disclosure]
    public let reminded: Bool; public let mandate: MandateTerms; public let candidates: [Candidate]; public let excluded: [Excluded]

    public static func decode(_ data: Data, detail: MemberOfferDetail) throws -> Self {
        let object = try ReviewValidation.object(data, keys: "price_band disclosures offer presenter expires_at carriage reminded mandate candidates excluded")
        try ReviewValidation.shape(object["mandate"], keys: "kind scope lapses_at")
        if !(object["price_band"] is NSNull) { try ReviewValidation.shape(object["price_band"], keys: "min max") }
        try ReviewValidation.rows(object["candidates"], keys: "merchant maker ships given_by id product quantity unit_price is_exploration valence alternatives argument_against disclosure", optional: "collected_as name variant", reference: true)
        _ = try ReviewValidation.collectedAs(object["candidates"])
        try ReviewValidation.rows(object["excluded"], keys: "product reason")
        try ReviewValidation.disclosureShape(object["disclosures"])
        let value: Self = try ReviewValidation.decode(data)
        guard detail.binding == "digital", ReviewValidation.same(value.offer, detail.id), ReviewValidation.same(value.presenter, detail.presenter), value.expiresAt == detail.expiresAt else { throw MemberFailure.scopeMismatch }
        guard value.priceBand == detail.priceBand, ReviewValidation.sameDisclosures(value.disclosures, detail.disclosures), value.carriage.map(ReviewValidation.safe) ?? true,
              ["standing", "individual"].contains(value.mandate.kind), !value.mandate.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.mandate.lapsesAt.map(ReviewValidation.safe) ?? true, value.mandate.kind != "standing" || value.mandate.lapsesAt != nil,
              value.candidates.count == detail.candidates.count else { throw MemberFailure.malformed }
        var ids = Set<Data>()
        for c in value.candidates {
            guard ids.insert(Data(c.id.utf8)).inserted,
                  let source = detail.candidates.first(where: { ReviewValidation.same($0.id, c.id) }),
                  ReviewValidation.matches(source, product: c.product, merchant: c.merchant, maker: c.maker, ships: c.ships, giver: c.givenBy, quantity: c.quantity, unitPrice: c.unitPrice, valence: c.valence),
                  c.isExploration == source.isExploration, !c.alternatives.isEmpty,
                  ReviewValidation.sameOptional(c.name, source.name), ReviewValidation.sameOptional(c.variant, source.variant),
                  c.alternatives.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  !c.argumentAgainst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ReviewValidation.governs(c.disclosure, candidate: source, blocks: value.disclosures) else { throw MemberFailure.malformed }
        }
        let reasons = ["auto_renewal", "obstructed_cancellation", "manufactured_scarcity", "late_price", "outside_mandate", "declined_before"]
        guard value.excluded.allSatisfy({ !$0.product.isEmpty && reasons.contains($0.reason) }) else { throw MemberFailure.malformed }
        return value
    }
}
public struct MemberStatement: Decodable, Equatable, Sendable {
    public struct Line: Decodable, Equatable, Sendable {
        public let candidate: String; public let product: String; public let merchant: String; public let maker: String; public let ships: String
        public let givenBy: String?; public let valence: String; public let quantity: Int64; public let unitPrice: Int64; public let amount: Int64
        /// Question 46. The collection's note for a missing (`lost`) line; nil otherwise and from engines before it.
        public let note: String?
        public let disclosure: MemberDisclosureReference
        public let name: String?; public let variant: String?
    }
    public let offer: String; public let household: String; public let expiresAt: Int64
    public let lines: [Line]; public let disclosures: [MemberOfferDetail.Disclosure]; public let carriage: Int64?; public let challenge: String
    public static func decode(_ data: Data, detail: MemberOfferDetail) throws -> Self {
        let object = try ReviewValidation.object(data, keys: "offer household expires_at lines disclosures carriage challenge")
        // Question 46 added `note` to every line. A capture from an engine before it carries no such key, and no lost line.
        let base = "candidate product merchant maker ships given_by valence quantity unit_price amount disclosure"
        let hasNote = ((object["lines"] as? [[String: Any]])?.first?.keys.contains("note")) ?? false
        try ReviewValidation.rows(object["lines"], keys: hasNote ? base + " note" : base, optional: "name variant", reference: true)
        try ReviewValidation.disclosureShape(object["disclosures"])
        let value: Self = try ReviewValidation.decode(data)
        guard detail.binding == "physical", ReviewValidation.same(value.offer, detail.id), ReviewValidation.same(value.household, detail.household), value.expiresAt == detail.expiresAt else { throw MemberFailure.scopeMismatch }
        let eligible = detail.candidates.filter { ["kept", "defaulted", "consumed"].contains($0.valence) }
        // A `lost` candidate is on the statement only where the collection recorded it missing, which the detail
        // cannot say, so lost lines are checked against lost candidates and every other eligible line must be present.
        let lost = detail.candidates.filter { $0.valence == "lost" }
        guard value.lines.filter({ $0.valence != "lost" }).count == eligible.count, ReviewValidation.sameDisclosures(value.disclosures, detail.disclosures), value.carriage.map(ReviewValidation.safe) ?? true else { throw MemberFailure.malformed }
        var ids = Set<Data>()
        for line in value.lines {
            guard ids.insert(Data(line.candidate.utf8)).inserted,
                  let source = (line.valence == "lost" ? lost : eligible).first(where: { ReviewValidation.same($0.id, line.candidate) }),
                  ReviewValidation.matches(source, product: line.product, merchant: line.merchant, maker: line.maker, ships: line.ships, giver: line.givenBy, quantity: line.quantity, unitPrice: line.unitPrice, valence: line.valence),
                  ReviewValidation.sameOptional(line.name, source.name), ReviewValidation.sameOptional(line.variant, source.variant),
                  ReviewValidation.governs(line.disclosure, candidate: source, blocks: value.disclosures), ReviewValidation.safe(line.amount) else { throw MemberFailure.malformed }
            if line.valence == "lost" {
                // Never charged, and a missing record always carries the collection's note.
                guard line.amount == 0, let note = line.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemberFailure.malformed }
                continue
            }
            guard line.note == nil else { throw MemberFailure.malformed }
            let amount = source.quantity.multipliedReportingOverflow(by: source.unitPrice)
            if source.givenBy != nil { guard line.amount == 0 else { throw MemberFailure.malformed } }
            else { guard !amount.overflow, ReviewValidation.safe(amount.partialValue), line.amount == amount.partialValue else { throw MemberFailure.malformed } }
        }
        // The service hashes a zero placeholder when carriage is missing. This is
        // integrity checking only: preserve nil and never expose signing readiness.
        let canonical: String
        do { canonical = try Canonical.statement(offer: value.offer, carriage: value.carriage ?? 0, lines: value.lines.map { .init(candidate: $0.candidate, valence: $0.valence, amount: $0.amount, disputed: false) }) }
        catch { throw MemberFailure.malformed }
        guard ReviewValidation.same(value.challenge, Canonical.challenge(canonical)) else { throw MemberFailure.malformed }
        return value
    }
}
enum ReviewValidation {
    static func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
    static func sameOptional(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) { case (.none, .none): return true; case let (.some(a), .some(b)): return same(a, b); default: return false }
    }
    static func safe(_ value: Int64) -> Bool { (0...Canonical.maximumInteger).contains(value) }
    /// Catalogue revision 3. Absent is legitimate; present is nonempty text within the published bound.
    static func displayText(_ value: String?, max: Int) -> Bool {
        guard let value else { return true }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= max
    }
    /// The same check on a raw row, where a present key must also be a string.
    static func displayFields(_ row: [String: Any]) -> Bool {
        for (key, max) in [("name", 120), ("variant", 60)] {
            guard let raw = row[key] else { continue }
            guard let text = raw as? String, displayText(text, max: max) else { return false }
        }
        return true
    }
    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) } catch { throw MemberFailure.malformed }
    }
    /// `optional` names keys a newer engine adds and an older one omits; any other difference is refused.
    static func shape(_ value: Any?, keys: String, optional: String = "") throws {
        let required = Set(keys.split(separator: " ").map(String.init)), extra = Set(optional.split(separator: " ").map(String.init))
        guard let value = value as? [String: Any], Set(value.keys).subtracting(extra) == required else { throw MemberFailure.malformed }
    }
    static func object(_ data: Data, keys: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MemberFailure.malformed }
        try shape(object, keys: keys); return object
    }
    static func rows(_ value: Any?, keys: String, optional: String = "", reference: Bool = false) throws {
        guard let rows = value as? [[String: Any]] else { throw MemberFailure.malformed }
        for row in rows { try shape(row, keys: keys, optional: optional); if reference { try shape(row["disclosure"], keys: "merchant product") } }
    }
    /// §3, question 48. Where an engine sends `collected_as` it sends it on every row, as null or a collection verdict.
    static func collectedAs(_ value: Any?) throws -> Bool {
        guard let rows = value as? [[String: Any]] else { throw MemberFailure.malformed }
        let present = rows.filter { $0.keys.contains("collected_as") }.count
        guard present == 0 || present == rows.count else { throw MemberFailure.malformed }
        guard rows.allSatisfy({ row in
            guard let v = row["collected_as"] else { return true }
            return v is NSNull || ["returned", "consumed", "missing"].contains(v as? String ?? "")
        }) else { throw MemberFailure.malformed }
        return present > 0
    }
    static func disclosureShape(_ value: Any?) throws {
        try rows(value, keys: "merchant product version items signature", optional: "contact")
        for row in value as! [[String: Any]] {
            try rows(row["items"], keys: "label value")
            guard validDisclosureContact(row["contact"]) else { throw MemberFailure.malformed }
        }
    }
    static func sameContact(_ a: MemberOfferDetail.Disclosure.Contact?, _ b: MemberOfferDetail.Disclosure.Contact?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case let (.some(a), .some(b)): return same(a.kind, b.kind) && same(a.value, b.value)
        default: return false
        }
    }
    static func sameDisclosures(_ a: [MemberOfferDetail.Disclosure], _ b: [MemberOfferDetail.Disclosure]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { a, b in
            same(a.merchant, b.merchant) && sameOptional(a.product, b.product) && same(a.version, b.version) && same(a.signature, b.signature) && sameContact(a.contact, b.contact) && a.items.count == b.items.count && zip(a.items, b.items).allSatisfy { same($0.label, $1.label) && same($0.value, $1.value) }
        }
    }
    static func matches(_ c: MemberOfferDetail.Candidate, product: String, merchant: String, maker: String, ships: String, giver: String?, quantity: Int64, unitPrice: Int64, valence: String) -> Bool {
        same(c.product, product) && same(c.merchant, merchant) && same(c.maker, maker) && same(c.ships, ships) && sameOptional(c.givenBy, giver) && c.quantity == quantity && c.unitPrice == unitPrice && same(c.valence, valence)
    }
    static func governs(_ reference: MemberDisclosureReference, candidate: MemberOfferDetail.Candidate, blocks: [MemberOfferDetail.Disclosure]) -> Bool {
        let relevant = blocks.filter { same($0.merchant, candidate.merchant) }
        let product = relevant.contains { sameOptional($0.product, candidate.product) } ? candidate.product : nil
        return same(reference.merchant, candidate.merchant) && sameOptional(reference.product, product) && relevant.contains { sameOptional($0.product, product) }
    }
}
