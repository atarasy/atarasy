import SwiftUI
import AtarasyCore

/// Me, my devices, my data (vault `80` §6.2 A). The household's key hash is kept for support
/// under "About this account" and is never the first thing a member reads.
struct MemberAccountTab: View {
    @ObservedObject var account: MemberAccount
    @State private var showingLeaveSheet = false
    @State private var action: Task<Void, Never>?
    var body: some View {
        List {
            if let session = account.session {
                Section {
                    Label { VStack(alignment: .leading, spacing: 2) { Text("Signed in with your passkey"); Text("Until \(MemberFormat.dayAndTime(session.expiresAt))").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green) }
                }
            }
            Section {
                NavigationLink { MemberRecordsView(account: account) } label: { Label("My records", systemImage: "doc.text.magnifyingglass") }
                    .accessibilityIdentifier("openRecords")
            } footer: { Text("Decisions and statements you signed on this device, and their results.") }
            Section("Sharing") {
                if let requests = account.permissionRequests { NavigationLink { MemberPermissionRequestsView(model: requests) } label: { Label("Access requests", systemImage: "hand.raised") } }
                if let permissions = account.permissions { NavigationLink { MemberPermissionsView(model: permissions) } label: { Label("What you have shared", systemImage: "lock.open") } }
            }
            Section("Your data") {
                if !account.privateNodeNotice.isEmpty { Text(verbatim: account.privateNodeNotice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("privateNodeStatus") }
                if let recovery = account.recovery { NavigationLink { MemberRecoveryView(model: recovery, recoveryRequired: account.privateNodeState == .recoveryRequired) } label: { Label("Recovery", systemImage: "key.horizontal") } }
                if let hostMove = account.hostMove { NavigationLink { MemberHostMoveView(model: hostMove) } label: { Label("Move to another host", systemImage: "arrow.right.doc.on.clipboard") }.disabled(account.privateNodeState != .ready) }
            }
            if !account.refreshNotice.isEmpty { Section("Notifications") { Text(verbatim: account.refreshNotice).font(.footnote).accessibilityIdentifier("memberRefreshNotice") } }
            Section {
                Button("Sign out") { guard action == nil else { return }; action = Task { await account.signOut(); action = nil } }.accessibilityIdentifier("memberSignOut")
                Button("Delete account", role: .destructive) { showingLeaveSheet = true }.accessibilityIdentifier("memberDeleteAccount")
            }
            if let session = account.session {
                Section {
                    DisclosureGroup("About this account") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This account's records open only on the device where you first signed in.").font(.footnote)
                            Text("Account reference, for support").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: session.household).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("accountReference")
                        }
                    }
                }
            }
            if MemberPRFMeasurementView.isAvailable && MemberPRFMeasurementView.relyingParty != nil {
                Section("For the team") { MemberPRFMeasurementLink() }
            }
            if !account.notice.isEmpty { Section { Text(verbatim: account.notice).accessibilityIdentifier("memberNotice") } }
        }
        .navigationTitle("Account")
        .disabled(account.busy || action != nil)
        .sheet(isPresented: $showingLeaveSheet) { NavigationStack { MemberLeaveSheet(account: account) } }
    }
}

/// Everything this device signed, reached from Account rather than from a public feed
/// (`22` §1). Each row names its goods where the Inbox still lists the offer.
struct MemberRecordsView: View {
    @ObservedObject var account: MemberAccount
    var body: some View {
        List {
            if let statements = account.statements { MemberStatementRecords(flow: statements, account: account) }
            if let decisions = account.decisions { MemberDecisionRecords(flow: decisions, account: account) }
            if let withdrawals = account.withdrawals { MemberUndoRecords(flow: withdrawals, account: account) }
        }
        .navigationTitle("My records")
        .onAppear { account.statements?.refreshSaved(); account.decisions?.refreshSaved(); account.withdrawals?.refreshSaved() }
    }
}

