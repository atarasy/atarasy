import SwiftUI
import AtarasyCore

/// The Dials (`04b` §7b), called Limits on screen: what the member's agent may do without
/// asking, written as sentences rather than fields (vault `80` §6.2 L). A change takes effect
/// only when everyone the current version names has signed it; tightening needs only the
/// member, loosening needs the people they named (clause 47).
struct MemberLimitsView: View {
    @ObservedObject var account: MemberAccount
    var body: some View {
        List {
            Section {
                Text("These are the limits your agent works within. Nothing outside them can be bought for you, and loosening them needs the people you name here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !account.mandates.isEmpty {
                Section("Waiting for your signature") {
                    ForEach(account.mandates) { mandate in
                        NavigationLink { MemberMandateView(account: account, selected: mandate) } label: {
                            Label { VStack(alignment: .leading, spacing: 2) { Text("Review and sign your limits"); Text(verbatim: MemberLimitsText.summary(mandate)).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "signature").foregroundStyle(.orange) }
                        }
                        .accessibilityIdentifier("unsignedMandate-" + mandate.id)
                    }
                }
            }
            ForEach(account.effectiveMandates) { mandate in
                Section {
                    MemberMandateSentences(mandate: mandate)
                    NavigationLink("Change these limits") { MemberMandateEditor(account: account, before: mandate) }
                        .accessibilityIdentifier("editMandate-" + mandate.id)
                } header: {
                    Text(account.effectiveMandates.count > 1 ? "Limits \(mandate.label)" : "Your limits")
                }
            }
            let pending = account.mandateChanges.filter { $0.state == "pending" }
            if !pending.isEmpty {
                Section("Changes waiting for signatures") {
                    ForEach(pending) { change in
                        NavigationLink { MemberMandateChangeReview(account: account, change: change) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Change to your limits")
                                Text("\(change.signedBy.count) of \(change.requiredSigners.count) signatures").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("pendingMandateChange-" + change.id)
                    }
                }
            }
            if account.effectiveMandates.isEmpty && account.mandates.isEmpty {
                Section { Text("No limits are recorded for this account yet.").foregroundStyle(.secondary) }
            }
            if !account.dialsNotice.isEmpty { Section { Text(verbatim: account.dialsNotice).accessibilityIdentifier("dialsNotice") } }
            if !account.mandateNotice.isEmpty { Section { Text(verbatim: account.mandateNotice) } }
        }
        .navigationTitle("Limits")
        .refreshable { await account.refreshDials(); await account.refreshMandates() }
        .task { await account.refreshDials(); await account.refreshMandates() }
    }
}

extension MemberMandate {
    /// The part of the id after the household's, which the member or their hub chose (§13.2).
    var label: String { id.split(separator: ".").last.map(String.init) ?? id }
}
extension Mandate {
    init(_ m: MemberMandate) {
        self.init(id: m.id, household: m.household, ceilingOutOfNetwork: m.ceilingOutOfNetwork, ceilingDaily: m.ceilingDaily, coolingSeconds: m.coolingSeconds, coSigners: m.coSigners, lapsesAt: m.lapsesAt, version: m.version)
    }
}
extension MemberLimitsText {
    static func summary(_ m: MemberMandate) -> String { summary(Mandate(m)) }
}

/// The five protections as sentences. The same view draws "now" and "after the change".
struct MemberMandateSentences: View {
    let mandate: MemberMandate
    var body: some View {
        sentence("calendar", MemberLimitsText.daily(Mandate(mandate)), "Everything bought for you in one day, including what has already been settled today.")
        sentence("building.2", String(localized: "Up to \(MemberFormat.money(mandate.ceilingOutOfNetwork)) at a shop outside your network"), nil)
        sentence("arrow.uturn.backward", MemberLimitsText.cooling(Mandate(mandate)), "After you sign a decision, how long you have to undo it.")
        sentence("person.2", mandate.coSigners.isEmpty ? String(localized: "Nobody else needs to agree to loosen these") : String(localized: "\(mandate.coSigners.count) people must agree to loosen these"), nil)
        sentence("hourglass", String(localized: "Ends on \(MemberFormat.day(mandate.lapsesAt))"), "After this date nothing can be bought for you until you sign new limits.")
    }
    private func sentence(_ icon: String, _ text: String, _ note: LocalizedStringKey?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: icon).foregroundStyle(MemberStyle.accent) }
    }
}

