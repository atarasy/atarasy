import Foundation

/// Unsent choices only. This value grants no authority and performs no network or key operation.
public struct MemberDigitalDraft: Sendable {
    public enum Choice: String, CaseIterable, Sendable { case undecided, keep, decline }
    public struct Summary: Equatable, Sendable {
        public let goods: Int64
        public let carriage: Int64
        public let total: Int64
    }
    public let approval: MemberApproval
    private var choices: [Data: Choice] = [:]

    public init(approval: MemberApproval) { self.approval = approval }
    public func choice(for id: String) -> Choice { choices[Data(id.utf8)] ?? .undecided }
    public mutating func choose(_ choice: Choice, candidate id: String) throws {
        guard approval.candidates.contains(where: { Data($0.id.utf8) == Data(id.utf8) && $0.valence == "offered" }) else { throw ContractError.invalidTransition }
        choices[Data(id.utf8)] = choice
    }
    public mutating func discard() { choices.removeAll() }

    /// Unknown carriage, incomplete choices, expired terms and unsafe arithmetic never become a zero total.
    public func summary(now: Int64) throws -> Summary {
        guard now >= 0, now < approval.expiresAt,
              approval.mandate.lapsesAt.map({ now < $0 }) ?? true,
              !approval.candidates.isEmpty,
              Set(approval.candidates.map { Data($0.id.utf8) }).count == approval.candidates.count,
              let carriage = approval.carriage, (0...Canonical.maximumInteger).contains(carriage) else { throw ContractError.invalidTransition }
        var goods: Int64 = 0
        for candidate in approval.candidates {
            guard candidate.valence == "offered", choice(for: candidate.id) != .undecided,
                  candidate.quantity > 0, candidate.quantity <= Canonical.maximumInteger,
                  (0...Canonical.maximumInteger).contains(candidate.unitPrice) else { throw ContractError.invalidTransition }
            if choice(for: candidate.id) == .keep && candidate.givenBy == nil {
                let amount = candidate.quantity.multipliedReportingOverflow(by: candidate.unitPrice)
                guard !amount.overflow, amount.partialValue <= Canonical.maximumInteger else { throw ContractError.invalidValue }
                let sum = goods.addingReportingOverflow(amount.partialValue)
                guard !sum.overflow, sum.partialValue <= Canonical.maximumInteger else { throw ContractError.invalidValue }
                goods = sum.partialValue
            }
        }
        let total = goods.addingReportingOverflow(carriage)
        guard !total.overflow, total.partialValue <= Canonical.maximumInteger else { throw ContractError.invalidValue }
        return Summary(goods: goods, carriage: carriage, total: total.partialValue)
    }
}
