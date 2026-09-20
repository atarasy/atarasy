import SwiftUI
import Combine
import AtarasyCore

struct MemberWithdrawalScreen: View {
    @ObservedObject var flow: MemberWithdrawalFlow
    let original: MemberOperationHandle
    @State private var acknowledged = false
    @State private var action: Task<Void, Never>?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func perform(_ work: @escaping @MainActor () async -> Void) { guard action == nil else { return }; action = Task { await work(); action = nil } }
    var body: some View {
        Form {
            Section("Decision to withdraw") {
                Text(original.offer).textSelection(.enabled)
                Text("Original operation: \(original.id)").font(.footnote).textSelection(.enabled)
                Text("Withdrawal reopens the proposal's choices. Refresh the proposal before deciding again. Its expiry still applies. This does not cancel a payment or record a refund.")
            }
            if let frozen = flow.review {
                Section("Original decision") {
                    Text("Selected goods: \(frozen.goods)")
                    Text("Carriage: \(frozen.carriage)")
                    Text("Goods and carriage: \(frozen.total)")
                    Text("Cooling deadline: \(Date(timeIntervalSince1970: Double(frozen.coolingEndsAt) / 1000).formatted())")
                    Text("Current mandate version: \(frozen.mandate.version)")
                    Text("A previously recorded cooling right can remain after a mandate lapses.").font(.footnote)
                }
                MemberReviewSections(review: .approval(frozen.approval), frozenDecisions: frozen.decisions)
                Section("Withdraw this decision") {
                    Toggle("I reviewed the decision and want to withdraw it", isOn: $acknowledged).accessibilityIdentifier("acknowledgeWithdrawal")
                    Button("Withdraw with passkey") { perform { await flow.approve() } }.disabled(!acknowledged || !flow.canApprove).accessibilityIdentifier("approveWithdrawal")
                }
            } else if flow.handle == nil {
                Button("Prepare withdrawal for review") { acknowledged = false; perform { await flow.prepare(original: original) } }.accessibilityIdentifier("prepareWithdrawal")
            }
            if let handle = flow.handle {
                Section("Saved withdrawal") {
                    Text(handle.id).textSelection(.enabled)
                    if !handle.attempted { Button("Cancel prepared withdrawal") { perform { await flow.cancelPrepared() } }.accessibilityIdentifier("cancelWithdrawal") }
                    Button("Check withdrawal result") { perform { await flow.check(handle) } }.accessibilityIdentifier("checkWithdrawal")
                }
            }
            if flow.busy { ProgressView("Waiting for your request") }
            if !flow.notice.isEmpty { Text(flow.notice).accessibilityIdentifier("withdrawalNotice") }
        }
        .disabled(flow.busy || action != nil)
        .navigationTitle("Withdraw decision")
        .onAppear { flow.closeReview() }
        .onReceive(clock) { _ in flow.checkExpiry() }
        .onDisappear { action?.cancel(); flow.closeReview() }
    }
}
struct SavedMemberWithdrawalSections: View {
    @ObservedObject var flow: MemberWithdrawalFlow
    var body: some View {
        Section("Saved withdrawals") {
            Button("Refresh saved withdrawals") { flow.refreshSaved() }.disabled(flow.busy)
            ForEach(flow.saved, id: \.id) { h in Button("Check withdrawal for \(h.offer)") { Task { await flow.check(h) } }.disabled(flow.busy) }
            if !flow.notice.isEmpty { Text(flow.notice) }
        }.onAppear { flow.refreshSaved() }
    }
}
