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
    @Environment(\.dismiss) private var dismiss
    // `account.mandates` drops a mandate's id only after `signMandate()` submits it
    // successfully (MemberAccount.swift), so its absence here is the signed state.
    // Deriving it this way, rather than a separate local flag, keeps this screen and
    // the "Mandates awaiting your signature" list in Account agreeing about what is
    // signed without an extra round trip.
    private var signed: Bool { !account.mandates.contains(where: { $0.id == selected.id }) }
    var body: some View {
        Form {
            if signed {
                Section {
                    Text("Mandate signed. It is now in effect.").accessibilityIdentifier("mandateSignedNotice")
                    Button("Done") { dismiss() }.accessibilityIdentifier("mandateSignedDone")
                }
            } else if let review = account.mandateReview, review.mandate == selected {
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
            if !signed, !account.mandateNotice.isEmpty { Text(account.mandateNotice) }
            if !account.notice.isEmpty { Text(account.notice) }
        }
        .navigationTitle("Review mandate")
        .disabled(account.busy)
        .interactiveDismissDisabled(account.busy)
        .task { if !signed { acknowledged = false; await account.reviewMandate(selected) } }
    }
}

struct MemberDialsSection: View {
    @ObservedObject var account: MemberAccount
    var body: some View {
        Section {
            NavigationLink("Dials · standing protections") { MemberDialsView(account: account) }
                .accessibilityIdentifier("openDials")
        }
    }
}

private struct MandateTermsView: View {
    let title: String
    let value: MemberMandate
    var body: some View {
        Section(title) {
            Text("Version \(value.version)").font(.headline)
            Text("Outside-network ceiling: ¥\(value.ceilingOutOfNetwork)")
            Text(value.ceilingDaily.map { "Daily ceiling: ¥\($0)" } ?? "No daily ceiling")
            Text(value.coolingSeconds.map { "Cooling period: \($0) seconds" } ?? "No cooling period")
            Text(value.coSigners.isEmpty ? "No co-signers" : "Co-signers: " + value.coSigners.joined(separator: ", "))
            Text("Lapses: \(Date(timeIntervalSince1970: Double(value.lapsesAt) / 1000).formatted())")
        }
    }
}

