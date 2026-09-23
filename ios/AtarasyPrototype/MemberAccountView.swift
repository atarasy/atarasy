import SwiftUI
import AtarasyCore
import UIKit
import Combine
import UniformTypeIdentifiers

// Configuration is bundled by the trusted build, never supplied by an invitation or deep link.
private func configuredMemberEnvironment() -> MemberEnvironment? {
    guard let name = Bundle.main.object(forInfoDictionaryKey: "AtarasyMemberEnvironment") as? String,
          let origin = Bundle.main.object(forInfoDictionaryKey: "AtarasyMemberOrigin") as? String,
          let url = URL(string: origin) else { return nil }
    return try? MemberEnvironment(name: name, origin: url)
}
private func configuredMoveTargetEnvironment() -> MemberEnvironment? {
    guard let name = Bundle.main.object(forInfoDictionaryKey: "AtarasyMoveTargetEnvironment") as? String,
          let origin = Bundle.main.object(forInfoDictionaryKey: "AtarasyMoveTargetOrigin") as? String,
          let url = URL(string: origin) else { return nil }
    return try? MemberEnvironment(name: name, origin: url)
}
private func configuredAPNSEnvironment() -> MemberAPNSEnvironment? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "AtarasyAPNSEnvironment") as? String else { return nil }
    return MemberAPNSEnvironment(rawValue: value)
}
@MainActor final class MemberWindow: ObservableObject { weak var window: UIWindow? }
// Owned by the view that presents the sheet. Dismissing the sheet used to discard the
// account while the server session stayed live, so the member had to sign in again.
@MainActor final class MemberAccountHolder: ObservableObject {
    @Published var account: MemberAccount?
    @Published var apnsToken: Data?
    let window = MemberWindow()
}
private struct MemberWindowReader: UIViewRepresentable {
    let reference: MemberWindow
    final class Probe: UIView {
        var reference: MemberWindow?
        // A pushed screen takes this probe off the window. Keep the last window so a
        // statement approval on that screen still has an anchor for the passkey sheet.
        override func didMoveToWindow() { super.didMoveToWindow(); if let window { reference?.window = window } }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.reference = reference; return view }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.reference = reference }
}
#if ATARASY_RELEASE
/// The Production `WindowGroup` root. There is no sample inbox in this configuration
/// (App.swift excludes it under `ATARASY_RELEASE`), so the member account is the app
/// itself: a `NavigationStack`, not a sheet, with no "Done" that would dismiss into a
/// screen that does not exist here.
struct MemberProductionRootView: View {
    @StateObject private var holder = MemberAccountHolder()
    var body: some View {
        NavigationStack {
            if let environment = configuredMemberEnvironment() {
                ConfiguredMemberAccount(environment: environment, holder: holder)
            } else {
                ContentUnavailableView("Member sign-in unavailable", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("This app is not yet connected to a member host on this device."))
                    .accessibilityIdentifier("memberUnconfigured")
                    .navigationTitle("Member account")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atarasyAPNSToken)) { if let token = $0.object as? Data { holder.apnsToken = token } }
    }
}
#endif
struct MemberAccountSheet: View {
    @ObservedObject var holder: MemberAccountHolder
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            #if ATARASY_UI_TEST_FIXTURES
            if ProcessInfo.processInfo.arguments.contains("--member-dials-fixture") {
                MemberDialsFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--member-request-fixture") {
                MemberRequestFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--member-permission-fixture") {
                MemberPermissionFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--member-withdrawal-fixture") {
                MemberWithdrawalFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--member-digital-fixture") {
                MemberDigitalFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--member-statement-fixture") {
                MemberStatementFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("--member-list-fixture") {
                MemberProposalFixtureView()
            } else { configuredContent }
            #else
            configuredContent
            #endif
        }
    }
    @ViewBuilder private var configuredContent: some View {
            if let environment = configuredMemberEnvironment() {
                ConfiguredMemberAccount(environment: environment, holder: holder)
            } else {
                ContentUnavailableView("Member sign-in unavailable", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("This build is not connected to a member service. You can continue exploring the sample proposals."))
                    .accessibilityIdentifier("memberUnconfigured")
                    .navigationTitle("Member account")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("memberDone") } }
            }
    }
}
private struct ConfiguredMemberAccount: View {
    let environment: MemberEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var holder: MemberAccountHolder
    private var refreshRegistrationID: String {
        guard let session = holder.account?.session, let token = holder.apnsToken, let environment = configuredAPNSEnvironment() else { return "unavailable" }
        return session.id + ":" + token.base64EncodedString() + ":" + environment.rawValue
    }
    var body: some View {
        Group {
            if let account = holder.account { MemberAccountForm(account: account) }
            else { ProgressView("Opening member account") }
        }
        .background(MemberWindowReader(reference: holder.window).frame(width: 0, height: 0))
        .overlay { if scenePhase != .active { Color(uiColor: .systemBackground).ignoresSafeArea().accessibilityHidden(true) } }
        .navigationTitle("Member account")
        .onAppear { holder.account?.clearExpired(now: Int64(Date().timeIntervalSince1970 * 1000)) }
        .task(id: scenePhase) {
            guard scenePhase == .active, holder.account == nil else { return }
            do {
                let base = try URLSessionMemberTransport(timeout: 30, maximumResponseBytes: 8_000_000)
                let transport: any MemberHTTPTransport
                #if ATARASY_DEVICE_ACCEPTANCE
                if ProcessInfo.processInfo.arguments.contains("--acceptance-drop-statement-response") {
                    transport = try DevelopmentResponseLossTransport(base: base, environment: environment) {
                        // Only a non-secret event marker; never log the response or request.
                        print("ATARASY_DEVICE_ACCEPTANCE: discarded one successful statement response")
                    }
                } else { transport = base }
                #else
                transport = base
                #endif
                let vault = try KeychainMemberSessionVault(namespace: "dev.atarasy.native")
                let service = MemberClient(environment: environment, transport: transport, vault: vault)
                let reference = holder.window
                let passkeys = NativePasskeyAuthoriser(environment: environment, anchor: { [weak reference] in reference?.window })
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let installation = try MemberInstallationIdentity(file: support.appendingPathComponent("installation-id"))
                let keys = try KeychainMemberOperationKeyVault(namespace: "dev.atarasy.native", installation: installation)
                let store = try ProtectedFileMemberOperationStore(directory: support.appendingPathComponent("MemberOperations", isDirectory: true), environment: environment, vault: keys)
                let statements = MemberStatementFlow(environment: environment, service: service, passkeys: passkeys, store: store, diagnostic: { event in
                    #if ATARASY_DEVICE_ACCEPTANCE
                    print("ATARASY_DEVICE_ACCEPTANCE: approval stopped " + event)
                    #endif
                })
                let decisions = MemberDigitalFlow(environment: environment, service: service, passkeys: passkeys, store: store)
                let withdrawals = MemberWithdrawalFlow(environment: environment, service: service, passkeys: passkeys, store: store)
                let privateNode = MemberPrivateNode(environment: environment, service: service, vault: keys)
                let recoveryVault = try KeychainMemberRecoveryMaterialVault(namespace: "dev.atarasy.native", installation: installation)
                let noticeChannel = Bundle.main.object(forInfoDictionaryKey: "AtarasyRecoveryNoticeChannel") as? String
                let recovery = MemberRecoveryFlow(environment: environment, service: service, privateNode: privateNode, passkeys: passkeys, vault: recoveryVault, noticeChannel: noticeChannel)
                var hostMove: MemberHostMoveFlow?
                if let targetEnvironment = configuredMoveTargetEnvironment(), targetEnvironment != environment {
                    let targetTransport = try URLSessionMemberTransport(timeout: 30, maximumResponseBytes: 8_000_000), targetService = MemberClient(environment: targetEnvironment, transport: targetTransport, vault: vault)
                    let targetPasskeys = NativePasskeyAuthoriser(environment: targetEnvironment, anchor: { [weak reference] in reference?.window }), targetNode = MemberPrivateNode(environment: targetEnvironment, service: targetService, vault: keys)
                    hostMove = MemberHostMoveFlow(sourceEnvironment: environment, targetEnvironment: targetEnvironment, source: service, target: targetService, sourceNode: privateNode, targetNode: targetNode, sourcePasskeys: passkeys, targetPasskeys: targetPasskeys)
                }
                holder.account = MemberAccount(service: service, passkeys: passkeys, statements: statements, decisions: decisions, withdrawals: withdrawals, permissions: MemberPermissions(service: service), permissionRequests: MemberPermissionRequests(service: service), privateNode: privateNode, recovery: recovery, hostMove: hostMove, operations: store)
            } catch { dismiss() }
        }
        .task(id: refreshRegistrationID) {
            guard scenePhase == .active, let account = holder.account, account.session != nil, let token = holder.apnsToken, let environment = configuredAPNSEnvironment() else { return }
            await account.registerRefresh(token: token, apnsEnvironment: environment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .atarasyRefreshHint)) { notification in
            guard scenePhase == .active, let data = notification.object as? Data, let account = holder.account else { return }
            Task { await account.receiveRefreshHint(data) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { holder.account?.clearExpired(now: Int64(Date().timeIntervalSince1970 * 1000)) }
            else if phase == .background { holder.account?.lock(); holder.account = nil }
        }
    }
}
private struct MemberAccountForm: View {
    @ObservedObject var account: MemberAccount
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    @State private var household = ""
    @State private var action: Task<Void, Never>?
    @State private var showingLeaveSheet = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func perform(_ work: @escaping @MainActor () async -> Void) {
        guard action == nil else { return }
        action = Task { await work(); action = nil }
    }
    var body: some View {
        Form {
            if let session = account.session {
                Section("Your session") {
                    Text(session.household).textSelection(.enabled)
                    Text("Expires \(Date(timeIntervalSince1970: Double(session.expiresAt) / 1000).formatted())")
                    Button("Sign out") { perform { await account.signOut() } }.accessibilityIdentifier("memberSignOut")
                    Button("Delete account", role: .destructive) { showingLeaveSheet = true }.accessibilityIdentifier("memberDeleteAccount")
                }
                Section("Private node") {
                    Text(account.privateNodeNotice.isEmpty ? "Private records have not been opened." : account.privateNodeNotice).accessibilityIdentifier("privateNodeStatus")
                    if let recovery = account.recovery { NavigationLink("Recovery") { MemberRecoveryView(model: recovery, recoveryRequired: account.privateNodeState == .recoveryRequired) } }
                    if let hostMove = account.hostMove { NavigationLink("Exit / Move Host") { MemberHostMoveView(model: hostMove) }.disabled(account.privateNodeState != .ready) }
                }
                if account.protectedAccessReady {
                    if !account.refreshNotice.isEmpty { Section("Updates") { Text(account.refreshNotice).accessibilityIdentifier("memberRefreshNotice") } }
                    if let requests = account.permissionRequests { Section { NavigationLink("Access requests") { MemberPermissionRequestsView(model: requests) } } }
                    if let permissions = account.permissions { Section { NavigationLink("Permissions") { MemberPermissionsView(model: permissions) } } }
                    MemberDialsSection(account: account)
                    MemberMandateSection(account: account)
                    MemberProposalSections(model: account.proposals, statements: account.statements, decisions: account.decisions)
                    if let statements = account.statements { SavedMemberOperationSections(flow: statements) }
                    if let withdrawals = account.withdrawals { SavedMemberWithdrawalSections(flow: withdrawals) }
                    if let decisions = account.decisions { SavedMemberDecisionSections(flow: decisions, withdrawals: account.withdrawals) }
                }
            } else {
                Section {
                    Button("Sign in with a passkey") { perform { await account.signIn() } }.accessibilityIdentifier("memberSignIn")
                }
                Section("Join with an invitation") {
                    SecureField("Invitation", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Register a passkey") {
                        let supplied = invitation; invitation = ""
                        perform { await account.enrol(invitation: supplied) }
                    }.disabled(invitation.isEmpty).accessibilityIdentifier("memberEnrol")
                }
                Section("Restore a saved session") {
                    TextField("Household reference", text: $household).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Use the reference shown in your previous session. It does not grant access by itself.").font(.footnote)
                    Button("Restore session") { let selected = household; perform { await account.restore(household: selected) } }.disabled(household.isEmpty).accessibilityIdentifier("memberRestore")
                }
            }
            if account.busy { ProgressView("Waiting for your request") }
            if !account.notice.isEmpty { Section { Text(account.notice).accessibilityIdentifier("memberNotice") } }
        }
        .disabled(account.busy || action != nil)
        .interactiveDismissDisabled(account.busy || action != nil)
        // In Production this form is the WindowGroup root, not a presented sheet: there is
        // nothing to dismiss into, so no "Done" is offered there.
        #if !ATARASY_RELEASE
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(account.busy || action != nil) } }
        #endif
        .onReceive(clock) { date in account.clearExpired(now: Int64(date.timeIntervalSince1970 * 1000)) }
        .onDisappear { invitation = ""; household = ""; action?.cancel() }
        .sheet(isPresented: $showingLeaveSheet) { NavigationStack { MemberLeaveSheet(account: account) } }
    }
}

