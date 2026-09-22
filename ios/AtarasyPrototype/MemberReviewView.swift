import SwiftUI
import AtarasyCore

struct MemberReviewSections: View {
    let review: MemberReview
    var digitalDraft: Binding<MemberDigitalDraft?>? = nil
    var frozenDecisions: [Decision]? = nil
    var body: some View {
        Section(frozenDecisions == nil ? "Read-only review" : "Frozen proposal terms") {
            Text(frozenDecisions == nil ? "These refreshed records were read separately. They are not a signed agreement or a payment result." : "These terms and your choices form the prepared review. Nothing has been signed or submitted yet.").font(.footnote)
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
                    if let choice = frozenDecisions?.first(where: { Data($0.candidate.utf8) == Data(candidate.id.utf8) }) {
                        Text(choice.valence == "kept" ? "Your choice: keep for myself" : "Your choice: decline").font(.headline)
                    } else { Text("Choice status: \(candidate.valence)") }
                    Text("Exploratory proposal: \(candidate.isExploration ? "Yes" : "No")")
                    Text("Alternatives").font(.headline)
                    ForEach(Array(candidate.alternatives.enumerated()), id: \.offset) { _, alternative in Text(verbatim: alternative) }
                    Text("Argument against").font(.headline)
                    Text(verbatim: candidate.argumentAgainst).accessibilityIdentifier("reviewArgumentAgainst")
                    disclosures(approval.disclosures, merchant: candidate.merchant, product: candidate.product)
                    if let digitalDraft, digitalDraft.wrappedValue != nil, candidate.valence == "offered" {
                        Picker("Your unsent choice", selection: Binding(
                            get: { digitalDraft.wrappedValue?.choice(for: candidate.id) ?? .undecided },
                            set: { choice in
                                guard var draft = digitalDraft.wrappedValue else { return }
                                do { try draft.choose(choice, candidate: candidate.id); digitalDraft.wrappedValue = draft }
                                catch { digitalDraft.wrappedValue = nil }
                            }
                        )) {
                            Text("Choose").tag(MemberDigitalDraft.Choice.undecided)
                            Text("Keep for myself").tag(MemberDigitalDraft.Choice.keep)
                            Text("Decline").tag(MemberDigitalDraft.Choice.decline)
                        }.accessibilityIdentifier("digitalChoice-" + candidate.id)
                    }
                }
            }
            Section("Excluded products") {
                if approval.excluded.isEmpty { Text("No excluded products were reported.") }
                ForEach(Array(approval.excluded.enumerated()), id: \.offset) { _, item in Text("\(item.product): \(item.reason)").accessibilityIdentifier("reviewExclusion") }
            }
        case .settlement(let settlement, let corrections, let settlementDisclosures):
            Section("Settlement") {
                Text("This box has settled. There is nothing left to sign.").accessibilityIdentifier("settledBox")
                Text("Settled: \(date(settlement.settledAt))")
                Text("Goods charged: \(settlement.charged)").accessibilityIdentifier("settledGoodsCharged")
                if settlement.disputedAmount > 0 { Text("Disputed and not charged here: \(settlement.disputedAmount)") }
                Text("This record does not confirm provider payment.").font(.footnote)
                Text("The settlement above is signed and is never rewritten.").font(.footnote)
            }
            ForEach(Array(settlement.lines.enumerated()), id: \.offset) { _, line in
                Section("Settled: \(line.product)") {
                    parties(line.merchant, line.maker, line.ships)
                    // The settlement read carries no collected_as, so a settled lost line names both kinds.
                    if line.valence == "lost" { Text(MemberOfferDetail.lostOutcome(nil, supplied: false)) }
                    else { Text("Outcome: \(line.valence); goods amount: \(line.amount)") }
                    if line.disputed { Text(line.valence == "lost" ? "Disputed: you said it was in the box." : "Disputed: excluded from the goods charge.") }
                }
            }
            // §6.6, question 70. A correction only ever lowers what was signed, appended
            // beside it rather than rewriting it. There is nothing to sign or dispute here:
            // no refund request, no dispute control, no messaging (clause 54).
            if let corrections, !corrections.corrections.isEmpty {
                Section("Corrections") {
                    Text("The merchant of record has appended these to the settlement above. Nothing here is yours to sign or dispute.").font(.footnote)
                    ForEach(Array(corrections.corrections.enumerated()), id: \.offset) { _, correction in
                        Text("\(correction.kind == "refund" ? "Refund" : "Collection") from \(correction.merchant): -\(correction.amount)")
                            .accessibilityIdentifier("correctionLine")
                        Text(verbatim: correction.note)
                        Text("Corrected: \(date(correction.correctedAt))").font(.footnote)
                    }
                    Text("Net after corrections: \(corrections.net)").accessibilityIdentifier("settlementNet")
                }
                // SPEC §6.6a. A refund the issuer returned, or the shop's own repayment.
                // This platform moved no money either time and moves none now: the shop
                // reaches the household by its own signed contact, or, where it signed
                // none, by the return terms already beside its disclosure. Nothing here
                // is sent to the merchant, and there is no refund action (clause 54).
                if let returns = corrections.returns, !returns.isEmpty {
                    Section("Returns") {
                        ForEach(Array(returns.enumerated()), id: \.offset) { _, ret in
                            if ret.state == "returned" {
                                Text("The refund from \(ret.merchant) did not reach you. The shop still owes it to you, off this platform.")
                                    .accessibilityIdentifier("correctionReturnedLine")
                            } else {
                                Text("\(ret.merchant) reports it repaid this another way.")
                                    .accessibilityIdentifier("correctionRepaidLine")
                            }
                            Text(verbatim: ret.note)
                            merchantContactOrTerms(settlementDisclosures, merchant: ret.merchant)
                        }
                    }
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
            // Question 72. Beside this block's own terms, and only where this
            // merchant signed one.
            if let contact = block.contact {
                if let url = contact.url { Link(contact.value, destination: url) } else { Text(verbatim: contact.value) }
            }
        }
    }
    /// SPEC §6.6a. A correction_return has no product, so the merchant's standing
    /// disclosure (its `product`-less block) is what "its return terms" names.
    /// Where the merchant signed a contact there, that is shown; where it signed none,
    /// the block's own items stand in its place. Nothing is shown for a merchant with
    /// no standing block at all: this hub never invents terms.
    @ViewBuilder private func merchantContactOrTerms(_ blocks: [MemberOfferDetail.Disclosure], merchant: String) -> some View {
        if let block = blocks.first(where: { Data($0.merchant.utf8) == Data(merchant.utf8) && $0.product == nil }) {
            if let contact = block.contact {
                if let url = contact.url { Link(contact.value, destination: url) } else { Text(verbatim: contact.value) }
            } else {
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    Text(verbatim: item.label).font(.subheadline)
                    Text(verbatim: item.value)
                }
            }
        }
    }
}
