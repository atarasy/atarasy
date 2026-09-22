import Foundation

/// Wire receipt from the pinned reference engine. It does not attest provider payment.
public struct ProtocolSettlement: Decodable, Equatable, Sendable {
    public struct Line: Decodable, Equatable, Sendable {
        public let candidate: String
        public let product: String
        public let merchant: String
        public let maker: String
        public let ships: String
        public let valence: String
        public let amount: Int64
        public let disputed: Bool
    }
    public let offer: String
    public let settledAt: Int64
    public let keptAmount: Int64
    public let consumedAmount: Int64
    public let lostAmount: Int64
    public let charged: Int64
    public let disputedAmount: Int64
    public let lines: [Line]
    public let payer: String
    public let signedBy: String
    public let signedAs: String
    public let receipt: String
    public let confirmation: String?

    private enum CodingKeys: String, CodingKey {
        case offer, charged, lines, payer, receipt, confirmation
        case settledAt = "settled_at", keptAmount = "kept_amount", consumedAmount = "consumed_amount"
        case lostAmount = "lost_amount", disputedAmount = "disputed_amount"
        case signedBy = "signed_by", signedAs = "signed_as"
    }
}

/// §6.6, question 70. A signed settlement is never rewritten; a reduction is a second,
/// appended record. This is the household's receipt of them: the settlement as it was
/// signed, each correction in the order it arrived, and what remains.
public struct MemberCorrections: Decodable, Equatable, Sendable {
    public struct Original: Decodable, Equatable, Sendable {
        public let charged: Int64
        public let carriage: Int64?
    }
    public struct Correction: Decodable, Equatable, Sendable {
        public let id: String
        public let offer: String
        public let merchant: String
        /// Whole units by which what the household pays is lowered. A correction only lowers.
        public let amount: Int64
        public let kind: String
        /// The merchant's own words, shown to the household as written and never as markup.
        public let note: String
        public let correctedAt: Int64
        public let signature: String
        private enum CodingKeys: String, CodingKey {
            case id, offer, merchant, amount, kind, note, signature
            case correctedAt = "corrected_at"
        }
    }
    public let offer: String
    public let original: Original
    public let corrections: [Correction]
    public let net: Int64
}

/// None of these failures proves that a preceding write had no effect.
public enum ReferenceReadFailure: Error, Equatable, Sendable {
    case protocolRefusal(status: Int, code: String)
    case unexpectedHTTP(status: Int)
    case malformedResponse
    case mismatchedResource
    case inconsistentSettlement
    case inconsistentMandate
}

/// Decodes an already received GET /offers/{id}/settlement response.
/// No transport, session, write, retry or payment-status inference is implemented here.
public enum ReferenceResponseReader {
    public static func settlement(status: Int, contentType: String?, data: Data, expectedOffer: String) throws -> ProtocolSettlement {
        let body = try responseObject(status: status, contentType: contentType, data: data)
        let value: ProtocolSettlement
        do {
            // Fail closed for this pinned contract; widening belongs to a tested revision.
            guard Set(body.keys) == Set(["offer", "settled_at", "kept_amount", "consumed_amount", "lost_amount", "charged", "disputed_amount", "lines", "payer", "signed_by", "signed_as", "receipt", "confirmation"]),
                  let lines = body["lines"] as? [[String: Any]],
                  lines.allSatisfy({ Set($0.keys) == Set(["candidate", "product", "merchant", "maker", "ships", "valence", "amount", "disputed"]) })
            else { throw ReferenceReadFailure.malformedResponse }
            value = try JSONDecoder().decode(ProtocolSettlement.self, from: data)
        } catch { throw ReferenceReadFailure.malformedResponse }
        guard !expectedOffer.isEmpty, Data(value.offer.utf8) == Data(expectedOffer.utf8) else { throw ReferenceReadFailure.mismatchedResource }
        try validate(value)
        return value
    }

    /// §6.6, question 70. Decodes an already received GET /offers/{id}/corrections response.
    /// A caller that finds this route absent (a settlement with nothing corrected, or an
    /// engine before question 70) reads that as "nothing to show", never as a reason to
    /// hide the settlement it stands beside.
    public static func corrections(status: Int, contentType: String?, data: Data, expectedOffer: String) throws -> MemberCorrections {
        let body = try responseObject(status: status, contentType: contentType, data: data)
        let value: MemberCorrections
        do {
            guard Set(body.keys) == Set(["offer", "original", "corrections", "net"]),
                  let original = body["original"] as? [String: Any], Set(original.keys) == Set(["charged", "carriage"]),
                  let rows = body["corrections"] as? [[String: Any]],
                  rows.allSatisfy({ Set($0.keys) == Set(["id", "offer", "merchant", "amount", "kind", "note", "corrected_at", "signature"]) })
            else { throw ReferenceReadFailure.malformedResponse }
            value = try JSONDecoder().decode(MemberCorrections.self, from: data)
        } catch { throw ReferenceReadFailure.malformedResponse }
        guard !expectedOffer.isEmpty, Data(value.offer.utf8) == Data(expectedOffer.utf8) else { throw ReferenceReadFailure.mismatchedResource }
        try validateCorrections(value)
        return value
    }