private struct MemberExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// §14.3. Apple Guideline 5.1.1(v): account deletion, reachable from "Your session" beside
/// "Sign out". Mirrors the host-move ceremony: load a status, review a blocker list or
/// review-then-sign-then-submit, and show the result.
private struct MemberLeaveSheet: View {
    @ObservedObject var account: MemberAccount
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var exportDocument: MemberExportDocument?
    @State private var exportFilename = "atarasy-export.json"
    @State private var showingExporter = false
    var body: some View {
        Form {
            switch account.leavePhase {
            case .idle, .checkingStatus:
                Section { ProgressView("Checking your account") }
            case .blocked:
                Section("This account cannot be deleted yet") {
                    if account.leaveBlockers.isEmpty { Text("Something is holding this account open.").accessibilityIdentifier("leaveBlockerRow") }
                    ForEach(Array(account.leaveBlockers.enumerated()), id: \.offset) { _, blocker in
                        Text(Self.blockerDescription(blocker)).accessibilityIdentifier("leaveBlockerRow")
                    }
                    Button("Check again") { Task { await account.refreshLeaveStatus() } }.accessibilityIdentifier("leaveRecheck")
                }
            case .ready, .signing:
                Section("Before you delete") {
                    Text("Deleting removes your account and everything this host holds for it. Shops keep their own records of sales. Gifts you shared with other households stay in their records, showing you as a member who has left.")
                    Button("Save a copy of my records") { Task { await account.requestExport() } }
                        .disabled(account.leavePhase == .signing)
                        .accessibilityIdentifier("leaveExport")
                    if !account.leaveExportNotice.isEmpty { Text(account.leaveExportNotice).font(.footnote).accessibilityIdentifier("leaveExportNotice") }
                }
                Section {
                    Button("Delete account", role: .destructive) { confirmingDelete = true }
                        .disabled(account.leavePhase == .signing)
                        .accessibilityIdentifier("leaveDelete")
                    if account.leavePhase == .signing { ProgressView() }
                }
                .confirmationDialog("Delete this account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete account", role: .destructive) { Task { await account.deleteAccount() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone. You will be asked to confirm with your passkey.")
                }
            case .done:
                Section("Account deleted") {
                    Text(account.leaveNotice).accessibilityIdentifier("leaveDoneNotice")
                    Button("Done") { dismiss() }.accessibilityIdentifier("leaveDone")
                }
            case .failed:
                Section("Account deletion") {
                    Text(account.leaveNotice).accessibilityIdentifier("leaveFailedNotice")
                    Button("Refresh account status") { Task { await account.refreshLeaveStatus() } }.accessibilityIdentifier("leaveRecheck")
                }
            }
        }
        .navigationTitle("Delete account")
        .interactiveDismissDisabled(account.leavePhase == .signing)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() }.disabled(account.leavePhase == .signing).accessibilityIdentifier("leaveClose") } }
        .task { await account.refreshLeaveStatus() }
        .onChange(of: account.leaveExport?.exportedAt) { _, exportedAt in
            guard exportedAt != nil, let export = account.leaveExport, let data = try? export.fileContents() else { return }
            exportFilename = "atarasy-export-\(Self.exportDateStamp()).json"
            exportDocument = MemberExportDocument(data: data)
            showingExporter = true
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .json, defaultFilename: exportFilename) { _ in }
    }
    private static func exportDateStamp() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
    private static func blockerDescription(_ blocker: MemberLeaveBlocker) -> String {
        switch blocker.kind {
        case "offer_in_progress": return "A box or order is still open. Finish or decline it first."
        case "statement_unsigned": return "A settlement statement is waiting for your signature."
        case "reservation_held": return "A reservation is still held against your account."
        case "gift_in_flight": return "A gift to or from this household is still in flight."
        case "permission_action_pending": return "A permission request is still pending a decision."
        case "co_signer": return "You co-sign another household's shopping mandate. Step down first."
        case "recoverer": return "You help another household recover its account. Step down first."
        case "host_move_pending": return "A host move is in progress for this account."
        case "operation_pending": return "An operation is still awaiting its outcome."
        case "mandate_change_pending": return "A change to a mandate is still pending signatures."
        case "recovery_request_pending": return "A recovery request involving this household is still pending."
        case "permission_request_pending": return "A permission request involving this household is still pending."
        default: return "Blocked: \(blocker.kind)."
        }
    }
}

