import SwiftUI
import AtarasyCore

struct MemberMandateSection: View {
    @ObservedObject var account: MemberAccount
    var body: some View {
        Section("Mandates awaiting your signature") {
            Text("These terms are not active until you review and sign them.").font(.footnote)
            Button("Refresh unsigned mandates") { Task { await account.refreshMandates() } }
                .accessibilityIdentifier("refreshUnsignedMandates")
            ForEach(account.mandates) { mandate in
                NavigationLink { MemberMandateView(account: account, selected: mandate) } label: {
                    VStack(alignment: .leading) {
                        Text("Review mandate · version \(mandate.version)")
                        Text(mandate.id).font(.caption)
                    }
                }
            }
            if !account.mandateNotice.isEmpty { Text(account.mandateNotice) }
        }
    }
}
struct MemberMandateView: View {
    @ObservedObject var account: MemberAccount
    let selected: MemberMandate
    @State private var acknowledged = false
    var body: some View {
        Form {
            if let review = account.mandateReview, review.mandate == selected {
                let m = review.mandate
                Section("Terms to sign") {
                    Text("Host: \(review.host)")
                    Text("Mandate: \(m.id)").textSelection(.enabled)
                    Text("Household: \(m.household)").textSelection(.enabled)
                    Text("Version: \(m.version)")
                    Text("Outside-network ceiling: ¥\(m.ceilingOutOfNetwork)")
                    Text(m.ceilingDaily.map { "Daily ceiling: ¥\($0)" } ?? "No daily ceiling")
                    Text(m.coolingSeconds.map { "Cooling period: \($0) seconds" } ?? "No cooling period")
                    Text(m.coSigners.isEmpty ? "No co-signers" : "Co-signers: " + m.coSigners.joined(separator: ", "))
                    Text("Lapses: \(Date(timeIntervalSince1970: Double(m.lapsesAt) / 1000).formatted())")
                }
                Section {
                    Toggle("I have read and agree to these terms", isOn: $acknowledged)
                        .accessibilityIdentifier("acknowledgeMandate")
                    Button("Sign mandate with a passkey") { Task { await account.signMandate(); acknowledged = false } }
                        .disabled(!acknowledged || account.busy)
                        .accessibilityIdentifier("signMandate")
                }
            } else if !account.busy {
                Button("Load terms for review") { Task { acknowledged = false; await account.reviewMandate(selected) } }
            }
            if account.busy { ProgressView("Waiting for your request") }
            if !account.mandateNotice.isEmpty { Text(account.mandateNotice) }
            if !account.notice.isEmpty { Text(account.notice) }
        }
        .navigationTitle("Review mandate")
        .disabled(account.busy)
        .interactiveDismissDisabled(account.busy)
        .task { acknowledged = false; await account.reviewMandate(selected) }
    }
}
