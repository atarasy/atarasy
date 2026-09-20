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
            if ProcessInfo.processInfo.arguments.contains("--member-permission-fixture") {
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
        .navigationTitle("Member account")
        .onAppear { holder.account?.clearExpired(now: Int64(Date().timeIntervalSince1970 * 1000)) }
        .task {
            guard holder.account == nil else { return }
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
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MemberOperations", isDirectory: true)
                let store = try FileMemberOperationStore(directory: directory)
                let statements = MemberStatementFlow(environment: environment, service: service, passkeys: passkeys, store: store, diagnostic: { event in
                    #if ATARASY_DEVICE_ACCEPTANCE
                    print("ATARASY_DEVICE_ACCEPTANCE: approval stopped " + event)
                    #endif
                })
                let decisions = MemberDigitalFlow(environment: environment, service: service, passkeys: passkeys, store: store)
                let withdrawals = MemberWithdrawalFlow(environment: environment, service: service, passkeys: passkeys, store: store)
                holder.account = MemberAccount(service: service, passkeys: passkeys, statements: statements, decisions: decisions, withdrawals: withdrawals, permissions: MemberPermissions(service: service))
            } catch { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { holder.account?.clearExpired(now: Int64(Date().timeIntervalSince1970 * 1000)) } }
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
                if let permissions = account.permissions { Section { NavigationLink("Permissions") { MemberPermissionsView(model: permissions) } } }
                MemberMandateSection(account: account)
                MemberProposalSections(model: account.proposals, statements: account.statements, decisions: account.decisions)
                if let statements = account.statements { SavedMemberOperationSections(flow: statements) }
                if let withdrawals = account.withdrawals { SavedMemberWithdrawalSections(flow: withdrawals) }
                if let decisions = account.decisions { SavedMemberDecisionSections(flow: decisions, withdrawals: account.withdrawals) }
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
