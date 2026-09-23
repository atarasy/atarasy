import SwiftUI
import AtarasyCore

/// One offer, opened from the Inbox. The review loads with the screen, so what the member came
/// for is the first thing drawn rather than a button that fetches it (vault `80` F1).
struct MemberOfferScreen: View {
    @ObservedObject var account: MemberAccount
    @ObservedObject var proposals: MemberProposals
    let selected: MemberOfferSummary
    var body: some View {
        Group {
            if proposals.sessionIdentity == nil {
                ContentUnavailableView("You are signed out", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("Sign in again from the Account tab.")).accessibilityIdentifier("detailSessionEnded")
            } else if let detail = proposals.detail, detail.id == selected.id, let review = proposals.review {
                content(detail: detail, review: review)
            } else if proposals.detailLoading || proposals.reviewLoading {
                ProgressView("Opening").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = proposals.detail, detail.id == selected.id, detail.binding == "physical" {
                // A box the collection has not reached has no statement yet; its contents still show.
                ScrollView { MemberBoxContents(detail: detail).padding() }
            } else {
                ContentUnavailableView {
                    Label("Could not open this", systemImage: "wifi.exclamationmark")
                } description: { Text("Nothing was decided or paid. Try again.") } actions: {
                    Button("Try again") { Task { await proposals.loadReview(selected) } }
                }
                .accessibilityIdentifier("detailUnavailable")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(selected.binding == "physical" ? "Box" : "Proposal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await proposals.loadReview(selected) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh").accessibilityIdentifier("refreshMemberDetail") } }
        // Keyed on the offer too, not only the session: on iPad's split Inbox this same screen
        // instance is reused across selections, so a session-only key would never reload.
        .task(id: "\(proposals.sessionIdentity?.uuidString ?? "-")|\(selected.id)") { await proposals.loadReview(selected) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in proposals.checkExpiry() }
    }
    @ViewBuilder private func content(detail: MemberOfferDetail, review: MemberReview) -> some View {
        switch review {
        case .approval(let approval):
            if detail.state == "presented", approval.candidates.contains(where: { $0.valence == "offered" }), let decisions = account.decisions {
                MemberProposalView(detail: detail, approval: approval, decisions: decisions) { Task { await proposals.loadReview(selected) } }
            } else {
                MemberDecidedView(detail: detail, approval: approval, decisions: account.decisions, withdrawals: account.withdrawals)
            }
        case .statement(let statement):
            MemberBoxView(detail: detail, statement: statement, flow: account.statements) { Task { await proposals.loadReview(selected) } }
        case .settlement(let settlement, let corrections, let disclosures):
            MemberSettledView(detail: detail, settlement: settlement, corrections: corrections, disclosures: disclosures)
        }
    }
}

// MARK: - Digital proposal

/// A drafted cart (`22` UX-03). Each open line gets Keep or Decline; nothing is sent until the
/// member signs on the next screen, and leaving sends nothing (`04b` §2.2c).
struct MemberProposalView: View {
    let detail: MemberOfferDetail
    let approval: MemberApproval
    @ObservedObject var decisions: MemberDigitalFlow
    var reload: () -> Void = {}
    @State private var draft: MemberDigitalDraft
    @State private var now = Date()
    init(detail: MemberOfferDetail, approval: MemberApproval, decisions: MemberDigitalFlow, reload: @escaping () -> Void = {}) {
        self.detail = detail; self.approval = approval; self.decisions = decisions; self.reload = reload
        _draft = State(initialValue: MemberDigitalDraft(approval: approval))
    }
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    private var summary: MemberDigitalDraft.Summary? { try? draft.summary(now: nowMs) }
    private var open: [MemberApproval.Candidate] { approval.candidates.filter { $0.valence == "offered" } }
    private var answered: Int { open.filter { draft.choice(for: $0.id) != .undecided }.count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemberCard {
                    Text(verbatim: MemberParties.sellers(approval.candidates.map(\.merchant))).font(.title3.bold())
                    Text("Closes \(MemberFormat.day(approval.expiresAt)).").font(.subheadline)
                    Text("If you do not choose, this proposal closes without a purchase.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(approval.candidates, id: \.id) { candidate in
                    MemberProposalLine(candidate: candidate, choice: Binding(
                        get: { draft.choice(for: candidate.id) },
                        set: { choice in var next = draft; if (try? next.choose(choice, candidate: candidate.id)) != nil { draft = next } }
                    ))
                }
                if !approval.excluded.isEmpty { MemberExcludedView(excluded: approval.excluded) }
                MemberTermsSection(blocks: approval.disclosures, collapsed: true)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary {
                MemberAmountRow(label: "Goods", amount: MemberFormat.money(summary.goods))
                MemberAmountRow(label: "Delivery", amount: MemberFormat.money(summary.carriage))
                MemberAmountRow(label: "Total if you sign", amount: MemberFormat.money(summary.total), emphasised: true).accessibilityIdentifier("digitalDraftTotal")
            } else if approval.carriage == nil {
                Text("Delivery costs have not been recorded. You can choose now and sign once they are.").font(.footnote).accessibilityIdentifier("reviewCarriageUnknown")
            } else {
                Text("Choose Keep or Decline for each item (\(answered) of \(open.count)).").font(.footnote)
            }
            Text("Your choices are not sent until you sign.").font(.caption).foregroundStyle(.secondary)
            NavigationLink { MemberDecisionReviewScreen(flow: decisions, detail: detail, draft: draft, done: reload) } label: {
                Text("Review").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(summary == nil)
            .accessibilityIdentifier("openDigitalDecision")
        }
        .padding()
        .background(.bar)
    }
}

/// Who sells what, said once for the whole offer: one merchant by name, several as a list.
enum MemberParties {
    static func sellers(_ merchants: [String]) -> String {
        var seen = Set<Data>(); let unique = merchants.filter { seen.insert(Data($0.utf8)).inserted }
        return unique.formatted(.list(type: .and))
    }
}

struct MemberProposalLine: View {
    let candidate: MemberApproval.Candidate
    @Binding var choice: MemberDigitalDraft.Choice
    @State private var showingWhy = false
    var body: some View {
        MemberCard {
            if candidate.givenBy == nil {
                MemberWrappingRow {
                    Text(verbatim: candidate.title).font(.headline)
                } trailing: {
                    Text(verbatim: MemberFormat.money(MemberFormat.lineTotal(candidate.unitPrice, candidate.quantity))).font(.headline).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(verbatim: candidate.title).font(.headline)
            }
            MemberLineParties(merchant: candidate.merchant, maker: candidate.maker, quantity: candidate.quantity, unitPrice: candidate.givenBy == nil ? candidate.unitPrice : nil)
            HStack(spacing: 6) {
                if let giver = candidate.givenBy { MemberTag(text: "Gift from \(giver)", systemImage: "gift", tint: .pink).accessibilityIdentifier("detailGift") }
                if candidate.isExploration { MemberTag(text: "New to you", systemImage: "sparkles", tint: .blue) }
            }
            if candidate.givenBy != nil { Text("No goods charge to you for this item.").font(.footnote).foregroundStyle(.secondary) }
            if candidate.valence == "offered" {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        choiceButton(.keep, "Keep", "checkmark")
                        choiceButton(.decline, "Decline", "xmark")
                    }
                    VStack(spacing: 10) {
                        choiceButton(.keep, "Keep", "checkmark")
                        choiceButton(.decline, "Decline", "xmark")
                    }
                }
            } else {
                Text(MemberLineStatus.resolved(candidate.valence)).font(.subheadline).foregroundStyle(.secondary)
            }
            DisclosureGroup("Why this, and why not", isExpanded: $showingWhy) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alternatives").font(.subheadline.bold())
                    ForEach(Array(candidate.alternatives.enumerated()), id: \.offset) { _, alternative in Text(verbatim: "・" + alternative).font(.subheadline) }
                    Text("The case against").font(.subheadline.bold()).padding(.top, 4)
                    Text(verbatim: candidate.argumentAgainst).font(.subheadline).accessibilityIdentifier("reviewArgumentAgainst")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            .font(.subheadline)
        }
    }
    private func choiceButton(_ value: MemberDigitalDraft.Choice, _ label: LocalizedStringKey, _ image: String) -> some View {
        let selected = choice == value
        return Button { choice = selected ? .undecided : value } label: {
            Label(label, systemImage: image).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(selected ? (value == .keep ? .green : .gray) : .secondary)
        .background(selected ? (value == .keep ? Color.green.opacity(0.15) : Color.gray.opacity(0.18)) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier((value == .keep ? "keep-" : "decline-") + candidate.id)
    }
}

/// Seller, maker (where different) and unit price for one line.
struct MemberLineParties: View {
    let merchant: String
    let maker: String
    let quantity: Int64
    let unitPrice: Int64?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sold by \(merchant)").font(.subheadline).foregroundStyle(.secondary)
            if maker != merchant { Text("Made by \(maker)").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("detailMaker") }
            if let unitPrice, quantity > 1 { Text("\(quantity) × \(MemberFormat.money(unitPrice))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

enum MemberLineStatus {
    static func resolved(_ valence: String) -> LocalizedStringKey {
        switch valence {
        case "kept": return "You kept this."
        case "returned": return "Declined."
        case "consumed": return "Used."
        case "defaulted": return "Sent because nothing was chosen."
        case "lost": return "Not returned. You are never charged for it."
        default: return "Waiting for your choice."
        }
    }
}

/// `SPEC.md` §10: the rules a proposal left out, and why. The reason is one of the published rules.
struct MemberExcludedView: View {
    let excluded: [MemberApproval.Excluded]
    var body: some View {
        MemberCard {
            Text("Left out by your agent").font(.headline)
            Text("Your agent does not propose these, and says why.").font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(excluded.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: item.product).font(.subheadline)
                    Spacer()
                    Text(Self.reason(item.reason)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }.accessibilityIdentifier("reviewExclusion")
            }
        }
    }
    static func reason(_ code: String) -> LocalizedStringKey {
        switch code {
        case "auto_renewal": return "Renews automatically"
        case "obstructed_cancellation": return "Hard to cancel"
        case "manufactured_scarcity": return "Uses scarcity pressure"
        case "late_price": return "Price shown too late"
        case "outside_mandate": return "Outside your limits"
        case "declined_before": return "You declined it before"
        default: return "Excluded"
        }
    }
}

// MARK: - Merchant terms

/// `SPEC.md` §10a. Each merchant's signed text, as composed: never summarised, reordered or
/// translated. Collapsed per merchant while browsing, drawn open on a signing screen (vault `80` D-7).
struct MemberTermsSection: View {
    let blocks: [MemberOfferDetail.Disclosure]
    let collapsed: Bool
    private var merchants: [String] {
        var seen = Set<Data>(); return blocks.map(\.merchant).filter { seen.insert(Data($0.utf8)).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shop terms").font(.headline)
            Text("Written and signed by each shop. Shown exactly as the shop wrote it.").font(.footnote).foregroundStyle(.secondary)
            ForEach(merchants, id: \.self) { merchant in
                MemberCard {
                    if collapsed {
                        DisclosureGroup { blocksView(merchant) } label: { Text("Terms from \(merchant)").font(.subheadline.bold()) }
                    } else {
                        Text("Terms from \(merchant)").font(.subheadline.bold())
                        blocksView(merchant)
                    }
                }
            }
        }
        .accessibilityIdentifier("merchantTerms")
    }
    @ViewBuilder private func blocksView(_ merchant: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.filter { $0.merchant == merchant }.enumerated()), id: \.offset) { _, block in
                if let product = block.product { Text("For \(product) only").font(.caption.bold()).foregroundStyle(.secondary) }
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.label).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: item.value).font(.subheadline)
                    }
                }
                // Question 72. Only where this merchant signed one; tapping is the member's own act.
                if let contact = block.contact {
                    if let url = contact.url { Link(destination: url) { Label { Text(verbatim: contact.value) } icon: { Image(systemName: "envelope") } }.font(.subheadline) }
                    else { Text(verbatim: contact.value).font(.subheadline) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, collapsed ? 6 : 0)
    }
}

// MARK: - Signing a decision

/// `22` UX-06 for a decision. Opening the screen prepares the fixed review; the passkey sheet
/// is the one tap (`04b` §2.2c), and the member reads what it covers before making it.
struct MemberDecisionReviewScreen: View {
    @ObservedObject var flow: MemberDigitalFlow
    let detail: MemberOfferDetail
    let draft: MemberDigitalDraft
    var done: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    /// What the passkey was asked to sign, kept for the result: the review itself is cleared when it is sent.
    @State private var signed: FrozenMemberDecision?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = flow.result {
                    MemberResultView(result: result, notice: flow.notice, kind: .decision, busy: flow.busy) { if let handle = flow.handle { Task { await flow.check(handle) } } }
                    if let signed { MemberSignedDecision(frozen: signed) }
                    if result != .unknown && result != .pending {
                        Button { dismiss(); done() } label: { Text("Done").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("resultDone")
                    }
                } else if let frozen = flow.review {
                    frozenView(frozen)
                } else if flow.busy {
                    ProgressView("Preparing your review").frame(maxWidth: .infinity).padding(.top, 40)
                } else if !flow.notice.isEmpty {
                    MemberBanner(text: flow.notice).accessibilityIdentifier("digitalFlowNotice")
                    Button("Try again") { Task { await flow.prepare(detail: detail, draft: draft) } }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sign this decision")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.closeReview(); await flow.prepare(detail: detail, draft: draft) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in flow.checkExpiry() }
        .onDisappear { flow.closeReview() }
    }
    @ViewBuilder private func frozenView(_ frozen: FrozenMemberDecision) -> some View {
        let kept = frozen.decisions.filter { $0.valence == "kept" }.map(\.candidate)
        let candidates = frozen.approval.candidates
        MemberCard {
            Text("Signing buys the items you keep, from the shops named, at the prices shown. The items you decline are declined, and nothing else is bought.").font(.subheadline)
        }
        MemberCard {
            Text("You keep").font(.headline)
            ForEach(candidates.filter { kept.contains($0.id) }, id: \.id) { c in
                MemberWrappingRow {
                    Text(verbatim: c.title)
                } trailing: {
                    Text(verbatim: c.givenBy == nil ? MemberFormat.money(MemberFormat.lineTotal(c.unitPrice, c.quantity)) : String(localized: "Free")).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Text("Sold by \(c.merchant)").font(.caption).foregroundStyle(.secondary)
            }
            if kept.isEmpty { Text("Nothing. You decline every item.").foregroundStyle(.secondary) }
            let declined = candidates.filter { c in c.valence == "offered" && !kept.contains(c.id) }
            if !declined.isEmpty {
                Divider()
                Text("You decline").font(.headline)
                ForEach(declined, id: \.id) { c in Text(verbatim: c.title).foregroundStyle(.secondary) }
            }
        }
        MemberCard {
            MemberAmountRow(label: "Goods", amount: MemberFormat.money(frozen.goods))
            MemberAmountRow(label: "Delivery", amount: MemberFormat.money(frozen.carriage))
            Divider()
            MemberAmountRow(label: "Total", amount: MemberFormat.money(frozen.total), emphasised: true).accessibilityIdentifier("frozenDigitalTotal")
            Text("The shop takes payment through its own checkout. This signature is your decision, not a payment.").font(.footnote).foregroundStyle(.secondary)
        }
        MemberLimitsLine(mandate: frozen.mandate)
        MemberTermsSection(blocks: frozen.approval.disclosures, collapsed: false)
        if !flow.notice.isEmpty { MemberBanner(text: flow.notice, systemImage: "info.circle", tint: .blue).accessibilityIdentifier("digitalFlowNotice") }
        Button { signed = frozen; Task { await flow.approve() } } label: { Label("Sign with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!flow.canApprove)
            .accessibilityIdentifier("approveDigitalDecision")
        Text("Face ID or Touch ID confirms it is you. It does not replace reading this screen.").font(.caption).foregroundStyle(.secondary)
    }
}

/// What the member signed, under its result (`22` UX-07): the goods kept, and the total.
struct MemberSignedDecision: View {
    let frozen: FrozenMemberDecision
    var body: some View {
        let kept = frozen.decisions.filter { $0.valence == "kept" }.map(\.candidate)
        MemberCard {
            Text("What you signed").font(.headline)
            ForEach(frozen.approval.candidates.filter { kept.contains($0.id) }, id: \.id) { c in
                HStack { Text(verbatim: c.title); Spacer(); Text(verbatim: c.givenBy == nil ? MemberFormat.money(MemberFormat.lineTotal(c.unitPrice, c.quantity)) : String(localized: "Free")).monospacedDigit() }
            }
            if kept.isEmpty { Text("Nothing. You declined every item.").foregroundStyle(.secondary) }
            Divider()
            MemberAmountRow(label: "Total", amount: MemberFormat.money(frozen.total), emphasised: true).accessibilityIdentifier("signedDecisionTotal")
        }
    }
}

/// One line on which of the member's standing limits governs this act (`22` UX-06). The full
/// mandate lives on the Limits tab; a signing screen needs the part that decides this act.
struct MemberLimitsLine: View {
    let mandate: Mandate
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your limits").font(.subheadline.bold())
                Text(verbatim: MemberLimitsText.summary(mandate)).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: "slider.horizontal.3") }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: MemberStyle.corner))
    }
}