/// Signing a version the host proposed for this household (question 56): until it is signed it is a claim with no effect.
struct MemberMandateView: View {
    @ObservedObject var account: MemberAccount
    let selected: MemberMandate
    @Environment(\.dismiss) private var dismiss
    // `account.mandates` drops a mandate only after `signMandate()` submits it, so its absence is the signed state.
    private var signed: Bool { !account.mandates.contains(where: { $0.id == selected.id }) }
    var body: some View {
        List {
            if signed {
                Section {
                    Label("Your limits are signed and in effect.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("mandateSignedNotice")
                    Button("Done") { dismiss() }.accessibilityIdentifier("mandateSignedDone")
                }
            } else if let review = account.mandateReview, review.mandate == selected {
                Section { Text("Until you sign these, nothing can be bought for you. After you sign, only you can tighten them, and loosening them needs the people you name.").font(.subheadline) }
                Section("Limits to sign") { MemberMandateSentences(mandate: review.mandate) }
                Section {
                    Button { Task { await account.signMandate() } } label: { Label("Sign with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(account.busy).accessibilityIdentifier("signMandate")
                } footer: { Text("Signed for \(review.host).") }
            } else if account.busy {
                ProgressView("Preparing")
            } else {
                Button("Load the limits to sign") { Task { await account.reviewMandate(selected) } }
            }
            if !signed, !account.mandateNotice.isEmpty { Text(verbatim: account.mandateNotice) }
            if !account.notice.isEmpty { Text(verbatim: account.notice) }
        }
        .navigationTitle("Sign your limits")
        .disabled(account.busy)
        .task { if !signed { await account.reviewMandate(selected) } }
    }
}

/// Editing the limits. Amounts in the host's currency, the undo time in hours, the end date on a calendar.
struct MemberMandateEditor: View {
    @ObservedObject var account: MemberAccount
    let before: MemberMandate
    @State private var outside: String
    @State private var daily: String
    @State private var hasDaily: Bool
    @State private var coolingHours: Int
    @State private var hasCooling: Bool
    @State private var signers: String
    @State private var lapse: Date
    @State private var validation = ""
    init(account: MemberAccount, before: MemberMandate) {
        self.account = account; self.before = before
        _outside = State(initialValue: String(before.ceilingOutOfNetwork))
        _daily = State(initialValue: before.ceilingDaily.map(String.init) ?? "")
        _hasDaily = State(initialValue: before.ceilingDaily != nil)
        _coolingHours = State(initialValue: Int((before.coolingSeconds ?? 0) / 3600))
        _hasCooling = State(initialValue: before.coolingSeconds != nil)
        _signers = State(initialValue: before.coSigners.joined(separator: "\n"))
        _lapse = State(initialValue: MemberFormat.date(before.lapsesAt))
    }
    private func proposed() -> MemberMandate? {
        guard let outside = Int64(outside), outside >= 0, !hasDaily || (Int64(daily).map { $0 >= 0 } == true), (0...720).contains(coolingHours) else { return nil }
        let names = signers.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard Set(names).count == names.count else { return nil }
        // A cooling period that was not a whole number of hours keeps its exact value unless the member moved it.
        let original = before.coolingSeconds
        let cooling: Int64? = hasCooling ? (original.map { Int($0 / 3600) == coolingHours ? $0 : Int64(coolingHours) * 3600 } ?? Int64(coolingHours) * 3600) : nil
        let value = MemberMandate(id: before.id, household: before.household, ceilingOutOfNetwork: outside, ceilingDaily: hasDaily ? Int64(daily) : nil, coolingSeconds: cooling, coSigners: names, lapsesAt: Int64(lapse.timeIntervalSince1970 * 1000), version: before.version + 1)
        guard value.ceilingOutOfNetwork != before.ceilingOutOfNetwork || value.ceilingDaily != before.ceilingDaily || value.coolingSeconds != before.coolingSeconds || value.coSigners != before.coSigners || value.lapsesAt != before.lapsesAt else { return nil }
        return value
    }
    var body: some View {
        Form {
            Section("Now") { MemberMandateSentences(mandate: before) }
            Section {
                Toggle("Daily limit", isOn: $hasDaily)
                if hasDaily { LabeledContent("Up to, per day") { TextField("Amount", text: $daily).keyboardType(.numberPad).multilineTextAlignment(.trailing) } }
                LabeledContent("At a shop outside your network") { TextField("Amount", text: $outside).keyboardType(.numberPad).multilineTextAlignment(.trailing).accessibilityIdentifier("mandateOutsideCeiling") }
                Toggle("Time to undo a decision", isOn: $hasCooling)
                if hasCooling { Stepper(value: $coolingHours, in: 0...720) { Text(coolingHours == 0 ? String(localized: "No time to undo") : MemberFormat.duration(seconds: Int64(coolingHours) * 3600)) } }
                DatePicker("Ends on", selection: $lapse, displayedComponents: [.date])
            } header: { Text("New limits") } footer: { Text("Amounts are in \(MemberFormat.currencyCode).") }
            Section {
                TextField("One per line", text: $signers, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("People who must agree to loosen these") } footer: { Text("Enter the account reference each person gives you.") }
            Section {
                Text("Raising a limit, shortening the time to undo or removing a person needs everyone named in your current limits to sign. Nothing changes until they have.").font(.footnote)
                Button("Review this change") {
                    guard let value = proposed() else { validation = String(localized: "Change at least one limit. Amounts must be whole numbers, the time to undo at most 30 days, and each person listed once."); return }
                    validation = ""; Task { await account.reviewMandateChange(value) }
                }.accessibilityIdentifier("reviewMandateChange")
                if !validation.isEmpty { Text(verbatim: validation).foregroundStyle(.red).accessibilityIdentifier("mandateValidation") }
            }
            if let prepared = account.preparedMandateChange, prepared.change.before.id == before.id {
                Section("After the change") { MemberMandateSentences(mandate: prepared.change.mandate) }
                Section("Who must sign") {
                    ForEach(prepared.change.requiredSigners, id: \.self) { signer in MemberSignerRow(signer: signer, signed: prepared.change.signedBy.contains(signer), isYou: signer == account.session?.household) }
                    Button { Task { await account.signPreparedMandateChange() } } label: { Label("Sign with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("signMandateChange")
                }
            }
            if !account.dialsNotice.isEmpty { Section { Text(verbatim: account.dialsNotice).accessibilityIdentifier("dialsNotice") } }
        }
        .navigationTitle("Change limits")
    }
}

struct MemberSignerRow: View {
    let signer: String
    let signed: Bool
    let isYou: Bool
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(isYou ? "You" : "Another person")
                if !isYou { Text(verbatim: signer).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
        } icon: { Image(systemName: signed ? "checkmark.circle.fill" : "circle").foregroundStyle(signed ? .green : .secondary) }
        .accessibilityValue(signed ? Text("Signed") : Text("Waiting"))
        .accessibilityIdentifier("mandateSigner-" + signer)
    }
}

/// A change waiting for signatures. The signers come from the version in effect when it was proposed.
struct MemberMandateChangeReview: View {
    @ObservedObject var account: MemberAccount
    let change: MemberMandateChange
    private var current: MemberMandateChange { account.mandateChanges.first(where: { $0.id == change.id }) ?? change }
    private var maySign: Bool { account.session.map { current.requiredSigners.contains($0.household) && !current.signedBy.contains($0.household) } ?? false }
    private var owns: Bool { account.session?.household == current.mandate.household }
    var body: some View {
        List {
            Section("Now") { MemberMandateSentences(mandate: current.before) }
            Section("After the change") { MemberMandateSentences(mandate: current.mandate) }
            Section {
                ForEach(current.requiredSigners, id: \.self) { signer in MemberSignerRow(signer: signer, signed: current.signedBy.contains(signer), isYou: signer == account.session?.household) }
                if maySign && account.preparedMandateChange?.change.id != current.id {
                    Button("Review for my signature") { Task { await account.reviewPendingMandateChange(current.id) } }.accessibilityIdentifier("reviewPendingMandateChange")
                }
                if account.preparedMandateChange?.change.id == current.id {
                    Button { Task { await account.signPreparedMandateChange() } } label: { Label("Sign with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("signPendingMandateChange")
                }
                if owns { Button("Cancel this change", role: .destructive) { Task { await account.cancelMandateChange(current.id) } }.accessibilityIdentifier("cancelMandateChange") }
            } header: { Text("Who must sign") } footer: { Text("Taken from the limits in effect when the change was proposed.").accessibilityIdentifier("mandateSignerBasis") }
            if !account.dialsNotice.isEmpty { Section { Text(verbatim: account.dialsNotice).accessibilityIdentifier("dialsNotice") } }
        }
        .navigationTitle("Change to your limits")
    }
}
