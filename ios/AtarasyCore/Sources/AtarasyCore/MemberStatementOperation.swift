import Foundation

/// Local immutable preparation, not a grant of authority or permission to send.
public struct PreparedMemberStatement: Sendable {
    public let environment: MemberEnvironment
    public let sessionID: String
    public let household: String
    public let presenter: String
    public let offer: String
    public let canonical: String
    public let challenge: String
    public let goodsCharged: Int64
    public let disputedGoods: Int64
    public let carriage: Int64
    public let disputed: [String]
    fileprivate let sessionExpiresAt: Int64
    fileprivate let expected: [ExpectedStatementReceiptLine]
    fileprivate let lostGoods: Int64
    fileprivate let keptGoods: Int64
    fileprivate let consumedGoods: Int64

    public init(environment: MemberEnvironment, session: MemberSessionInfo, detail: MemberOfferDetail, statement: MemberStatement, disputed: [String], now: Int64) throws {
        guard now >= 0, session.expiresAt > now, session.expiresAt <= Canonical.maximumInteger, !session.id.isEmpty else { throw MemberFailure.expired }
        guard exact(session.household, detail.household), session.presenters.contains(where: { exact($0, detail.presenter) }),
              exact(statement.offer, detail.id), exact(statement.household, detail.household), statement.expiresAt == detail.expiresAt else { throw MemberFailure.scopeMismatch }
        guard detail.binding == "physical", detail.giver == nil, ["decided", "expired"].contains(detail.state),
              !detail.candidates.contains(where: { $0.valence == "offered" }),
              // Question 46: goods used, or a line the collection recorded missing, make a statement to sign.
              detail.candidates.contains(where: { $0.valence == "consumed" }) || statement.lines.contains(where: { $0.valence == "lost" }),
              let carriage = statement.carriage, (0...Canonical.maximumInteger).contains(carriage),
              disclosureBytes(detail.disclosures) == disclosureBytes(statement.disclosures) else { throw MemberFailure.invalidInput }
        let disputeIDs = Set(disputed.map { Data($0.utf8) })
        let missing = statement.lines.filter { $0.valence == "lost" }
        guard disputeIDs.count == disputed.count, disputed.allSatisfy({ id in
            detail.candidates.contains { exact($0.id, id) && $0.valence == "consumed" } || missing.contains { exact($0.candidate, id) }
        }) else { throw MemberFailure.invalidInput }
        var expected: [ExpectedStatementReceiptLine] = [], canonicalLines: [StatementLine] = []
        var kept: Int64 = 0, consumed: Int64 = 0, contested: Int64 = 0, lost: Int64 = 0
        for candidate in detail.candidates {
            guard candidate.valence != "returned" else { continue }
            let product = candidate.quantity.multipliedReportingOverflow(by: candidate.unitPrice)
            let gifted = candidate.givenBy != nil && candidate.valence != "lost"
            guard gifted || (!product.overflow && (0...Canonical.maximumInteger).contains(product.partialValue)) else { throw MemberFailure.malformed }
            let amount = gifted ? 0 : product.partialValue
            let isDisputed = disputeIDs.contains(Data(candidate.id.utf8))
            expected.append(.init(candidate: candidate, amount: amount, disputed: isDisputed))
            switch candidate.valence {
            case "lost": try checkedAdd(&lost, amount)
            case "kept", "defaulted": try checkedAdd(&kept, amount)
            case "consumed": if isDisputed { try checkedAdd(&contested, amount) } else { try checkedAdd(&consumed, amount) }
            default: throw MemberFailure.malformed
            }
            if candidate.valence == "lost" {
                // A missing record is signed at 0; a deadline loss is not on the statement at all.
                if let line = statement.lines.first(where: { exact($0.candidate, candidate.id) }) {
                    guard exact(line.valence, "lost"), line.amount == 0 else { throw MemberFailure.malformed }
                    canonicalLines.append(.init(candidate: candidate.id, valence: "lost", amount: 0, disputed: isDisputed))
                }
            } else {
                guard let line = statement.lines.first(where: { exact($0.candidate, candidate.id) }),
                      exact(line.product, candidate.product), exact(line.merchant, candidate.merchant), exact(line.maker, candidate.maker), exact(line.ships, candidate.ships),
                      optionalExact(line.givenBy, candidate.givenBy), line.quantity == candidate.quantity, line.unitPrice == candidate.unitPrice,
                      exact(line.valence, candidate.valence), line.amount == amount else { throw MemberFailure.malformed }
                canonicalLines.append(.init(candidate: candidate.id, valence: candidate.valence, amount: amount, disputed: isDisputed))
            }
        }
        guard statement.lines.count == canonicalLines.count else { throw MemberFailure.malformed }
        let unsigned = canonicalLines.map { StatementLine(candidate: $0.candidate, valence: $0.valence, amount: $0.amount, disputed: false) }
        guard exact(statement.challenge, Canonical.challenge(try Canonical.statement(offer: detail.id, carriage: carriage, lines: unsigned))) else { throw MemberFailure.malformed }
        canonical = try Canonical.statement(offer: detail.id, carriage: carriage, lines: canonicalLines)
        challenge = Canonical.challenge(canonical)
        var charged = kept; try checkedAdd(&charged, consumed)
        self.environment = environment; sessionID = session.id; sessionExpiresAt = session.expiresAt
        household = detail.household; presenter = detail.presenter; offer = detail.id
        self.carriage = carriage; self.disputed = disputed; self.expected = expected
        goodsCharged = charged; disputedGoods = contested; lostGoods = lost; keptGoods = kept; consumedGoods = consumed
    }
}

