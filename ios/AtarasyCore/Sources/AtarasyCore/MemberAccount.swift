import Foundation
import Combine
import CryptoKit

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
    func registerRefresh(token: Data, apnsEnvironment: MemberAPNSEnvironment) async throws -> MemberRefreshSubscription
    func disableRefresh() async throws -> MemberRefreshSubscription
    /// §14.3. Apple Guideline 5.1.1(v) account deletion.
    func leaveStatus() async throws -> MemberLeaveStatus
    func prepareLeave() async throws -> PreparedMemberLeave
    func leave(_ prepared: PreparedMemberLeave, assertion: MemberPasskeyResponse) async throws -> MemberLeft
    func exportAccount() async throws -> MemberExport
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
    func registerRefresh(token: Data, apnsEnvironment: MemberAPNSEnvironment) async throws -> MemberRefreshSubscription { throw MemberFailure.unavailable }
    func disableRefresh() async throws -> MemberRefreshSubscription { throw MemberFailure.unavailable }
    func leaveStatus() async throws -> MemberLeaveStatus { throw MemberFailure.unavailable }
    func prepareLeave() async throws -> PreparedMemberLeave { throw MemberFailure.unavailable }
    func leave(_ prepared: PreparedMemberLeave, assertion: MemberPasskeyResponse) async throws -> MemberLeft { throw MemberFailure.unavailable }
    func exportAccount() async throws -> MemberExport { throw MemberFailure.unavailable }
}

public enum MemberLeavePhase: String, Sendable { case idle, checkingStatus, blocked, ready, signing, done, failed }

