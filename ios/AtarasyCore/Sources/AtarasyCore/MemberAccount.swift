import Foundation
import Combine

public protocol MemberAccountService: MemberProposalService {
    func registrationOptions(invitation: String) async throws -> MemberCeremony
    func loginOptions() async throws -> MemberCeremony
    func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo
    func restore(household: String) async throws -> MemberSessionInfo?
    func unsignedMandates() async throws -> [MemberMandate]
    func prepareMandate(_ selected: MemberMandate) async throws -> MemberMandateReview
    func submitMandate(_ review: MemberMandateReview, assertion: MemberPasskeyResponse) async throws
    func effectiveMandates() async throws -> [MemberMandate]
    func mandateChanges() async throws -> [MemberMandateChange]
    func prepareMandateChange(_ mandate: MemberMandate) async throws -> PreparedMemberMandateChange
    func prepareMandateSignature(_ id: String) async throws -> PreparedMemberMandateChange
    func submitMandateChange(_ prepared: PreparedMemberMandateChange, assertion: MemberPasskeyResponse) async throws -> MemberMandateChange
    func cancelMandateChange(_ id: String) async throws -> MemberMandateChange
    func logout() async throws -> MemberLogoutOutcome
    func lockLocalAccess() async
}
extension MemberClient: MemberAccountService {}
public extension MemberAccountService {
    func unsignedMandates() async throws -> [MemberMandate] { throw MemberFailure.unavailable }
    func prepareMandate(_ selected: MemberMandate) async throws -> MemberMandateReview { throw MemberFailure.unavailable }
    func submitMandate(_ review: MemberMandateReview, assertion: MemberPasskeyResponse) async throws { throw MemberFailure.unavailable }
    func effectiveMandates() async throws -> [MemberMandate] { throw MemberFailure.unavailable }
    func mandateChanges() async throws -> [MemberMandateChange] { throw MemberFailure.unavailable }
    func prepareMandateChange(_ mandate: MemberMandate) async throws -> PreparedMemberMandateChange { throw MemberFailure.unavailable }
    func prepareMandateSignature(_ id: String) async throws -> PreparedMemberMandateChange { throw MemberFailure.unavailable }
    func submitMandateChange(_ prepared: PreparedMemberMandateChange, assertion: MemberPasskeyResponse) async throws -> MemberMandateChange { throw MemberFailure.unavailable }
    func cancelMandateChange(_ id: String) async throws -> MemberMandateChange { throw MemberFailure.unavailable }
    func lockLocalAccess() async {}
}

