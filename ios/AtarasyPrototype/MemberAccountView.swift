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
@MainActor private final class MemberWindow: ObservableObject { weak var window: UIWindow? }
private struct MemberWindowReader: UIViewRepresentable {
    let reference: MemberWindow
    final class Probe: UIView {
        var reference: MemberWindow?
        override func didMoveToWindow() { super.didMoveToWindow(); reference?.window = window }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.reference = reference; return view }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.reference = reference }
}
struct MemberAccountSheet: View {
    @State private var account: MemberAccount?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            #if ATARASY_UI_TEST_FIXTURES
            if ProcessInfo.processInfo.arguments.contains("--member-list-fixture") {
                MemberProposalFixtureView()
            } else { configuredContent }
            #else
            configuredContent
            #endif
        }
        .onDisappear { account?.close() }
    }
    @ViewBuilder private var configuredContent: some View {
            if let environment = configuredMemberEnvironment() {
                ConfiguredMemberAccount(environment: environment, account: $account)
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
    @StateObject private var window = MemberWindow()
    @Binding var account: MemberAccount?
    var body: some View {
        Group {
            if let account { MemberAccountForm(account: account) }
            else { ProgressView("Opening member account") }
        }
        .background(MemberWindowReader(reference: window).frame(width: 0, height: 0))
        .navigationTitle("Member account")
        .task {
            guard account == nil else { return }
            do {
                let transport = try URLSessionMemberTransport(timeout: 30, maximumResponseBytes: 1_048_576)
                let vault = try KeychainMemberSessionVault(namespace: "dev.atarasy.native")
                let service = MemberClient(environment: environment, transport: transport, vault: vault)
                let reference = window
                let passkeys = NativePasskeyAuthoriser(environment: environment, anchor: { [weak reference] in reference?.window })
                account = MemberAccount(service: service, passkeys: passkeys)
            } catch { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { account?.clearExpired(now: Int64(Date().timeIntervalSince1970 * 1000)) } }
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
                MemberProposalSections(model: account.proposals)
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