enum MemberLimitsText {
    static func daily(_ m: Mandate) -> String {
        m.ceilingDaily.map { String(localized: "Up to \(MemberFormat.money($0)) a day") } ?? String(localized: "No daily limit")
    }
    static func cooling(_ m: Mandate) -> String {
        m.coolingSeconds.map { $0 == 0 ? String(localized: "No time to undo") : String(localized: "\(MemberFormat.duration(seconds: $0)) to undo") } ?? String(localized: "No time to undo")
    }
    static func summary(_ m: Mandate) -> String { daily(m) + " · " + cooling(m) }
}

// MARK: - Result

enum MemberActKind { case decision, statement, undo }

/// `22` UX-07. What was recorded, kept apart from whether money moved (COPY-10). An unknown
/// result offers a read-back and nothing else: never a fresh act (IOS-10).
struct MemberResultView: View {
    let result: MemberActResult
    let notice: String
    let kind: MemberActKind
    let busy: Bool
    let check: () -> Void
    var body: some View {
        MemberCard {
            Label { Text(title).font(.title3.bold()) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            if !notice.isEmpty { Text(verbatim: notice).font(.subheadline) }
            if case .recorded(let amount?) = result {
                MemberAmountRow(label: "Goods charged", amount: MemberFormat.money(amount)).accessibilityIdentifier("resultGoods")
            }
            if case .settledElsewhere(let amount) = result { MemberAmountRow(label: "Goods charged", amount: MemberFormat.money(amount)) }
            if case .settledUnverified(let amount) = result { MemberAmountRow(label: "Goods charged", amount: MemberFormat.money(amount)) }
            Divider()
            Text("Payment status is not available here.").font(.footnote).foregroundStyle(.secondary)
            if result == .unknown || result == .pending {
                Button { check() } label: { Text("Check result").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    .accessibilityIdentifier("checkResult")
            }
        }
    }
    private var title: LocalizedStringKey {
        switch result {
        case .recorded: return kind == .statement ? "Statement signed" : kind == .undo ? "Decision undone" : "Decision recorded"
        case .settledElsewhere, .settledUnverified: return "Already settled"
        case .pending: return "No result yet"
        case .unknown: return "Result not known yet"
        }
    }
    private var icon: String {
        switch result {
        case .recorded: return "checkmark.circle.fill"
        case .settledElsewhere, .settledUnverified: return "info.circle.fill"
        case .pending, .unknown: return "questionmark.circle.fill"
        }
    }
    private var tint: Color {
        switch result {
        case .recorded: return .green
        case .settledElsewhere, .settledUnverified: return .blue
        case .pending, .unknown: return .orange
        }
    }
}

// MARK: - Decided proposal and undo

/// A proposal this household has signed for. The undo (a withdrawal) is reached from here, the
/// decision it undoes, rather than from a list of operation ids (vault `80` S5).
struct MemberDecidedView: View {
    let detail: MemberOfferDetail
    let approval: MemberApproval
    var decisions: MemberDigitalFlow?
    var withdrawals: MemberWithdrawalFlow?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemberCard {
                    Text(verbatim: MemberParties.sellers(approval.candidates.map(\.merchant))).font(.title3.bold())
                    Text(detail.state == "presented" || detail.state == "decided" ? "You decided on this proposal." : "This proposal is closed.").font(.subheadline)
                }
                ForEach(approval.candidates, id: \.id) { c in
                    MemberCard {
                        if c.givenBy == nil {
                            MemberWrappingRow {
                                Text(verbatim: c.title).font(.headline)
                            } trailing: {
                                Text(verbatim: MemberFormat.money(MemberFormat.lineTotal(c.unitPrice, c.quantity))).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            Text(verbatim: c.title).font(.headline)
                        }
                        MemberLineParties(merchant: c.merchant, maker: c.maker, quantity: c.quantity, unitPrice: nil)
                        Text(MemberLineStatus.resolved(c.valence)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let decisions, let withdrawals, let original = decisions.saved.first(where: { $0.offer == detail.id && $0.attempted }) {
                    NavigationLink { MemberUndoScreen(flow: withdrawals, original: original) } label: {
                        Label("Undo this decision", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("openUndo")
                    Text("You can undo within the time your limits allow. Undoing reopens the proposal.").font(.footnote).foregroundStyle(.secondary)
                }
                MemberTermsSection(blocks: approval.disclosures, collapsed: true)
            }
            .padding()
        }
        .onAppear { decisions?.refreshSaved() }
    }
}

/// A withdrawal (§16.5), called undo on screen. It reopens the proposal and cancels no payment.
struct MemberUndoScreen: View {
    @ObservedObject var flow: MemberWithdrawalFlow
    let original: MemberOperationHandle
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = flow.result {
                    MemberResultView(result: result, notice: flow.notice, kind: .undo, busy: flow.busy) { if let handle = flow.handle { Task { await flow.check(handle) } } }
                } else if let frozen = flow.review {
                    MemberCard {
                        Text("Undoing reopens this proposal so you can choose again before it closes. It does not cancel a payment or record a refund.").font(.subheadline)
                        MemberAmountRow(label: "Your decision", amount: MemberFormat.money(frozen.total))
                        Text("You can undo until \(MemberFormat.dayAndTime(frozen.coolingEndsAt)).").font(.subheadline.bold())
                    }
                    MemberLimitsLine(mandate: frozen.mandate)
                    if !flow.notice.isEmpty { MemberBanner(text: flow.notice, systemImage: "info.circle", tint: .blue) }
                    Button { Task { await flow.approve() } } label: { Label("Undo with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!flow.canApprove)
                        .accessibilityIdentifier("approveWithdrawal")
                } else if flow.busy {
                    ProgressView("Preparing").frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    MemberBanner(text: flow.notice.isEmpty ? String(localized: "This decision can no longer be undone.") : flow.notice).accessibilityIdentifier("withdrawalNotice")
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Undo decision")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.closeReview(); flow.refreshSaved(); await flow.prepare(original: original) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in flow.checkExpiry() }
        .onDisappear { flow.closeReview() }
    }
}