private struct MemberHostMoveView: View {
    @ObservedObject var model: MemberHostMoveFlow
    var body: some View {
        Form {
            Section("Target") {
                Text("The configured target host must be trusted by this build. You will sign in there before anything is copied.")
                Text(model.phase.rawValue).font(.headline).accessibilityIdentifier("hostMovePhase")
            }
            Section("Coverage") {
                Text(model.coverage.isEmpty ? "Coverage has not been verified on the target host." : model.coverage)
                if let receipt = model.targetReceipt { Text("Receipt: \(receipt.archiveDigest)").font(.footnote).textSelection(.enabled) }
            }
            Section("Rollback") {
                Text(model.phase == .readyToRetire ? "The target is verified. Source access remains active until the final signed retirement." : "A failed or interrupted import does not retire source access.")
            }
            Section {
                Button("Import and verify target") { Task { await model.prepare() } }.disabled([.signingIntoTarget, .exporting, .importing, .verifying, .retiring, .completed, .readyToRetire].contains(model.phase)).accessibilityIdentifier("hostMovePrepare")
                if model.phase == .readyToRetire { Button("Retire source host access", role: .destructive) { Task { await model.retireSource() } }.accessibilityIdentifier("hostMoveRetire") }
                if [.signingIntoTarget, .exporting, .importing, .verifying, .retiring].contains(model.phase) { ProgressView() }
                if !model.notice.isEmpty { Text(model.notice).accessibilityIdentifier("hostMoveNotice") }
            }
        }
        .navigationTitle("Move Host")
        .interactiveDismissDisabled([.importing, .verifying, .retiring].contains(model.phase))
    }
}