@MainActor public final class MemberAccount: ObservableObject {
    @Published public private(set) var session: MemberSessionInfo? { didSet { statements?.setSession(session); decisions?.setSession(session); withdrawals?.setSession(session); permissions?.setSession(session); permissionRequests?.setSession(session); recovery?.setSession(session); hostMove?.setSession(session); mandates = []; mandateReview = nil; effectiveMandates = []; mandateChanges = []; preparedMandateChange = nil; dialsNotice = ""; leavePhase = .idle; leaveBlockers = []; leaveResult = nil; leaveNotice = ""; leaveExport = nil; leaveExportNotice = ""; if session == nil { privateNodeState = .locked; privateNodeNotice = ""; refreshSubscription = nil; refreshNotice = ""; if let privateNode { Task { await privateNode.lock() } } } } }
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
    /// The host holds records this device's key cannot open, as opposed to a read that failed.
    @Published public private(set) var privateNodeKeyMismatch = false
    @Published public private(set) var refreshSubscription: MemberRefreshSubscription?
    @Published public private(set) var refreshNotice = ""
    @Published public private(set) var leavePhase: MemberLeavePhase = .idle
    @Published public private(set) var leaveBlockers: [MemberLeaveBlocker] = []
    @Published public private(set) var leaveResult: MemberLeft?
    @Published public private(set) var leaveNotice = ""
    @Published public private(set) var leaveExport: MemberExport?
    @Published public private(set) var leaveExportNotice = ""
    public let statements: MemberStatementFlow?
    public let permissionRequests: MemberPermissionRequests?
    public let permissions: MemberPermissions?
    public let withdrawals: MemberWithdrawalFlow?
    public let decisions: MemberDigitalFlow?
    public let proposals: MemberProposals
    public let recovery: MemberRecoveryFlow?
    public let hostMove: MemberHostMoveFlow?
    private let privateNode: MemberPrivateNode?
    private let service: any MemberAccountService
    private let passkeys: any MemberPasskeyAuthorising
    /// §14.3. The device's own journal, cleared when the account is deleted.
    private let operations: (any MemberOperationStore)?
    private var generation: UInt64 = 0
    public init(service: any MemberAccountService, passkeys: any MemberPasskeyAuthorising, statements: MemberStatementFlow? = nil, decisions: MemberDigitalFlow? = nil, withdrawals: MemberWithdrawalFlow? = nil, permissions: MemberPermissions? = nil, permissionRequests: MemberPermissionRequests? = nil, privateNode: MemberPrivateNode? = nil, recovery: MemberRecoveryFlow? = nil, hostMove: MemberHostMoveFlow? = nil, operations: (any MemberOperationStore)? = nil) {
        self.operations = operations
        self.service = service; self.passkeys = passkeys; self.statements = statements; self.decisions = decisions; self.withdrawals = withdrawals; self.permissions = permissions; self.permissionRequests = permissionRequests; self.privateNode = privateNode; self.recovery = recovery; self.hostMove = hostMove
        proposals = MemberProposals(service: service)
        proposals.onSessionUnavailable = { [weak self] in
            guard let self else { return }
            self.generation &+= 1; self.session = nil
            self.notice = L("You have been signed out. Sign in again.")
        }
        hostMove?.onRetired = { [weak self] in self?.generation &+= 1; self?.session = nil; self?.notice = L("Your data has moved. Sign in at the new host.") }
    }
    // Closing hides late results. A verification already sent can still complete on the service.
    public func close() { generation &+= 1; session = nil; proposals.setSession(nil); privateNodeState = .locked; privateNodeNotice = ""; notice = "" }
    /// Clears all decrypted account state immediately. Service work is fenced separately so a
    /// response that arrives after device lock cannot repopulate this account object.
    public func lock() { close(); Task { await service.lockLocalAccess() } }
    public var protectedAccessReady: Bool { privateNode == nil || privateNodeState == .ready }
    private func openPrivateNode(_ info: MemberSessionInfo) async {
        guard let privateNode else { privateNodeState = .ready; return }
        privateNodeState = .locked; privateNodeKeyMismatch = false; privateNodeNotice = L("Opening your records.")
        do {
            let result = try await privateNode.open(session: info); privateNodeState = result; await recovery?.refresh()
            privateNodeNotice = result == .ready ? L("Your records are encrypted on this device before they are stored.") : L("This device cannot open your encrypted records. Use Recovery to restore access.")
        } catch is CryptoKitError {
            // The records on the host were sealed with a key this device does not hold, typically
            // because another device signed in to the same household and set them up first. Nothing
            // here can make them readable; the way out is recovery or leaving and joining again.
            privateNodeState = .locked; privateNodeKeyMismatch = true
            privateNodeNotice = L("This device's key does not match your encrypted records. They may have been set up on another device. Use Recovery, or delete this account and join again with a new invitation.")
        } catch MemberFailure.scopeMismatch {
            privateNodeState = .locked; privateNodeKeyMismatch = true
            privateNodeNotice = L("This device's key does not match your encrypted records. They may have been set up on another device. Use Recovery, or delete this account and join again with a new invitation.")
        } catch { privateNodeState = .locked; privateNodeNotice = L("Your records could not be opened on this device. Check your connection and try again.") }
    }
    /// Opens the private node again for the current session, after a failure that may have been transient.
    public func retryPrivateNode() async {
        guard let session, !busy else { return }
        await openPrivateNode(session)
    }
    public func clearExpired(now: Int64) {
        if let session, session.expiresAt <= now { self.session = nil; proposals.setSession(nil); notice = L("Your sign-in expired. Sign in again.") }
    }
    private func message(_ error: Error) -> String {
        switch error {
        case is CancellationError, NativePasskeyFailure.cancelled: return L("Passkey cancelled. Nothing was sent.")
        case MemberFailure.uncertainVerification: return L("We could not confirm the result. Do not repeat it. Sign in again, or ask for a new invitation to register.")
        case MemberFailure.remoteLogoutUnconfirmed: return L("Signed out on this device. We could not confirm the sign-out on the server.")
        case MemberFailure.storage: return L("Secure storage on this device could not be updated. Sign-out may be incomplete here.")
        case MemberFailure.expired, MemberFailure.http(401): return L("This is no longer available. Start again.")
        default: return L("This could not be completed. Check your connection and try again.")
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
            notice = L("Passkey registered. Sign in to continue.")
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
            session = info; proposals.setSession(info); await openPrivateNode(info); notice = L("Signed in.")
        }
    }
    public func restore(household: String) async {
        guard session == nil else { return }
        await run {
            let started = generation
            let info = try await service.restore(household: household)
            guard started == generation else { return }
            session = info; proposals.setSession(info); if let info { await openPrivateNode(info) }; notice = info == nil ? L("No saved sign-in was found for this account.") : L("Signed in.")
        }
    }
    public func signOut() async {
        await run {
            if session != nil { _ = try? await service.disableRefresh() }
            session = nil; proposals.setSession(nil)
            let started = generation
            let result = try await service.logout()
            guard started == generation else { return }
            notice = switch result { case .revoked: L("Signed out."); case .noLocalSession: L("You were not signed in on this device.") }
        }
    }
    public func registerRefresh(token: Data, apnsEnvironment: MemberAPNSEnvironment) async {
        guard let expected = session?.id else { return }
        do {
            let value = try await service.registerRefresh(token: token, apnsEnvironment: apnsEnvironment)
            guard session?.id == expected else { return }
            refreshSubscription = value; refreshNotice = L("Update notifications are on. They never contain what was proposed.")
        } catch {
            guard session?.id == expected else { return }
            refreshSubscription = nil; refreshNotice = L("Update notifications are unavailable. Pull down to refresh.")
        }
    }
    @discardableResult public func receiveRefreshHint(_ data: Data) async -> Bool {
        guard MemberRefreshHint.validate(data), session != nil else { return false }
        proposals.markStale(); refreshNotice = L("Something new arrived. Checking your shops.")
        await proposals.refresh()
        guard session != nil else { refreshNotice = L("Access was refused while checking for updates. Sign in again."); return true }
        refreshNotice = proposals.incomplete ? L("Some shops could not be reached. This list may be incomplete.") : ""
        return true
    }
    public func refreshMandates() async {
        guard session != nil else { return }
        await run {
            let started = generation; mandateReview = nil; mandates = []; mandateNotice = ""
            let values = try await service.unsignedMandates()
            guard started == generation, session != nil else { return }
            mandates = values; mandateNotice = ""
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
                mandates.removeAll { $0.id == review.mandate.id }; mandateNotice = L("Your limits are signed and in effect.")
            } catch {
                mandateNotice = L("We could not confirm the result. Refresh before doing anything else, and do not sign again.")
                // This is not enrolment; do not suggest replacing a passkey.
                notice = L("We could not confirm your signature. Check your limits before trying again.")
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
                dialsNotice = ""
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
                dialsNotice = ""
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
                dialsNotice = ""
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
                    dialsNotice = L("The change to your limits is now in effect.")
                } else {
                    let missing = result.requiredSigners.filter { !result.signedBy.contains($0) }
                    dialsNotice = L("Your signature was recorded. Signatures still needed: \(missing.count)")
                }
            } catch {
                if error as? MemberFailure == .uncertainVerification { preparedMandateChange = nil; dialsNotice = L("We could not confirm the result. Refresh your limits to see the change, and do not sign a new one yet.") }
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
                dialsNotice = L("The change was cancelled. Your current limits are unchanged.")
            } catch { dialsNotice = dialsMessage(error); throw error }
        }
    }

    /// §14.3. Loads what would block deletion right now. Called when the deletion sheet
    /// opens, and again after a blocker is resolved elsewhere.
    public func refreshLeaveStatus() async {
        guard session != nil else { return }
        await run {
            let started = generation
            leavePhase = .checkingStatus; leaveBlockers = []; leaveNotice = ""
            let status = try await service.leaveStatus()
            guard started == generation, session != nil else { return }
            if status.blockers.isEmpty { leavePhase = .ready }
            else { leavePhase = .blocked; leaveBlockers = status.blockers }
        }
    }
    /// Prepares a fresh review, signs it with the passkey, and submits it. On success the
    /// session and every piece of local session-bound state are cleared at least as
    /// thoroughly as `signOut()` and `retireHost` clear them, since the household no longer
    /// exists on this host: the remote refresh registration (as `signOut()` disables it),
    /// the local session and private-node key material (as `retireHost` removes them via
    /// `removeRetiredLocalSession`), and the decrypted in-memory state (as both do, through
    /// the `session` `didSet`). A blocker that appeared since the last status check returns
    /// the flow to `.blocked` instead of failing outright.
    public func deleteAccount() async {
        guard session != nil, leavePhase == .ready else { return }
        await run {
            let started = generation
            leavePhase = .signing; leaveNotice = ""
            // No client-side refresh teardown: the server deletes the household's refresh
            // subscriptions with the account, and switching it off first left refresh off
            // whenever the deletion was cancelled or refused (refutation pass, 2026-09-22).
            do {
                let prepared = try await service.prepareLeave()
                try Task.checkCancellation()
                guard started == generation, session != nil else { return }
                let assertion = try await passkeys.authorise(prepared.ceremony, kind: .leave)
                try Task.checkCancellation()
                guard started == generation, session != nil else { return }
                let result = try await service.leave(prepared, assertion: assertion)
                guard started == generation else { return }
                generation &+= 1
                session = nil
                proposals.setSession(nil)
                // §14.3. The host deleted its side; this device's own journal of the
                // household's operations goes with it, and its key with the journal.
                try? operations?.removeAll(household: result.household)
                leavePhase = .done
                leaveResult = result
                leaveNotice = L("Your account and everything stored for it have been deleted. This device is signed out.")
            } catch {
                guard started == generation, session != nil else { return }
                if let leaveError = error as? MemberLeaveError, case .blocked(let blockers) = leaveError {
                    leaveBlockers = blockers; leavePhase = .blocked
                    leaveNotice = L("Something is still in progress, so your account was not deleted. Finish the items below, then try again.")
                    return
                }
                switch error {
                case is CancellationError, NativePasskeyFailure.cancelled:
                    leavePhase = .ready
                    leaveNotice = L("Passkey cancelled. Your account was not deleted.")
                default:
                    leavePhase = .failed
                    leaveNotice = L("We could not confirm the deletion. Do not repeat it. Refresh the account status first.")
                    notice = L("We could not confirm the deletion. Check your account status before trying again.")
                }
            }
        }
    }
    /// A member's full export, offered before deletion so leaving costs nothing they cannot
    /// keep. Read-only; never itself a step of deletion.
    public func requestExport() async {
        guard session != nil else { return }
        await run {
            let started = generation; leaveExportNotice = ""
            let value = try await service.exportAccount()
            guard started == generation, session != nil else { return }
            leaveExport = value; leaveExportNotice = L("Your copy is ready to save.")
        }
    }

    private func upsert(_ change: MemberMandateChange) {
        mandateChanges.removeAll { $0.id == change.id }
        mandateChanges.append(change)
        mandateChanges.sort { $0.createdAt > $1.createdAt }
    }
    private func dialsMessage(_ error: Error) -> String {
        switch error {
        case MemberFailure.http(409): return L("Your limits changed, or another change is waiting. Refresh before editing again.")
        case MemberFailure.http(422): return L("This change was refused. Check the amounts, the end date, the time to undo and who must agree.")
        case MemberFailure.http(401), MemberFailure.expired: return L("Your sign-in expired. Sign in again before changing your limits.")
        case is CancellationError, NativePasskeyFailure.cancelled: return L("Signing cancelled. Your limits are unchanged.")
        default: return L("Your limits could not be refreshed. Nothing was changed.")
        }
    }

}
