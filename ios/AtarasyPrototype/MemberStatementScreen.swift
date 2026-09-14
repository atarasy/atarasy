import SwiftUI
import Combine
import AtarasyCore

struct MemberStatementScreen: View {
    @ObservedObject var flow: MemberStatementFlow
    let detail: MemberOfferDetail
    let statement: MemberStatement
    @State private var disputed = Set<String>()
    @State private var action: Task<Void, Never>?
    @State private var acknowledged = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func perform(_ work: @escaping @MainActor () async -> Void) { guard action == nil else { return }; action = Task { await work(); action = nil } }
    /// Same wording as the web statement screen (`src/client/app.ts`).
    static let missingAttestation = "Signing shows you were told which items the collection did not find. It is not you agreeing they are missing or taking responsibility for them; you are never charged for them, and you can dispute any you had."
    var body: some View {
        Form {
            if let frozen = flow.review {
                FrozenMemberStatementSections(value: frozen)
                Section("Approval") {
                    // Question 46. What a signature over missing lines attests, beside the button that makes it.
                    if frozen.statement.lines.contains(where: { $0.valence == "lost" }) {
                        Text(MemberStatementScreen.missingAttestation).font(.footnote).accessibilityIdentifier("missingAttestation")
                    }
                    Toggle("I have reviewed this statement and the mandate", isOn: $acknowledged).accessibilityIdentifier("acknowledgeFrozenStatement")
                    Button("Approve with passkey") { perform { await flow.approve() } }
                        .disabled(!acknowledged || !flow.canApprove).accessibilityIdentifier("approveMemberStatement")
                }
            } else if flow.handle == nil && flow.settledOffers.contains(detail.id) {
                Section { Text("This box has settled. Go back and load it again to see its settlement.").accessibilityIdentifier("statementSettled") }
            } else if flow.handle == nil {
                Section("Consumed goods") {
                    Text("Mark any consumed line you dispute before preparing the statement.")
                    ForEach(statement.lines.filter { $0.valence == "consumed" }, id: \.candidate) { line in
                        Toggle("Dispute \(line.product)", isOn: Binding(get: { disputed.contains(line.candidate) }, set: { if $0 { disputed.insert(line.candidate) } else { disputed.remove(line.candidate) } }))
                    }
                }
                // Question 46. A missing line is never charged and founds no claim; the household may still contest it.
                let missing = statement.lines.filter { $0.valence == "lost" }
                if !missing.isEmpty {
                    Section("Recorded missing") {
                        Text("The collection says these were not in the box. You are never charged for them. If one was there, dispute it.")
                        ForEach(missing, id: \.candidate) { line in
                            if let note = line.note { Text("\(line.product): \(note)").font(.footnote) }
                            Toggle("It was in the box: \(line.product)", isOn: Binding(get: { disputed.contains(line.candidate) }, set: { if $0 { disputed.insert(line.candidate) } else { disputed.remove(line.candidate) } }))
                                .accessibilityIdentifier("disputeMissing-" + line.candidate)
                        }
                    }
                }
                Section {
                    if !missing.isEmpty { Text(MemberStatementScreen.missingAttestation).font(.footnote) }
                    Button("Prepare statement for review") { acknowledged = false; perform { await flow.prepare(detail: detail, statement: statement, disputed: Array(disputed)) } }
                        .accessibilityIdentifier("prepareMemberStatement")
                }
            }
            if let handle = flow.handle {
                Section("Saved operation") {
                    Text(handle.id).textSelection(.enabled)
                    if !handle.attempted {
                        Button("Cancel prepared statement", role: .destructive) { perform { await flow.cancelPrepared() } }
                            .accessibilityIdentifier("cancelPreparedStatement")
                    }
                    Button("Check recorded result") { perform { await flow.check(handle) } }.accessibilityIdentifier("checkMemberStatement")
                }
            }
            if flow.busy { ProgressView("Waiting for your request") }
            if !flow.notice.isEmpty { Section { Text(flow.notice).accessibilityIdentifier("statementFlowNotice") } }
        }
        .disabled(flow.busy || action != nil)
        .navigationTitle("Approve statement")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { flow.closeReview() }
        .onReceive(clock) { _ in flow.checkExpiry() }
        .onDisappear { action?.cancel(); flow.closeReview() }
    }
}
struct FrozenMemberStatementSections: View {
    let value: FrozenMemberStatement
    private func date(_ ms: Int64) -> String { Date(timeIntervalSince1970: Double(ms) / 1000).formatted() }
    var body: some View {
        Section("Frozen statement") {
            Text("Household: \(value.statement.household)")
            Text("Collection due: \(date(value.statement.expiresAt))")
            Text("Goods charge: \(value.goodsCharged); disputed amount: \(value.disputedAmount)").accessibilityIdentifier("frozenGoodsTotal")
            Text("Carriage: \(value.statement.carriage ?? 0)")
            Text("Amounts use the merchant's supplied units. Currency was not supplied.").font(.footnote)
        }
        ForEach(value.statement.lines, id: \.candidate) { line in
            Section(line.product) {
                Text("Merchant: \(line.merchant)"); Text("Maker: \(line.maker)"); Text("Carrier: \(line.ships)")
                Text("Quantity: \(line.quantity); unit price: \(line.unitPrice)")
                if line.valence != "lost" { Text("Outcome: \(line.valence); goods amount: \(line.amount)") }
                if let giver = line.givenBy { Text("Gift from \(giver). No goods charge to the recipient.") }
                if line.valence == "lost" {
                    Text("The collection says this was not in the box. Never charged to you.")
                    if let note = line.note { Text(verbatim: note).font(.footnote) }
                    if value.disputed.contains(line.candidate) { Text("Disputed: you say it was in the box. No amount moves.") }
                } else if value.disputed.contains(line.candidate) { Text("Disputed: excluded from the goods charge.") }
            }
        }
        Section("Merchant terms") { Text("Product terms govern matching labels; other standing terms still apply.") }
        ForEach(Array(value.statement.disclosures.enumerated()), id: \.offset) { _, block in
            Section(block.product.map { "Product terms: " + $0 } ?? "Standing terms") {
                Text(verbatim: block.merchant); Text("Version: \(block.version)")
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    Text(verbatim: item.label).font(.headline); Text(verbatim: item.value)
                }
            }
        }
        Section("Mandate") {
            Text("Reference: \(value.mandate.id)"); Text("Household: \(value.mandate.household)")
            Text("Version: \(value.mandate.version)"); Text("Lapses: \(date(value.mandate.lapsesAt))")
            Text("Outside-network ceiling: \(value.mandate.ceilingOutOfNetwork)")
            Text("Daily ceiling: \(value.mandate.ceilingDaily.map(String.init) ?? "Not supplied")")
            Text("Cooling period: \(value.mandate.coolingSeconds.map(String.init) ?? "Not supplied") seconds")
            Text("Co-signers: \(value.mandate.coSigners.isEmpty ? "None" : value.mandate.coSigners.joined(separator: ", "))")
        }
    }
}
struct SavedMemberOperationSections: View {
    @ObservedObject var flow: MemberStatementFlow
    var body: some View {
        Section("Saved statement operations") {
            Button("Refresh saved operations") { flow.refreshSaved() }.disabled(flow.busy)
            ForEach(flow.saved, id: \.id) { handle in
                VStack(alignment: .leading) {
                    Text(handle.offer).textSelection(.enabled)
                    Text(handle.attempted ? "Submission was attempted" : "Preparation saved")
                    Button("Check result") { Task { await flow.check(handle) } }.disabled(flow.busy)
                }
            }
            if !flow.notice.isEmpty { Text(flow.notice).accessibilityIdentifier("savedOperationNotice") }
        }
    }
}
