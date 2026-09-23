import SwiftUI
import AtarasyCore

/// The member's app once an account object exists: the entry screen while signed out, and
/// three destinations while signed in (`22` §1, vault `80` §6.1). A result is reached from
/// its offer or from My records, never from a feed.
struct MemberAppView: View {
    @ObservedObject var account: MemberAccount
    @State private var tab: MemberTab = .inbox
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if account.session == nil {
                NavigationStack { MemberEntryView(account: account) }
            } else if !account.protectedAccessReady {
                NavigationStack { MemberLockedView(account: account) }
            } else {
                TabView(selection: $tab) {
                    NavigationStack { MemberInboxView(account: account, proposals: account.proposals) }
                        .tabItem { Label("Inbox", systemImage: "tray") }
                        .tag(MemberTab.inbox)
                    NavigationStack { MemberLimitsView(account: account) }
                        .tabItem { Label("Limits", systemImage: "slider.horizontal.3") }
                        .tag(MemberTab.limits)
                    NavigationStack { MemberAccountTab(account: account) }
                        .tabItem { Label("Account", systemImage: "person.crop.circle") }
                        .tag(MemberTab.account)
                }
            }
        }
        .onReceive(clock) { date in account.clearExpired(now: Int64(date.timeIntervalSince1970 * 1000)) }
    }
}
enum MemberTab: Hashable { case inbox, limits, account }

/// Signed out. One sentence of what this is, and the two ways in. Restoring a session by a
/// household reference stays available for support, behind the trouble link, because no
/// member knows their household reference.
struct MemberEntryView: View {
    @ObservedObject var account: MemberAccount
    @State private var invitation = ""
    @State private var household = ""
    @State private var showingInvitation = false
    @State private var showingTrouble = false
    @State private var action: Task<Void, Never>?
    private func perform(_ work: @escaping @MainActor () async -> Void) { guard action == nil else { return }; action = Task { await work(); action = nil } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(MemberStyle.accent)
                    Text("Atarasy").font(.largeTitle.bold())
                    Text("Your own agent for things that arrive to be tried. You pay only for what you keep, and nothing is bought without your signature.")
                        .font(.body).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    Button { perform { await account.signIn() } } label: {
                        Label("Sign in with passkey", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("memberSignIn")
                    Button { showingInvitation.toggle() } label: { Text("I have an invitation").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("memberShowInvitation")
                }
                if showingInvitation {
                    MemberCard {
                        Text("Enter the invitation code you were given. A passkey is created on this device; no password is used.").font(.subheadline)
                        // Vault `81` option A: the pilot is one device per household.
                        Text("Use Atarasy on this device only. Your records are encrypted with a key kept on this device, and another device cannot open them.").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("oneDeviceNote")
                        SecureField("Invitation code", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Create passkey") {
                            let supplied = invitation; invitation = ""
                            perform { await account.enrol(invitation: supplied) }
                        }
                        .buttonStyle(.borderedProminent).disabled(invitation.isEmpty).accessibilityIdentifier("memberEnrol")
                    }
                }
                if account.busy { ProgressView("Waiting for your passkey").frame(maxWidth: .infinity) }
                if !account.notice.isEmpty { MemberBanner(text: account.notice, systemImage: "info.circle", tint: .blue).accessibilityIdentifier("memberNotice") }
                DisclosureGroup("Having trouble signing in?", isExpanded: $showingTrouble) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Support may ask you for the account reference shown under Account on a device where you are signed in. It does not sign you in by itself.").font(.footnote).foregroundStyle(.secondary)
                        TextField("Account reference", text: $household).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        Button("Restore session") { let selected = household; perform { await account.restore(household: selected) } }
                            .disabled(household.isEmpty).accessibilityIdentifier("memberRestore")
                    }.padding(.top, 8)
                }
                .font(.subheadline)
            }
            .padding(24)
        }
        .disabled(account.busy || action != nil)
        .onDisappear { invitation = ""; household = ""; action?.cancel() }
    }
}