/// In-memory evidence of an attempted submission. It neither sends nor verifies an
/// assertion. The future dispatcher must persist its own operation before effects.
public struct PendingMemberStatement: Sendable {
    public let prepared: PreparedMemberStatement
    public let confirmationFingerprint: String
    public init(prepared: PreparedMemberStatement, submittedSignature: String) throws {
        guard !submittedSignature.isEmpty, submittedSignature.utf8.count <= 16_384,
              let bytes = Data(base64Encoded: submittedSignature), !bytes.isEmpty,
              bytes.base64EncodedString() == submittedSignature else { throw MemberFailure.invalidInput }
        self.prepared = prepared
        confirmationFingerprint = Canonical.digest(submittedSignature)
    }
    func permits(environment: MemberEnvironment, session: MemberSessionInfo, now: Int64) -> Bool {
        exact(environment.name, prepared.environment.name) && environment.origin == prepared.environment.origin &&
        exact(session.id, prepared.sessionID) && exact(session.household, prepared.household) &&
        session.presenters.contains { exact($0, prepared.presenter) } && now >= 0 &&
        now < session.expiresAt && now < prepared.sessionExpiresAt
    }
    public func inspect(_ receipt: ProtocolSettlement) -> MemberStatementReadback {
        guard exact(receipt.offer, prepared.offer), exact(receipt.payer, prepared.household), exact(receipt.signedBy, prepared.presenter), receipt.signedAs == "agent" else { return .inconsistentRecord }
        guard let confirmation = receipt.confirmation, exact(Canonical.digest(confirmation), confirmationFingerprint) else { return .differentConfirmation }
        guard receipt.lines.count == prepared.expected.count, Set(receipt.lines.map { Data($0.candidate.utf8) }).count == receipt.lines.count,
              receipt.charged == prepared.goodsCharged, receipt.disputedAmount == prepared.disputedGoods,
              receipt.lostAmount == prepared.lostGoods, receipt.keptAmount == prepared.keptGoods, receipt.consumedAmount == prepared.consumedGoods,
              prepared.expected.allSatisfy({ expected in receipt.lines.contains { expected.matches($0) } }) else { return .inconsistentRecord }
        return .matchingProtocolRecord(receipt)
    }
}
public enum MemberStatementReadback: Equatable, Sendable {
    /// Confirms matching reference-engine evidence only, never provider payment.
    case matchingProtocolRecord(ProtocolSettlement)
    case differentConfirmation, inconsistentRecord, unresolved, sessionUnavailable
}
fileprivate struct ExpectedStatementReceiptLine: Sendable {
    let candidate: MemberOfferDetail.Candidate; let amount: Int64; let disputed: Bool
    func matches(_ line: ProtocolSettlement.Line) -> Bool {
        exact(candidate.id, line.candidate) && exact(candidate.product, line.product) && exact(candidate.merchant, line.merchant) &&
        exact(candidate.maker, line.maker) && exact(candidate.ships, line.ships) && exact(candidate.valence, line.valence) && amount == line.amount && disputed == line.disputed
    }
}
private func exact(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
private func optionalExact(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) { case (.none, .none): return true; case let (.some(a), .some(b)): return exact(a, b); default: return false }
}
private func checkedAdd(_ total: inout Int64, _ amount: Int64) throws {
    guard amount >= 0, total <= Canonical.maximumInteger - amount else { throw MemberFailure.malformed }; total += amount
}
private func disclosureBytes(_ blocks: [MemberOfferDetail.Disclosure]) -> Data {
    // Length-safe structured encoding avoids delimiter and Unicode-equality ambiguity.
    let values: [[String?]] = blocks.map { [$0.merchant, $0.product, $0.version, $0.signature] + $0.items.flatMap { [$0.label, $0.value] } }
    return (try? JSONEncoder().encode(values)) ?? Data()
}
