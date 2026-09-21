import SwiftUI
import AtarasyCore
import UIKit
import Combine

// Configuration is bundled by the trusted build, never supplied by an invitation or deep link.
private func configuredMemberEnvironment() -> MemberEnvironment? {
    guard let name = Bundle.main.object(forInfoDictionaryKey: "AtarasyMemberEnvironment") as? String,
          let origin = Bundle.main.object(forInfoDictionaryKey: "AtarasyMemberOrigin") as? String,
          let url = URL(string: origin) else { return nil }
    return try? MemberEnvironment(name: name, origin: url)
}
@MainActor final class MemberWindow: ObservableObject { weak var window: UIWindow? }
// Owned by the view that presents the sheet. Dismissing the sheet used to discard the
// account while the server session stayed live, so the member had to sign in again.
@MainActor final class MemberAccountHolder: ObservableObject {
    @Published var account: MemberAccount?
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
                let base = try URLSessionMemberTransport(timeout: 30, maximumResponseBytes: 1_048_576)
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
                holder.account = MemberAccount(service: service, passkeys: passkeys, statements: statements, decisions: decisions, withdrawals: withdrawals, permissions: MemberPermissions(service: service), permissionRequests: MemberPermissionRequests(service: service), privateNode: privateNode, recovery: recovery)
            } catch { dismiss() }
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
                }
                Section("Private node") {
                    Text(account.privateNodeNotice.isEmpty ? "Private records have not been opened." : account.privateNodeNotice).accessibilityIdentifier("privateNodeStatus")
                    if let recovery = account.recovery { NavigationLink("Recovery") { MemberRecoveryView(model: recovery, recoveryRequired: account.privateNodeState == .recoveryRequired) } }
                }
                if account.protectedAccessReady {
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
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(account.busy || action != nil) } }
        .onReceive(clock) { date in account.clearExpired(now: Int64(date.timeIntervalSince1970 * 1000)) }
        .onDisappear { invitation = ""; household = ""; action?.cancel() }
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