/// Signed in, but this device cannot open the household's encrypted records yet.
/// Every way out stays reachable here: trying again, recovery, deleting the account and
/// signing out. A member whose records cannot be opened must never meet a dead end.
struct MemberLockedView: View {
    @ObservedObject var account: MemberAccount
    @State private var showingLeaveSheet = false
    var body: some View {
        List {
            Section { Text(verbatim: account.privateNodeNotice.isEmpty ? String(localized: "Opening your records.") : account.privateNodeNotice).accessibilityIdentifier("privateNodeStatus") }
            if account.privateNodeState == .locked && !account.privateNodeNotice.isEmpty && !account.privateNodeKeyMismatch {
                Section { Button("Try again") { Task { await account.retryPrivateNode() } }.accessibilityIdentifier("privateNodeRetry") }
            }
            if let recovery = account.recovery {
                Section { NavigationLink("Recovery") { MemberRecoveryView(model: recovery, recoveryRequired: account.privateNodeState == .recoveryRequired) } }
            }
            Section {
                Button("Sign out") { Task { await account.signOut() } }.accessibilityIdentifier("memberSignOut")
                Button("Delete account", role: .destructive) { showingLeaveSheet = true }.accessibilityIdentifier("memberDeleteAccount")
            }
            if let session = account.session {
                Section {
                    DisclosureGroup("About this account") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This account's records open only on the device where you first signed in.").font(.footnote)
                            Text("Account reference, for support").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: session.household).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Atarasy")
        .disabled(account.busy)
        .sheet(isPresented: $showingLeaveSheet) { NavigationStack { MemberLeaveSheet(account: account) } }
    }
}

// MARK: - Inbox

/// Overtures (`04b` §1b), called the Inbox on screen. Two sections, each newest arrival first
/// over every shop (clause 14), and a strip for what is waiting on the member. No price, no
/// ranking, no count of unread items and nothing that counts down.
struct MemberInboxView: View {
    @ObservedObject var account: MemberAccount
    @ObservedObject var proposals: MemberProposals
    var body: some View {
        List {
            if proposals.incomplete {
                Section { MemberBanner(text: String(localized: "Some shops could not be reached. This list may be incomplete.")).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                    .accessibilityIdentifier("memberSourcesIncomplete")
            }
            if !account.mandates.isEmpty {
                Section {
                    NavigationLink { MemberLimitsView(account: account) } label: {
                        Label { VStack(alignment: .leading, spacing: 2) { Text("Sign your limits"); Text("Nothing can be bought for you until you do.").font(.footnote).foregroundStyle(.secondary) } } icon: { Image(systemName: "signature").foregroundStyle(.orange) }
                    }.accessibilityIdentifier("inboxUnsignedLimits")
                }
            }
            section(title: "At home", subtitle: "Boxes delivered to you. Use what you like; you pay only for what you use.", binding: "physical", empty: "No boxes at home.")
            section(title: "Proposals", subtitle: "Nothing is bought unless you choose it and sign.", binding: "digital", empty: "No proposals here.")
            if proposals.sources.isEmpty && !proposals.loading {
                Section { Text("No shops are connected to this account yet.").foregroundStyle(.secondary).accessibilityIdentifier("memberNoSources") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Inbox")
        .overlay { if proposals.loading && proposals.sources.allSatisfy({ $0.offers.isEmpty }) { ProgressView("Checking your shops").accessibilityIdentifier("memberSourcesLoading") } }
        .refreshable { await proposals.refresh(); await account.refreshMandates() }
        .task(id: proposals.sessionIdentity) { await proposals.refresh(); await account.refreshMandates() }
        // Signing the limits is what lets a presenter deliver (a review shop presents its proposal in
        // the same request), so the list is read again when an unsigned version is signed, rather than
        // waiting for the member to pull. Measured on the founder's iPhone on 2026-09-23.
        .onChange(of: account.mandates.map(\.id)) { old, new in
            if new.count < old.count { Task { await proposals.refresh() } }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if let checked = proposals.sources.compactMap(\.verifiedAt).min() {
                    Text("Checked \(MemberFormat.date(checked).formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func section(title: LocalizedStringKey, subtitle: LocalizedStringKey, binding: String, empty: LocalizedStringKey) -> some View {
        let rows = proposals.rows(binding: binding)
        Section {
            if rows.isEmpty {
                // COPY-11: an empty section says so and suggests nothing to buy. A list still
                // loading, or whose every shop failed, is not empty and says that instead.
                if proposals.loading { Text("Checking…").foregroundStyle(.secondary) }
                else if proposals.anySourceChecked { Text(empty).foregroundStyle(.secondary).accessibilityIdentifier("emptySection-" + binding) }
                else if !proposals.sources.isEmpty { Text("Could not be checked.").foregroundStyle(.secondary) }
            }
            ForEach(rows, id: \.id) { offer in
                NavigationLink { MemberOfferScreen(account: account, proposals: proposals, selected: offer) } label: { MemberInboxRow(offer: offer) }
                    .accessibilityIdentifier("memberProposal-" + offer.id)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary).textCase(nil)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).textCase(nil)
            }.padding(.bottom, 2)
        }
    }
}

struct MemberInboxRow: View {
    let offer: MemberOfferSummary
    private var lines: [MemberOfferSummary.Line] { offer.candidates ?? [] }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: offer.binding == "physical" ? "shippingbox.fill" : "text.bubble.fill")
                .font(.title3).foregroundStyle(offer.needsMember ? AnyShapeStyle(MemberStyle.accent) : AnyShapeStyle(.secondary))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: headline).font(.headline).lineLimit(2)
                if !offer.merchants.isEmpty { Text(verbatim: offer.merchants.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                status.font(.subheadline).foregroundStyle(offer.needsMember ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
    private var headline: String {
        guard let first = lines.first else { return offer.binding == "physical" ? String(localized: "Box") : String(localized: "Proposal") }
        return lines.count == 1 ? first.title : String(localized: "\(first.title) and \(lines.count - 1) more")
    }
    @ViewBuilder private var status: some View {
        switch offer.rowStatus {
        case .atHome(let swap): if let swap { Text("Next swap \(MemberFormat.day(swap))") } else { Text("At home") }
        case .statementReady(let holds): Text(holds ? "Confirm the statement to receive the next box" : "Statement ready to confirm")
        case .boxClosed(let settled): Text(settled ? "Settled" : "Closed, nothing to pay")
        case .proposalOpen(let closes): if let closes { Text("Closes \(MemberFormat.day(closes)). Nothing is bought if you do nothing.") } else { Text("Waiting for your choice") }
        case .proposalDecided: Text("You decided")
        case .proposalClosed: Text("Closed")
        }
    }
}
