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

/// None of these failures proves that a preceding write had no effect.
public enum ReferenceReadFailure: Error, Equatable, Sendable {
    case protocolRefusal(status: Int, code: String)
    case unexpectedHTTP(status: Int)
    case malformedResponse
    case mismatchedResource
    case inconsistentSettlement
}

/// Decodes an already received GET /offers/{id}/settlement response.
/// No transport, session, write, retry or payment-status inference is implemented here.
public enum ReferenceResponseReader {
    public static func settlement(status: Int, contentType: String?, data: Data, expectedOffer: String) throws -> ProtocolSettlement {
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
        let value: ProtocolSettlement
        do {
            // Fail closed for this pinned contract; widening belongs to a tested revision.
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(body.keys) == Set(["offer", "settled_at", "kept_amount", "consumed_amount", "lost_amount", "charged", "disputed_amount", "lines", "payer", "signed_by", "signed_as", "receipt", "confirmation"]),
                  let lines = body["lines"] as? [[String: Any]],
                  lines.allSatisfy({ Set($0.keys) == Set(["candidate", "product", "merchant", "maker", "ships", "valence", "amount", "disputed"]) })
            else { throw ReferenceReadFailure.malformedResponse }
            value = try JSONDecoder().decode(ProtocolSettlement.self, from: data)
        } catch { throw ReferenceReadFailure.malformedResponse }
        guard !expectedOffer.isEmpty, Data(value.offer.utf8) == Data(expectedOffer.utf8) else { throw ReferenceReadFailure.mismatchedResource }
        try validate(value)
        return value
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
            guard !line.candidate.isEmpty, !line.disputed || line.valence == "consumed" else { throw ReferenceReadFailure.inconsistentSettlement }
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
}