@MainActor public final class MemberAccount: ObservableObject {
    @Published public private(set) var session: MemberSessionInfo? { didSet { statements?.setSession(session); decisions?.setSession(session); withdrawals?.setSession(session); permissions?.setSession(session); permissionRequests?.setSession(session); recovery?.setSession(session); mandates = []; mandateReview = nil; effectiveMandates = []; mandateChanges = []; preparedMandateChange = nil; dialsNotice = ""; if session == nil { privateNodeState = .locked; privateNodeNotice = ""; if let privateNode { Task { await privateNode.lock() } } } } }
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    @Published public private(set) var mandates: [MemberMandate] = []
    @Published public private(set) var mandateReview: MemberMandateReview?
    @Published public private(set) var mandateNotice = ""
    @Published public private(set) var effectiveMandates: [MemberMandate] = []
    @Published public private(set) var mandateChanges: [MemberMandateChange] = []
    @Published public private(set) var preparedMandateChange: PreparedMemberMandateChange?
    @Published public private(set) var dialsNotice = ""
    @Published public private(set) var privateNodeState: MemberPrivateNodeState = .locked
    @Published public private(set) var privateNodeNotice = ""
    public let statements: MemberStatementFlow?
    public let permissionRequests: MemberPermissionRequests?
    public let permissions: MemberPermissions?
    public let withdrawals: MemberWithdrawalFlow?
    public let decisions: MemberDigitalFlow?
    public let proposals: MemberProposals
    public let recovery: MemberRecoveryFlow?
    private let privateNode: MemberPrivateNode?
    private let service: any MemberAccountService
    private let passkeys: any MemberPasskeyAuthorising
    private var generation: UInt64 = 0
    public init(service: any MemberAccountService, passkeys: any MemberPasskeyAuthorising, statements: MemberStatementFlow? = nil, decisions: MemberDigitalFlow? = nil, withdrawals: MemberWithdrawalFlow? = nil, permissions: MemberPermissions? = nil, permissionRequests: MemberPermissionRequests? = nil, privateNode: MemberPrivateNode? = nil, recovery: MemberRecoveryFlow? = nil) {
        self.service = service; self.passkeys = passkeys; self.statements = statements; self.decisions = decisions; self.withdrawals = withdrawals; self.permissions = permissions; self.permissionRequests = permissionRequests; self.privateNode = privateNode; self.recovery = recovery
        proposals = MemberProposals(service: service)
        proposals.onSessionUnavailable = { [weak self] in
            guard let self else { return }
            self.generation &+= 1; self.session = nil
            self.notice = "Your session is no longer available. Sign in again."
        }
    }
    // Closing hides late results. A verification already sent can still complete on the service.
    public func close() { generation &+= 1; session = nil; proposals.setSession(nil); privateNodeState = .locked; privateNodeNotice = ""; notice = "" }
    /// Clears all decrypted account state immediately. Service work is fenced separately so a
    /// response that arrives after device lock cannot repopulate this account object.
    public func lock() { close(); Task { await service.lockLocalAccess() } }
    public var protectedAccessReady: Bool { privateNode == nil || privateNodeState == .ready }
    private func openPrivateNode(_ info: MemberSessionInfo) async {
        guard let privateNode else { privateNodeState = .ready; return }
        privateNodeState = .locked; privateNodeNotice = "Opening encrypted private records."
        do {
            let result = try await privateNode.open(session: info); privateNodeState = result; await recovery?.refresh()
            privateNodeNotice = result == .ready ? "Private records are encrypted on this device before host storage." : "This node has encrypted records but this installation has no decryption key. Recovery is required."
        } catch { privateNodeState = .locked; privateNodeNotice = "Private records are unavailable. Protected actions remain closed." }
    }
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
            session = info; proposals.setSession(info); await openPrivateNode(info); notice = "Signed in."
        }
    }
    public func restore(household: String) async {
        guard session == nil else { return }
        await run {
            let started = generation
            let info = try await service.restore(household: household)
            guard started == generation else { return }
            session = info; proposals.setSession(info); if let info { await openPrivateNode(info) }; notice = info == nil ? "No saved session was found for this household." : "Saved session verified."
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
    public func refreshMandates() async {
        guard session != nil else { return }
        await run {
            let started = generation; mandateReview = nil; mandates = []; mandateNotice = ""
            let values = try await service.unsignedMandates()
            guard started == generation, session != nil else { return }
            mandates = values; mandateNotice = values.isEmpty ? "No unsigned mandates." : "Review each mandate before signing."
        }
    }
    public func reviewMandate(_ selected: MemberMandate) async {
        guard session != nil else { return }
        await run {
            let started = generation; mandateReview = nil; mandateNotice = ""
            let value = try await service.prepareMandate(selected)
            guard started == generation, session != nil else { return }
            mandateReview = value
        }
    }
    public func signMandate() async {
        guard let review = mandateReview, session != nil else { return }
        await run {
            let started = generation; mandateReview = nil
            let response = try await passkeys.authorise(review.ceremony, kind: .statement)
            try Task.checkCancellation()
            guard started == generation, session != nil else { return }
            do {
                try await service.submitMandate(review, assertion: response)
                guard started == generation, session != nil else { return }
                mandates.removeAll { $0.id == review.mandate.id }; mandateNotice = "Mandate signed."
            } catch {
                mandateNotice = "The result is unconfirmed. Refresh unsigned mandates before taking further action; do not repeat this submission."
                // This is not enrolment; do not suggest replacing a passkey.
                notice = "Mandate submission could not be confirmed. Inspect the current mandate state before trying again."
            }
        }
    }

    public func refreshDials() async {
        guard session != nil else { return }
        await run {
            do {
                let started = generation
                async let effective = service.effectiveMandates()
                async let changes = service.mandateChanges()
                let (current, pending) = try await (effective, changes)
                guard started == generation, session != nil else { return }
                effectiveMandates = current; mandateChanges = pending; preparedMandateChange = nil
                dialsNotice = current.isEmpty ? "No effective mandate is available." : "Effective protections are current."
            } catch { dialsNotice = dialsMessage(error); throw error }
        }
    }

    public func reviewMandateChange(_ mandate: MemberMandate) async {
        guard session != nil else { return }
        await run {
            do {
                let started = generation; let prepared = try await service.prepareMandateChange(mandate)
                guard started == generation, session != nil else { return }
                preparedMandateChange = prepared; upsert(prepared.change)
                dialsNotice = "Review the effective and proposed protections before signing."
            } catch { dialsNotice = dialsMessage(error); throw error }
        }
    }

    public func reviewPendingMandateChange(_ id: String) async {
        guard session != nil else { return }
        await run {
            do {
                let started = generation; let prepared = try await service.prepareMandateSignature(id)
                guard started == generation, session != nil else { return }
                preparedMandateChange = prepared; upsert(prepared.change)
                dialsNotice = "Review this fixed proposal before adding your signature."
            } catch { dialsNotice = dialsMessage(error); throw error }
        }
    }

    public func signPreparedMandateChange() async {
        guard let prepared = preparedMandateChange, session != nil else { return }
        await run {
            do {
                let started = generation
                let assertion = try await passkeys.authorise(prepared.ceremony, kind: .statement)
                try Task.checkCancellation()
                guard started == generation, session != nil else { return }
                preparedMandateChange = nil
                let result = try await service.submitMandateChange(prepared, assertion: assertion)
                guard started == generation, session != nil else { return }
                upsert(result)
                if result.state == "effective" {
                    effectiveMandates.removeAll { $0.id == result.mandate.id }
                    effectiveMandates.append(result.mandate)
                    effectiveMandates.sort { $0.id < $1.id }
                    dialsNotice = "Mandate version \(result.mandate.version) is effective."
                } else {
                    let missing = result.requiredSigners.filter { !result.signedBy.contains($0) }
                    dialsNotice = "Your signature was recorded. Waiting for \(missing.count) required signer\(missing.count == 1 ? "" : "s")."
                }
            } catch {
                if error as? MemberFailure == .uncertainVerification { preparedMandateChange = nil; dialsNotice = "The submission result is unconfirmed. Refresh Dials to read the existing change; do not sign a new version yet." }
                else { dialsNotice = dialsMessage(error) }
            }
        }
    }

    public func cancelMandateChange(_ id: String) async {
        guard session != nil else { return }
        await run {
            do {
                let result = try await service.cancelMandateChange(id)
                upsert(result); if preparedMandateChange?.change.id == id { preparedMandateChange = nil }
                dialsNotice = "The pending mandate change was cancelled. The effective version was not changed."
            } catch { dialsNotice = dialsMessage(error); throw error }
        }
    }

    private func upsert(_ change: MemberMandateChange) {
        mandateChanges.removeAll { $0.id == change.id }
        mandateChanges.append(change)
        mandateChanges.sort { $0.createdAt > $1.createdAt }
    }
    private func dialsMessage(_ error: Error) -> String {
        switch error {
        case MemberFailure.http(409): return "The effective mandate changed or another proposal is pending. Refresh Dials before editing again."
        case MemberFailure.http(422): return "These protections or signatures were refused. Review the limits, lapse, cooling period and required signers."
        case MemberFailure.http(401), MemberFailure.expired: return "Your session expired. Sign in again before changing protections."
        case is CancellationError, NativePasskeyFailure.cancelled: return "Signing cancelled. The effective mandate was not changed."
        default: return "Dials could not be refreshed. The effective mandate has not been changed."
        }
    }

}
