import Foundation
import Combine

public protocol MemberAccountService: MemberProposalService {
    func registrationOptions(invitation: String) async throws -> MemberCeremony
    func loginOptions() async throws -> MemberCeremony
    func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo
    func restore(household: String) async throws -> MemberSessionInfo?
    func logout() async throws -> MemberLogoutOutcome
}
extension MemberClient: MemberAccountService {}

@MainActor public final class MemberAccount: ObservableObject {
    @Published public private(set) var session: MemberSessionInfo? { didSet { statements?.setSession(session) } }
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    public let statements: MemberStatementFlow?
    public let proposals: MemberProposals
    private let service: any MemberAccountService
    private let passkeys: any MemberPasskeyAuthorising
    private var generation: UInt64 = 0
    public init(service: any MemberAccountService, passkeys: any MemberPasskeyAuthorising, statements: MemberStatementFlow? = nil) {
        self.service = service; self.passkeys = passkeys; self.statements = statements
        proposals = MemberProposals(service: service)
        proposals.onSessionUnavailable = { [weak self] in
            guard let self else { return }
            self.generation &+= 1; self.session = nil
            self.notice = "Your session is no longer available. Sign in again."
        }
    }
    // Closing hides late results. A verification already sent can still complete on the service.
    public func close() { generation &+= 1; session = nil; proposals.setSession(nil); notice = "" }
    public func clearExpired(now: Int64) {
        if let session, session.expiresAt <= now { self.session = nil; proposals.setSession(nil); notice = "Your session expired. Sign in again." }
    }
    private func message(_ error: Error) -> String {
        switch error {
        case is CancellationError, NativePasskeyFailure.cancelled: return "Passkey operation cancelled. No verification was submitted."
        case MemberFailure.uncertainVerification: return "The verification result could not be confirmed. Do not repeat the same request. Try a new sign-in, or obtain a new invitation for registration."
        case MemberFailure.remoteLogoutUnconfirmed: return "Signed out on this device. Server revocation could not be confirmed."
        case MemberFailure.storage: return "Secure session storage could not be updated. Sign-out may be incomplete on this device."
        case MemberFailure.expired, MemberFailure.http(401): return "Your session or request is no longer available. Start again."
        default: return "This request could not be completed. Check your connection and try a new request."
        }
    }
    private func run(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; notice = ""; let started = generation
        defer { busy = false }
        do { try await work() }
        catch { if started == generation { notice = message(error) } }
    }
    public func enrol(invitation: String) async {
        guard session == nil else { return }
        await run {
            let started = generation
            let ceremony = try await service.registrationOptions(invitation: invitation)
            try Task.checkCancellation(); guard started == generation else { return }
            let response = try await passkeys.authorise(ceremony, kind: .registration)
            try Task.checkCancellation(); guard started == generation else { return }
            try await service.register(ceremony: ceremony, response: response)
            guard started == generation else { return }
            notice = "Passkey registered. Sign in to open your session."
        }
    }
    public func signIn() async {
        guard session == nil else { return }
        await run {
            let started = generation
            let ceremony = try await service.loginOptions()
            try Task.checkCancellation(); guard started == generation else { return }
            let response = try await passkeys.authorise(ceremony, kind: .assertion)
            try Task.checkCancellation(); guard started == generation else { return }
            let info = try await service.login(ceremony: ceremony, response: response)
            guard started == generation else { return }
            session = info; proposals.setSession(info); notice = "Signed in."
        }
    }
    public func restore(household: String) async {
        guard session == nil else { return }
        await run {
            let started = generation
            let info = try await service.restore(household: household)
            guard started == generation else { return }
            session = info; proposals.setSession(info); notice = info == nil ? "No saved session was found for this household." : "Saved session verified."
        }
    }
    public func signOut() async {
        await run {
            session = nil; proposals.setSession(nil)
            let started = generation
            let result = try await service.logout()
            guard started == generation else { return }
            notice = switch result { case .revoked: "Signed out."; case .noLocalSession: "No active session on this device." }
        }
    }
}
