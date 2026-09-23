import SwiftUI
import AtarasyCore

/// A box in the home (`22` UX-04, UX-05). The collection records what happened to each line;
/// the member confirms that record or says a line is wrong, and never picks "used" themselves
/// (§11.2). Ignoring this screen is not the same as saying no, because the goods may already
/// have been used, so the screen says what waiting does instead (COPY-03).
struct MemberBoxView: View {
    let detail: MemberOfferDetail
    let statement: MemberStatement
    let flow: MemberStatementFlow?
    let reload: () -> Void
    @State private var disputed = Set<String>()
    /// §6.5: the box can be signed for once the collection has finished with it.
    private var ready: Bool { ["decided", "expired"].contains(detail.state) && !statement.lines.isEmpty }
    private var holdsNextBox: Bool {
        statement.lines.contains { $0.valence == "consumed" } ||
            (statement.lines.contains { $0.valence == "lost" } && statement.lines.contains { ["kept", "defaulted"].contains($0.valence) })
    }
    private var goods: Int64 {
        statement.lines.filter { $0.valence != "lost" && !disputed.contains($0.candidate) }.reduce(Int64(0)) { $0 &+ $1.amount }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemberBoxHeader(detail: detail)
                if ready {
                    if holdsNextBox { MemberBanner(text: String(localized: "This statement has not been signed. The next box is on hold until it is.")).accessibilityIdentifier("unsignedHold") }
                    MemberStatementLines(statement: statement, disputed: $disputed, editable: flow != nil)
                    totals
                    if let flow {
                        if flow.settledOffers.contains(detail.id) {
                            MemberBanner(text: String(localized: "This box has settled."), systemImage: "checkmark.circle", tint: .green).accessibilityIdentifier("statementSettled")
                            Button("Show the settlement", action: reload).buttonStyle(.bordered)
                        } else {
                            NavigationLink { MemberStatementReviewScreen(flow: flow, detail: detail, statement: statement, disputed: Array(disputed)) } label: {
                                Text("Review and sign").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(statement.carriage == nil)
                            .accessibilityIdentifier("openStatementApproval")
                        }
                    }
                } else {
                    MemberBoxContents(detail: detail, showHeader: false)
                }
                MemberTermsSection(blocks: statement.disclosures, collapsed: true)
            }
            .padding()
        }
        .task { await flow?.checkSettled(offerID: detail.id) }
    }
    @ViewBuilder private var totals: some View {
        MemberCard {
            MemberAmountRow(label: "Goods", amount: MemberFormat.money(goods)).accessibilityIdentifier("statementGoods")
            if let carriage = statement.carriage {
                MemberAmountRow(label: "Delivery", amount: MemberFormat.money(carriage)).accessibilityIdentifier("reviewCarriage")
                Divider()
                MemberAmountRow(label: "Goods and delivery", amount: MemberFormat.money(goods &+ carriage), emphasised: true)
            } else {
                // COPY-07.
                Text("Delivery costs have not been recorded. This statement is not ready to sign.").font(.subheadline).accessibilityIdentifier("reviewCarriageUnknown")
            }
            if !disputed.isEmpty { Text("Lines you marked are not charged here. What is owed for them is between you and the shop, under its terms.").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct MemberBoxHeader: View {
    let detail: MemberOfferDetail
    var body: some View {
        MemberCard {
            Text(verbatim: MemberParties.sellers(detail.candidates.map(\.merchant))).font(.title3.bold())
            if detail.state == "presented" {
                Text("Next swap \(MemberFormat.day(detail.expiresAt))").font(.subheadline)
                Text("These goods are already with you. Use what you like; you pay only for what you use, and the rest goes back at the swap.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // §2.2b, §10a.5: the date is on the screen, and it is not the member's deadline.
                Text("It was offered until \(MemberFormat.day(detail.expiresAt)).").font(.subheadline)
                Text("The collection has recorded what was used and what went back.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// The box's lines from the offer itself, for a box the collection has not finished with.
struct MemberBoxContents: View {
    let detail: MemberOfferDetail
    var showHeader = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showHeader { MemberBoxHeader(detail: detail) }
            MemberCard {
                Text("In the box").font(.headline)
                ForEach(detail.candidates, id: \.id) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: c.title)
                            Spacer()
                            if c.givenBy == nil { Text(verbatim: MemberFormat.money(MemberFormat.lineTotal(c.unitPrice, c.quantity))).monospacedDigit().foregroundStyle(.secondary) }
                            else { Text("Free").foregroundStyle(.secondary) }
                        }
                        if let giver = c.givenBy { MemberTag(text: "Gift from \(giver)", systemImage: "gift", tint: .pink).accessibilityIdentifier("detailGift") }
                        Group {
                            if c.valence == "lost" { Text(verbatim: MemberOfferDetail.lostOutcome(c.collectedAs, supplied: detail.collectedAsSupplied == true)) }
                            else { Text(MemberLineStatus.box(c.valence)) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("detailOutcome-" + c.id)
                    }
                    .padding(.vertical, 2)
                }
                Text("Prices are the shop's own. You are charged only for what you use.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

extension MemberLineStatus {
    static func box(_ valence: String) -> LocalizedStringKey {
        switch valence {
        case "offered": return "With you. Not collected yet."
        case "returned": return "Went back at the swap."
        case "consumed": return "Used."
        case "kept": return "You kept this."
        case "defaulted": return "Sent because nothing was chosen."
        default: return "With you."
        }
    }
}

/// The proposed statement, grouped by what the collection recorded. Only a line recorded as
/// used or missing can be marked (COPY-13); a line the member kept was already their own choice.
struct MemberStatementLines: View {
    let statement: MemberStatement
    @Binding var disputed: Set<String>
    let editable: Bool
    private func group(_ valences: [String]) -> [MemberStatement.Line] { statement.lines.filter { valences.contains($0.valence) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            groupCard("Used", lines: group(["consumed"]), note: "The collection found these used. You pay the shop's price, unless it was a gift.")
            groupCard("Kept", lines: group(["kept", "defaulted"]), note: "You chose to keep these.")
            groupCard("Not found in the box", lines: group(["lost"]), note: "Never charged to you. If one was there, say so.")
        }
    }
    @ViewBuilder private func groupCard(_ title: LocalizedStringKey, lines: [MemberStatement.Line], note: LocalizedStringKey) -> some View {
        if !lines.isEmpty {
            MemberCard {
                Text(title).font(.headline)
                Text(note).font(.footnote).foregroundStyle(.secondary)
                ForEach(lines, id: \.candidate) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: line.title).strikethrough(disputed.contains(line.candidate) && line.valence == "consumed")
                            Spacer()
                            amount(line)
                        }
                        Text("Sold by \(line.merchant)").font(.caption).foregroundStyle(.secondary)
                        if line.maker != line.merchant { Text("Made by \(line.maker)").font(.caption).foregroundStyle(.secondary) }
                        if let giver = line.givenBy { MemberTag(text: "Gift from \(giver)", systemImage: "gift", tint: .pink) }
                        if let note = line.note { Text(verbatim: note).font(.caption).foregroundStyle(.secondary) }
                        if editable && (line.valence == "consumed" || line.valence == "lost") {
                            Toggle(isOn: Binding(get: { disputed.contains(line.candidate) }, set: { if $0 { disputed.insert(line.candidate) } else { disputed.remove(line.candidate) } })) {
                                Text(line.valence == "lost" ? "It was in the box" : "This isn't right").font(.subheadline)
                            }
                            .accessibilityIdentifier((line.valence == "lost" ? "disputeMissing-" : "dispute-") + line.candidate)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
    @ViewBuilder private func amount(_ line: MemberStatement.Line) -> some View {
        if line.valence == "lost" { Text("Not charged").foregroundStyle(.secondary) }
        else if line.givenBy != nil { Text("Free").foregroundStyle(.secondary).accessibilityIdentifier("reviewGiftAmount") }
        else { Text(verbatim: MemberFormat.money(line.amount)).monospacedDigit().accessibilityIdentifier("reviewGoodsAmount") }
    }
}

// MARK: - Signing a statement

struct MemberStatementReviewScreen: View {
    @ObservedObject var flow: MemberStatementFlow
    let detail: MemberOfferDetail
    let statement: MemberStatement
    let disputed: [String]
    /// Question 46: what a signature over missing lines attests, beside the button that makes it.
    static let missingAttestation = String(localized: "Signing shows you were told which items the collection did not find. It is not you agreeing they are missing or taking responsibility for them; you are never charged for them, and you can say any of them was there.")
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = flow.result {
                    MemberResultView(result: result, notice: flow.notice, kind: .statement, busy: flow.busy) { if let handle = flow.handle { Task { await flow.check(handle) } } }
                } else if let frozen = flow.review {
                    frozenView(frozen)
                } else if flow.busy {
                    ProgressView("Preparing your statement").frame(maxWidth: .infinity).padding(.top, 40)
                } else if !flow.notice.isEmpty {
                    MemberBanner(text: flow.notice).accessibilityIdentifier("statementFlowNotice")
                    Button("Try again") { Task { await flow.prepare(detail: detail, statement: statement, disputed: disputed) } }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sign this statement")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.closeReview(); await flow.prepare(detail: detail, statement: statement, disputed: disputed) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in flow.checkExpiry() }
        .onDisappear { flow.closeReview() }
    }
    @ViewBuilder private func frozenView(_ frozen: FrozenMemberStatement) -> some View {
        MemberCard {
            Text("Signing confirms what the collection recorded, except the lines you marked, and lets \(MemberParties.sellers(frozen.statement.lines.map(\.merchant))) charge the goods amount below.").font(.subheadline)
        }
        MemberStatementLines(statement: frozen.statement, disputed: .constant(Set(frozen.disputed)), editable: false)
        MemberCard {
            MemberAmountRow(label: "Goods", amount: MemberFormat.money(frozen.goodsCharged)).accessibilityIdentifier("frozenGoodsTotal")
            MemberAmountRow(label: "Delivery", amount: MemberFormat.money(frozen.statement.carriage ?? 0))
            Divider()
            MemberAmountRow(label: "Goods and delivery", amount: MemberFormat.money(frozen.goodsCharged &+ (frozen.statement.carriage ?? 0)), emphasised: true)
            if frozen.disputedAmount > 0 { MemberAmountRow(label: "Marked as not right, not charged here", amount: MemberFormat.money(frozen.disputedAmount)) }
        }
        MemberLimitsLine(mandate: frozen.mandate)
        MemberTermsSection(blocks: frozen.statement.disclosures, collapsed: false)
        if frozen.statement.lines.contains(where: { $0.valence == "lost" }) {
            Text(verbatim: Self.missingAttestation).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("missingAttestation")
        }
        if !flow.notice.isEmpty { MemberBanner(text: flow.notice, systemImage: "info.circle", tint: .blue).accessibilityIdentifier("statementFlowNotice") }
        Button { Task { await flow.approve() } } label: { Label("Sign with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!flow.canApprove)
            .accessibilityIdentifier("approveMemberStatement")
        Text("Face ID or Touch ID confirms it is you. It does not replace reading this screen.").font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Settled box

/// A settled box. The signed settlement is never rewritten; a correction is appended beside it
/// (§6.6) and a returned refund is the shop's to repay off this platform (§6.6a).
struct MemberSettledView: View {
    let detail: MemberOfferDetail
    let settlement: ProtocolSettlement
    let corrections: MemberCorrections?
    let disclosures: [MemberOfferDetail.Disclosure]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemberCard {
                    Label("Settled \(MemberFormat.day(settlement.settledAt))", systemImage: "checkmark.seal").font(.headline).accessibilityIdentifier("settledBox")
                    Text("There is nothing left to sign for this box.").font(.subheadline).foregroundStyle(.secondary)
                }
                MemberCard {
                    ForEach(Array(settlement.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(verbatim: line.title); Spacer(); Text(verbatim: line.valence == "lost" ? String(localized: "Not charged") : MemberFormat.money(line.amount)).monospacedDigit() }
                            Group {
                                if line.valence == "lost" { Text(verbatim: MemberOfferDetail.lostOutcome(nil, supplied: false)) } else { Text(MemberLineStatus.box(line.valence)) }
                            }.font(.caption).foregroundStyle(.secondary)
                            if line.disputed { Text(line.valence == "lost" ? "You said it was in the box." : "You marked this as not right. Not charged here.").font(.caption) }
                        }
                    }
                    Divider()
                    MemberAmountRow(label: "Goods charged", amount: MemberFormat.money(settlement.charged), emphasised: true).accessibilityIdentifier("settledGoodsCharged")
                    if settlement.disputedAmount > 0 { MemberAmountRow(label: "Marked as not right, not charged here", amount: MemberFormat.money(settlement.disputedAmount)) }
                    Text("Payment status is not available here.").font(.footnote).foregroundStyle(.secondary)
                }
                if let corrections, !corrections.corrections.isEmpty {
                    MemberCard {
                        Text("Corrections from the shop").font(.headline)
                        Text("Added by the shop beside the settlement. Nothing here is yours to sign.").font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(corrections.corrections.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(c.kind == "refund" ? "Refund from \(c.merchant)" : "Correction from \(c.merchant)"); Spacer(); Text(verbatim: "−" + MemberFormat.money(c.amount)).monospacedDigit() }
                                Text(verbatim: c.note).font(.caption).foregroundStyle(.secondary)
                            }.accessibilityIdentifier("correctionLine")
                        }
                        Divider()
                        MemberAmountRow(label: "After corrections", amount: MemberFormat.money(corrections.net), emphasised: true).accessibilityIdentifier("settlementNet")
                        if let returns = corrections.returns {
                            ForEach(Array(returns.enumerated()), id: \.offset) { _, r in
                                Text(r.state == "returned" ? "The refund from \(r.merchant) did not reach you. The shop still owes it to you, off this platform." : "\(r.merchant) says it repaid this another way.")
                                    .font(.subheadline).accessibilityIdentifier(r.state == "returned" ? "correctionReturnedLine" : "correctionRepaidLine")
                                Text(verbatim: r.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                MemberTermsSection(blocks: disclosures, collapsed: true)
            }
            .padding()
        }
    }
}