struct MemberStatementRecords: View {
    @ObservedObject var flow: MemberStatementFlow
    @ObservedObject var account: MemberAccount
    var body: some View {
        MemberRecordList(title: "Statements", saved: flow.saved, account: account) { handle in
            MemberRecordDetail(handle: handle, account: account) {
                MemberRecordCheck(kind: .statement, handle: handle, current: flow.handle, result: flow.result, notice: flow.notice, busy: flow.busy) { await flow.check(handle) }
            }
            .onAppear { flow.closeReview() }
        }
    }
}
struct MemberDecisionRecords: View {
    @ObservedObject var flow: MemberDigitalFlow
    @ObservedObject var account: MemberAccount
    var body: some View {
        MemberRecordList(title: "Decisions", saved: flow.saved, account: account) { handle in
            MemberRecordDetail(handle: handle, account: account) {
                MemberRecordCheck(kind: .decision, handle: handle, current: flow.handle, result: flow.result, notice: flow.notice, busy: flow.busy) { await flow.check(handle) }
                if handle.attempted, let withdrawals = account.withdrawals {
                    NavigationLink { MemberUndoScreen(flow: withdrawals, original: handle) } label: { Label("Undo this decision", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).accessibilityIdentifier("openUndo")
                }
            }
            .onAppear { flow.closeReview() }
        }
    }
}
struct MemberUndoRecords: View {
    @ObservedObject var flow: MemberWithdrawalFlow
    @ObservedObject var account: MemberAccount
    var body: some View {
        MemberRecordList(title: "Undone decisions", saved: flow.saved, account: account) { handle in
            MemberRecordDetail(handle: handle, account: account) {
                MemberRecordCheck(kind: .undo, handle: handle, current: flow.handle, result: flow.result, notice: flow.notice, busy: flow.busy) { await flow.check(handle) }
            }
            .onAppear { flow.closeReview() }
        }
    }
}

struct MemberRecordList<Destination: View>: View {
    let title: LocalizedStringKey
    let saved: [MemberOperationHandle]
    @ObservedObject var account: MemberAccount
    @ViewBuilder let destination: (MemberOperationHandle) -> Destination
    var body: some View {
        Section(title) {
            if saved.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(saved, id: \.id) { handle in
                NavigationLink { destination(handle) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: MemberRecordText.goods(handle, account: account))
                        Text(handle.attempted ? "Signed and sent" : "Prepared, not signed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("record-" + handle.id)
            }
        }
    }
}

enum MemberRecordText {
    /// The goods on the offer, where the Inbox still lists it; a generic noun otherwise, never the id.
    @MainActor static func goods(_ handle: MemberOperationHandle, account: MemberAccount) -> String {
        let offers = account.proposals.sources.flatMap(\.offers)
        guard let offer = offers.first(where: { $0.id == handle.offer }), let lines = offer.candidates, let first = lines.first else {
            return handle.operationProfile.contains("statement") ? String(localized: "A box") : String(localized: "A proposal")
        }
        return lines.count == 1 ? first.title : String(localized: "\(first.title) and \(lines.count - 1) more")
    }
}

struct MemberRecordDetail<Content: View>: View {
    let handle: MemberOperationHandle
    @ObservedObject var account: MemberAccount
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemberCard {
                    Text(verbatim: MemberRecordText.goods(handle, account: account)).font(.headline)
                    Text(handle.attempted ? "You signed this and it was sent." : "This was prepared and never signed. Nothing was sent.").font(.subheadline).foregroundStyle(.secondary)
                }
                content
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MemberRecordCheck: View {
    let kind: MemberActKind
    let handle: MemberOperationHandle
    let current: MemberOperationHandle?
    let result: MemberActResult?
    let notice: String
    let busy: Bool
    let check: () async -> Void
    var body: some View {
        if let result, current?.id == handle.id {
            MemberResultView(result: result, notice: notice, kind: kind, busy: busy) { Task { await check() } }
        } else if handle.attempted {
            Button { Task { await check() } } label: { Text("Check result").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("checkResult")
        }
    }
}