struct MemberDialsView: View {
    @ObservedObject var account: MemberAccount
    var body: some View {
        Form {
            Section {
                Text("Dials are your standing protections. A change has no effect until every signer required by the previous effective version has signed it.").font(.footnote)
                Button("Refresh effective protections") { Task { await account.refreshDials() } }
                    .accessibilityIdentifier("refreshDials")
            }
            Section("Effective mandates") {
                ForEach(account.effectiveMandates) { mandate in
                    NavigationLink { MemberMandateEditor(account: account, before: mandate) } label: {
                        VStack(alignment: .leading) {
                            Text("Version \(mandate.version)").font(.headline)
                            Text("Daily: " + (mandate.ceilingDaily.map { "¥\($0)" } ?? "none") + " · Cooling: " + (mandate.coolingSeconds.map { "\($0)s" } ?? "none"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("editMandate-" + mandate.id)
                }
            }
            Section("Pending changes and co-signatures") {
                if account.mandateChanges.filter({ $0.state == "pending" }).isEmpty { Text("No pending changes.") }
                ForEach(account.mandateChanges.filter { $0.state == "pending" }) { change in
                    NavigationLink { MemberMandateChangeReview(account: account, change: change) } label: {
                        VStack(alignment: .leading) {
                            Text("Version \(change.mandate.version) · \(change.signedBy.count) of \(change.requiredSigners.count) signatures")
                            Text(change.mandate.id).font(.caption).lineLimit(1)
                        }
                    }.accessibilityIdentifier("pendingMandateChange-" + change.id)
                }
            }
            if !account.dialsNotice.isEmpty { Section { Text(account.dialsNotice).accessibilityIdentifier("dialsNotice") } }
        }
        .navigationTitle("Dials")
        .task { if account.effectiveMandates.isEmpty && account.mandateChanges.isEmpty { await account.refreshDials() } }
    }
}

private struct MemberMandateEditor: View {
    @ObservedObject var account: MemberAccount
    let before: MemberMandate
    @State private var outside: String
    @State private var daily: String
    @State private var hasDaily: Bool
    @State private var cooling: String
    @State private var hasCooling: Bool
    @State private var signers: String
    @State private var lapse: Date
    @State private var acknowledged = false
    @State private var validation = ""
    init(account: MemberAccount, before: MemberMandate) {
        self.account = account; self.before = before
        _outside = State(initialValue: String(before.ceilingOutOfNetwork))
        _daily = State(initialValue: before.ceilingDaily.map(String.init) ?? "")
        _hasDaily = State(initialValue: before.ceilingDaily != nil)
        _cooling = State(initialValue: before.coolingSeconds.map(String.init) ?? "")
        _hasCooling = State(initialValue: before.coolingSeconds != nil)
        _signers = State(initialValue: before.coSigners.joined(separator: "\n"))
        _lapse = State(initialValue: Date(timeIntervalSince1970: Double(before.lapsesAt) / 1000))
    }
    private func proposed() -> MemberMandate? {
        guard let outside = Int64(outside), outside >= 0,
              !hasDaily || (Int64(daily).map { $0 >= 0 } == true),
              !hasCooling || (Int64(cooling).map { (0...2_592_000).contains($0) } == true) else { return nil }
        let names = signers.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard Set(names).count == names.count else { return nil }
        let value = MemberMandate(id: before.id, household: before.household, ceilingOutOfNetwork: outside, ceilingDaily: hasDaily ? Int64(daily) : nil, coolingSeconds: hasCooling ? Int64(cooling) : nil, coSigners: names, lapsesAt: Int64(lapse.timeIntervalSince1970 * 1000), version: before.version + 1)
        guard value.ceilingOutOfNetwork != before.ceilingOutOfNetwork || value.ceilingDaily != before.ceilingDaily || value.coolingSeconds != before.coolingSeconds || value.coSigners != before.coSigners || value.lapsesAt != before.lapsesAt else { return nil }
        return value
    }
    var body: some View {
        Form {
            MandateTermsView(title: "Effective now", value: before)
            Section("Proposed protections") {
                TextField("Outside-network ceiling", text: $outside).keyboardType(.numberPad).accessibilityIdentifier("mandateOutsideCeiling")
                Toggle("Use a daily ceiling", isOn: $hasDaily)
                if hasDaily { TextField("Daily ceiling", text: $daily).keyboardType(.numberPad) }
                Toggle("Use a cooling period", isOn: $hasCooling)
                if hasCooling { TextField("Cooling seconds", text: $cooling).keyboardType(.numberPad) }
                TextField("Co-signers, one key per line", text: $signers, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                DatePicker("Lapse", selection: $lapse, displayedComponents: [.date, .hourAndMinute])
                Text("A wider ceiling, shorter cooling period, removed co-signer, or other weakening uses the co-signers from version \(before.version). The app never changes protections automatically.").font(.footnote)
                Button("Review mandate change") {
                    guard let value = proposed() else { validation = "Change or renew at least one protection. Use whole non-negative limits, a cooling period of at most 30 days, and distinct co-signer keys."; return }
                    validation = ""; Task { await account.reviewMandateChange(value) }
                }.accessibilityIdentifier("reviewMandateChange")
                if !validation.isEmpty { Text(validation).accessibilityIdentifier("mandateValidation") }
            }
            if let prepared = account.preparedMandateChange, prepared.change.before.id == before.id {
                MandateTermsView(title: "Fixed proposal to sign", value: prepared.change.mandate)
                Section("Required signatures from effective version \(before.version)") {
                    ForEach(prepared.change.requiredSigners, id: \.self) { signer in Text((prepared.change.signedBy.contains(signer) ? "Signed · " : "Required · ") + signer) }
                    Toggle("I reviewed the effective and proposed protections", isOn: $acknowledged).accessibilityIdentifier("acknowledgeMandateChange")
                    Button("Sign mandate change with a passkey") { Task { await account.signPreparedMandateChange() } }
                        .disabled(!acknowledged).accessibilityIdentifier("signMandateChange")
                }
            }
            if !account.dialsNotice.isEmpty { Section { Text(account.dialsNotice).accessibilityIdentifier("dialsNotice") } }
        }.navigationTitle("Change protections")
    }
}

private struct MemberMandateChangeReview: View {
    @ObservedObject var account: MemberAccount
    let change: MemberMandateChange
    @State private var acknowledged = false
    private var current: MemberMandateChange { account.mandateChanges.first(where: { $0.id == change.id }) ?? change }
    private var maySign: Bool { account.session.map { current.requiredSigners.contains($0.household) && !current.signedBy.contains($0.household) } ?? false }
    private var owns: Bool { account.session?.household == current.mandate.household }
    var body: some View {
        Form {
            MandateTermsView(title: "Effective when proposed", value: current.before)
            MandateTermsView(title: "Proposed version", value: current.mandate)
            Section("Required signers from version \(current.before.version)") {
                Text("Signatures required by effective version \(current.before.version)").accessibilityIdentifier("mandateSignerBasis")
                ForEach(current.requiredSigners, id: \.self) { signer in Text((current.signedBy.contains(signer) ? "Signed · " : "Waiting · ") + signer).accessibilityIdentifier("mandateSigner-" + signer) }
                if maySign && account.preparedMandateChange?.change.id != current.id {
                    Button("Review for my signature") { Task { await account.reviewPendingMandateChange(current.id) } }.accessibilityIdentifier("reviewPendingMandateChange")
                }
                if account.preparedMandateChange?.change.id == current.id {
                    Toggle("I reviewed both versions", isOn: $acknowledged).accessibilityIdentifier("acknowledgePendingMandateChange")
                    Button("Add my passkey signature") { Task { await account.signPreparedMandateChange() } }.disabled(!acknowledged).accessibilityIdentifier("signPendingMandateChange")
                }
                if owns { Button("Cancel pending change", role: .destructive) { Task { await account.cancelMandateChange(current.id) } }.accessibilityIdentifier("cancelMandateChange") }
            }
            if !account.dialsNotice.isEmpty { Section { Text(account.dialsNotice).accessibilityIdentifier("dialsNotice") } }
        }.navigationTitle("Mandate review")
    }
}