private struct MemberRecoveryView: View {
    @ObservedObject var model: MemberRecoveryFlow
    let recoveryRequired: Bool
    @State private var recoverer = ""
    var body: some View {
        Form {
            Section("Recovery role") {
                if model.keyStatus?.publicKey == nil { Text("This device has no recovery-only encryption key.") }
                else { Label("This device can receive a named recovery share", systemImage: "checkmark.shield") }
                Button("Enable this device as a recoverer") { Task { await model.registerRecoveryKey() } }
                    .disabled(model.busy || model.keyStatus?.publicKey != nil)
                    .accessibilityIdentifier("recoveryRegisterDevice")
            }
            Section("Your recovery policy") {
                if let configuration = model.configuration, configuration.configured {
                    Text("Two participants are required: your device, the named recoverer, or the host.")
                    Text("Recoverer: \(configuration.recoverer ?? "Unavailable")").font(.footnote).textSelection(.enabled)
                    Text("Policy version \(configuration.epoch ?? 0)").font(.footnote)
                } else { Text("Recovery has not been configured.") }
                TextField("Recoverer household reference", text: $recoverer).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Review and configure recovery") { let value = recoverer; Task { await model.configure(recoverer: value) } }
                    .disabled(model.busy || recoverer.isEmpty || !model.canConfigure)
                    .accessibilityIdentifier("recoveryConfigure")
                if !model.canConfigure { Text("This build has no independently delivered recovery notice channel, so recovery configuration remains closed.").font(.footnote) }
            }
            if recoveryRequired {
                Section("Restore this device") {
                    Text("A recovered passkey does not restore the encrypted records by itself.")
                    Button("Begin lost-device recovery") { Task { await model.beginLostDeviceRecovery() } }.disabled(model.busy).accessibilityIdentifier("recoveryBegin")
                }
            }
            Section("Ceremonies") {
                if model.requests.isEmpty { Text("No recovery ceremony is visible to this account.") }
                ForEach(model.requests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.state.capitalized).font(.headline)
                        Text(request.owner == model.currentHousehold ? "Your recovery" : "Recovery requested by a person who named you").font(.subheadline)
                        Text("Policy version \(request.epoch)").font(.footnote)
                        if request.recoverer == model.currentHousehold, request.state == "pending" {
                            Button("Review and approve recovery") { Task { await model.approve(request) } }.buttonStyle(.borderless).accessibilityIdentifier("recoveryApprove")
                        }
                        if request.owner == model.currentHousehold, request.state == "completed" {
                            Button("Install recovered key") { Task { await model.finish(request) } }.buttonStyle(.borderless).accessibilityIdentifier("recoveryFinish")
                        }
                        if request.owner == model.currentHousehold, request.state == "approved" { Text("The recoverer approved. The key remains unavailable until the independent notice is delivered.").font(.footnote) }
                    }
                }
            }
            Section("Recovery record") {
                if let events = model.log?.events, !events.isEmpty {
                    ForEach(events) { event in Text(event.state == "completed" ? "Notice delivered before recovery completed" : "Recovery recorded; notice delivery pending") }
                } else { Text("No completed or pending recovery event.") }
            }
            Section {
                Button("Refresh recovery status") { Task { await model.refresh() } }.disabled(model.busy)
                if model.busy { ProgressView() }
                if !model.notice.isEmpty { Text(model.notice).accessibilityIdentifier("recoveryNotice") }
            }
        }
        .navigationTitle("Recovery")
        .onAppear { Task { await model.refresh() } }
    }
}
