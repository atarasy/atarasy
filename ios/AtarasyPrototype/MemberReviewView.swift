import SwiftUI
import AtarasyCore

struct MemberReviewSections: View {
    /// Where a line is `lost` but the screen cannot tell a collection's missing record from a
    /// deadline loss (the offer and settlement reads carry no marker), so it names both. The same
    /// words are on the web hub's approval screen (`src/client/app.ts`).
    static let lostOutcome = "Not returned: the collection did not find it in the box, or it was not collected by the deadline. Never charged to you."
    let review: MemberReview
    var body: some View {
        Section("Read-only review") {
            Text("These refreshed records were read separately. They are not a signed agreement or a payment result.").font(.footnote)
            Text("Currency was not supplied. All amounts are in the merchant's supplied units.").font(.footnote)
        }
        switch review {
        case .approval(let approval):
            Section("Before deciding") {
                carriage(approval.carriage)
                Text("Reminder sent: \(approval.reminded ? "Yes" : "No")")
                Text("Mandate: \(approval.mandate.kind)")
                Text("Scope: \(approval.mandate.scope)")
                if let expiry = approval.mandate.lapsesAt { Text("Mandate lapses: \(date(expiry))") }
                else { Text("No mandate lapse time supplied.") }
                Text("Proposal expiry: \(date(approval.expiresAt))")
                if let band = approval.priceBand { Text("Gift price band: \(band.min)–\(band.max)") }
            }
            ForEach(Array(approval.candidates.enumerated()), id: \.offset) { _, candidate in
                Section("Review: \(candidate.product)") {
                    parties(candidate.merchant, candidate.maker, candidate.ships)
                    Text("Quantity: \(candidate.quantity); catalogue unit price: \(candidate.unitPrice)")
                    gift(candidate.givenBy)
                    Text("Choice status: \(candidate.valence)")
                    Text("Exploratory proposal: \(candidate.isExploration ? "Yes" : "No")")
                    Text("Alternatives").font(.headline)
                    ForEach(Array(candidate.alternatives.enumerated()), id: \.offset) { _, alternative in Text(verbatim: alternative) }
                    Text("Argument against").font(.headline)
                    Text(verbatim: candidate.argumentAgainst).accessibilityIdentifier("reviewArgumentAgainst")
                    disclosures(approval.disclosures, merchant: candidate.merchant, product: candidate.product)
                }
            }
            Section("Excluded products") {
                if approval.excluded.isEmpty { Text("No excluded products were reported.") }
                ForEach(Array(approval.excluded.enumerated()), id: \.offset) { _, item in Text("\(item.product): \(item.reason)").accessibilityIdentifier("reviewExclusion") }
            }
        case .settlement(let settlement):
            Section("Settlement") {
                Text("This box has settled. There is nothing left to sign.").accessibilityIdentifier("settledBox")
                Text("Settled: \(date(settlement.settledAt))")
                Text("Goods charged: \(settlement.charged)").accessibilityIdentifier("settledGoodsCharged")
                if settlement.disputedAmount > 0 { Text("Disputed and not charged here: \(settlement.disputedAmount)") }
                Text("This record does not confirm provider payment.").font(.footnote)
            }
            ForEach(Array(settlement.lines.enumerated()), id: \.offset) { _, line in
                Section("Settled: \(line.product)") {
                    parties(line.merchant, line.maker, line.ships)
                    if line.valence == "lost" { Text(MemberReviewSections.lostOutcome) }
                    else { Text("Outcome: \(line.valence); goods amount: \(line.amount)") }
                    if line.disputed { Text(line.valence == "lost" ? "Disputed: you said it was in the box." : "Disputed: excluded from the goods charge.") }
                }
            }
        case .statement(let statement):
            Section("Physical statement") {
                carriage(statement.carriage)
                Text("Collection due: \(date(statement.expiresAt))")
                Text("Only kept, defaulted and consumed lines, and lines the collection recorded missing, appear here. Omission does not establish completed collection.").font(.footnote)
                Text("The statement challenge matches these reported lines. This does not verify disclosure signatures or authorise a charge.").font(.footnote)
                if statement.lines.isEmpty { Text("No eligible statement lines were reported.") }
            }
            ForEach(Array(statement.lines.enumerated()), id: \.offset) { _, line in
                Section("Statement: \(line.product)") {
                    parties(line.merchant, line.maker, line.ships)
                    Text(line.valence == "lost" ? "Reported outcome: not in the box. Never charged to you." : "Reported outcome: \(line.valence)")
                    if let note = line.note { Text(verbatim: note).font(.footnote) }
                    Text("Quantity: \(line.quantity); catalogue unit price: \(line.unitPrice)")
                    gift(line.givenBy)
                    Text("Proposed goods amount: \(line.amount)").accessibilityIdentifier(line.givenBy == nil ? "reviewGoodsAmount" : "reviewGiftAmount")
                    disclosures(statement.disclosures, merchant: line.merchant, product: line.product)
                }
            }
        }
    }
    private func date(_ value: Int64) -> String { Date(timeIntervalSince1970: Double(value) / 1000).formatted() }
    @ViewBuilder private func carriage(_ value: Int64?) -> some View {
        if let value { Text("Carriage: \(value)").accessibilityIdentifier("reviewCarriage") }
        else { Text("Carriage is unknown. A complete charge cannot be reviewed.").accessibilityIdentifier("reviewCarriageUnknown") }
    }
    @ViewBuilder private func parties(_ merchant: String, _ maker: String, _ ships: String) -> some View {
        Text("Merchant: \(merchant)"); Text("Maker: \(maker)"); Text("Carrier: \(ships)")
    }
    @ViewBuilder private func gift(_ giver: String?) -> some View {
        if let giver { Text("Gift from \(giver). No goods charge to the recipient.") }
    }
    @ViewBuilder private func disclosures(_ blocks: [MemberOfferDetail.Disclosure], merchant: String, product: String) -> some View {
        Text("Merchant disclosures, signatures not independently verified").font(.caption)
        Text("Where a label appears in both blocks, the product text governs that label. Other standing terms still apply.").font(.caption)
        ForEach(Array(blocks.filter { Data($0.merchant.utf8) == Data(merchant.utf8) && ($0.product == nil || Data($0.product!.utf8) == Data(product.utf8)) }.enumerated()), id: \.offset) { _, block in
            Text(block.product == nil ? "Standing disclosure" : "Product disclosure").font(.headline)
            Text("Version: \(block.version)").font(.caption)
            ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item.label).font(.subheadline)
                Text(verbatim: item.value)
            }
        }
    }
}
