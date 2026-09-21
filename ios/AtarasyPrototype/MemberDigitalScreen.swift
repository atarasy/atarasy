import SwiftUI
import Combine
import AtarasyCore

struct MemberDigitalScreen: View {
    @ObservedObject var flow: MemberDigitalFlow
    let detail: MemberOfferDetail
    let draft: MemberDigitalDraft
    @State private var acknowledged = false
    @State private var action: Task<Void, Never>?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func perform(_ work: @escaping @MainActor () async -> Void) { guard action == nil else { return }; action = Task { await work(); action = nil } }
    var body: some View {
        Form {
            if let frozen = flow.review {
                Section("Frozen choices") {
                    Text("Selected goods: \(frozen.goods)")
                    Text("Carriage: \(frozen.carriage)")
                    Text("Goods and carriage: \(frozen.total)").accessibilityIdentifier("frozenDigitalTotal")
                    Text("Amounts use the merchant's supplied units. This decision does not confirm payment.").font(.footnote)
                }
                MemberReviewSections(review: .approval(frozen.approval), frozenDecisions: frozen.decisions)
                Section("Mandate") {
                    Text("Reference: \(frozen.mandate.id)")
                    Text("Version: \(frozen.mandate.version)")
                    Text("Lapses: \(Date(timeIntervalSince1970: Double(frozen.mandate.lapsesAt) / 1000).formatted())")
                    Text("Outside-network ceiling: \(frozen.mandate.ceilingOutOfNetwork)")
                    Text("Daily ceiling: \(frozen.mandate.ceilingDaily.map(String.init) ?? "Not supplied")")
                    Text("Cooling seconds: \(frozen.mandate.coolingSeconds.map(String.init) ?? "Not supplied")")
                    Text("Co-signers: \(frozen.mandate.coSigners.isEmpty ? "None" : frozen.mandate.coSigners.joined(separator: ", "))")
                }
                Section("Approval") {
                    Toggle("I have reviewed these choices and terms", isOn: $acknowledged).accessibilityIdentifier("acknowledgeDigitalDecision")
                    Button("Confirm with passkey") { perform { await flow.approve() } }
                        .disabled(!acknowledged || !flow.canApprove).accessibilityIdentifier("approveDigitalDecision")
                }
            } else if flow.handle == nil {
                Section {
                    Text("Prepare a frozen review of your choices. Preparation does not submit the decision.")
                    Button("Prepare decision for review") { acknowledged = false; perform { await flow.prepare(detail: detail, draft: draft) } }
                        .accessibilityIdentifier("prepareDigitalDecision")
                }
            }
            if let handle = flow.handle {
                Section("Saved decision") {
                    Text(handle.id).textSelection(.enabled)
                    if !handle.attempted { Button("Cancel prepared decision") { perform { await flow.cancelPrepared() } }.accessibilityIdentifier("cancelDigitalDecision") }
                    Button("Check recorded result") { perform { await flow.check(handle) } }.accessibilityIdentifier("checkDigitalDecision")
                }
            }
            if flow.busy { ProgressView("Waiting for your request") }
            if !flow.notice.isEmpty { Section { Text(flow.notice).accessibilityIdentifier("digitalFlowNotice") } }
        }
        .disabled(flow.busy || action != nil)
        .navigationTitle("Digital decision")
        .onAppear { flow.closeReview() }
        .onReceive(clock) { _ in flow.checkExpiry() }
        .onDisappear { action?.cancel(); flow.closeReview() }
    }
}
struct SavedMemberDecisionSections: View {
    @ObservedObject var flow: MemberDigitalFlow
    var withdrawals: MemberWithdrawalFlow? = nil
    var body: some View {
        Section("Saved digital decisions") {
            Button("Refresh saved decisions") { flow.refreshSaved() }.disabled(flow.busy)
            ForEach(flow.saved, id: \.id) { handle in
                if let withdrawals { NavigationLink("Review withdrawal for \(handle.offer)") { MemberWithdrawalScreen(flow: withdrawals, original: handle) } }
                Button("Check \(handle.offer)") { Task { await flow.check(handle) } }.disabled(flow.busy)
            }
            if !flow.notice.isEmpty { Text(flow.notice) }
        }.onAppear { flow.refreshSaved() }
    }
}