    /// A mandate read may be lapsed; reading it does not authorise a change.
    public static func mandate(status: Int, contentType: String?, data: Data, expectedID: String, expectedHousehold: String, minimumVersion: Int64 = 1) throws -> Mandate {
        let body = try responseObject(status: status, contentType: contentType, data: data)
        guard Set(body.keys) == Set(["id", "household", "ceiling_out_of_network", "ceiling_daily", "cooling_seconds", "co_signers", "lapses_at", "version"]) else { throw ReferenceReadFailure.malformedResponse }
        let value: Mandate
        do {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            value = try decoder.decode(Mandate.self, from: data)
        } catch { throw ReferenceReadFailure.malformedResponse }
        guard !expectedID.isEmpty, !expectedHousehold.isEmpty,
              Data(value.id.utf8) == Data(expectedID.utf8), Data(value.household.utf8) == Data(expectedHousehold.utf8)
        else { throw ReferenceReadFailure.mismatchedResource }
        guard minimumVersion >= 1, value.version >= minimumVersion, value.coSigners.allSatisfy({ !$0.isEmpty }) else { throw ReferenceReadFailure.inconsistentMandate }
        do { try Canonical.validateMandate(value) } catch { throw ReferenceReadFailure.inconsistentMandate }
        return value
    }

    private static func responseObject(status: Int, contentType: String?, data: Data) throws -> [String: Any] {
        guard isJSON(contentType) else { throw ReferenceReadFailure.unexpectedHTTP(status: status) }
        if status != 200 {
            // Preserve future protocol codes. Do not display the server message, which
            // may include identifiers or internal diagnostics. A proxy body is not a refusal.
            if (400...599).contains(status),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               Set(body.keys) == Set(["error", "message"]),
               let code = body["error"] as? String, !code.isEmpty,
               body["message"] is String {
                throw ReferenceReadFailure.protocolRefusal(status: status, code: code)
            }
            throw ReferenceReadFailure.unexpectedHTTP(status: status)
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReferenceReadFailure.malformedResponse }
        return body
    }

    private static func isJSON(_ type: String?) -> Bool {
        type?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json"
    }
    private static func validate(_ value: ProtocolSettlement) throws {
        let amounts = [value.settledAt, value.keptAmount, value.consumedAmount, value.lostAmount, value.charged, value.disputedAmount] + value.lines.map(\.amount)
        guard amounts.allSatisfy({ (0...Canonical.maximumInteger).contains($0) }),
              value.signedAs == "agent", !value.receipt.isEmpty,
              Set(value.lines.map { Data($0.candidate.utf8) }).count == value.lines.count
        else { throw ReferenceReadFailure.inconsistentSettlement }
        var kept: Int64 = 0, consumed: Int64 = 0, lost: Int64 = 0, disputed: Int64 = 0
        func add(_ total: inout Int64, _ amount: Int64) throws {
            guard total <= Canonical.maximumInteger - amount else { throw ReferenceReadFailure.inconsistentSettlement }
            total += amount
        }
        for line in value.lines {
            // Question 46: a disputed missing line stays in the stock-loss total and adds nothing to the disputed amount.
            guard !line.candidate.isEmpty, !line.disputed || ["consumed", "lost"].contains(line.valence) else { throw ReferenceReadFailure.inconsistentSettlement }
            switch line.valence {
            case "kept", "defaulted": try add(&kept, line.amount)
            case "consumed": if line.disputed { try add(&disputed, line.amount) } else { try add(&consumed, line.amount) }
            case "lost": try add(&lost, line.amount)
            default: throw ReferenceReadFailure.inconsistentSettlement
            }
        }
        var goods = kept; try add(&goods, consumed)
        guard value.keptAmount == kept, value.consumedAmount == consumed,
              value.disputedAmount == disputed, value.lostAmount == lost, value.charged == goods
        else { throw ReferenceReadFailure.inconsistentSettlement }
        // Carriage is absent from this projection. Do not add it to `charged` or
        // infer a complete payable total, currency, verified authority or provider state.
    }
    /// §6.6. `net` is `original.charged + (original.carriage ?? 0) - sum(amounts)`, checked
    /// rather than trusted: a receipt whose arithmetic does not close is not one this screen
    /// can show as the household's total.
    private static func validateCorrections(_ value: MemberCorrections) throws {
        var amounts = [value.original.charged, value.net] + value.corrections.map(\.amount)
        if let carriage = value.original.carriage { amounts.append(carriage) }
        guard amounts.allSatisfy({ (0...Canonical.maximumInteger).contains($0) }), !value.offer.isEmpty else {
            throw ReferenceReadFailure.inconsistentSettlement
        }
        var ids = Set<Data>(), sum: Int64 = 0
        for c in value.corrections {
            guard c.amount >= 1, !c.id.isEmpty, !c.merchant.isEmpty, ["refund", "collection"].contains(c.kind),
                  c.note.count <= 500, Data(c.offer.utf8) == Data(value.offer.utf8), c.correctedAt >= 0,
                  ids.insert(Data(c.id.utf8)).inserted
            else { throw ReferenceReadFailure.inconsistentSettlement }
            guard sum <= Canonical.maximumInteger - c.amount else { throw ReferenceReadFailure.inconsistentSettlement }
            sum += c.amount
        }
        let base = value.original.charged + (value.original.carriage ?? 0)
        guard base >= 0, base <= Canonical.maximumInteger, sum <= base, base - sum == value.net else {
            throw ReferenceReadFailure.inconsistentSettlement
        }
    }
}
