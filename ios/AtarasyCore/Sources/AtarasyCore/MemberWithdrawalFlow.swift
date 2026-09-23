import Foundation
import Combine

public protocol MemberWithdrawalService: Sendable {
    func prepareWithdrawal(_ original: MemberOperationHandle, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedDecision, FrozenMemberWithdrawal)
    func withdrawalReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedDecision
    func submitWithdrawal(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberWithdrawalOutcome
    func withdrawalOutcome(_ handle: MemberOperationHandle) async -> MemberWithdrawalOutcome
    func cancelOperation(_ handle: MemberOperationHandle) async throws
}
extension MemberClient: MemberWithdrawalService {}

@MainActor public final class MemberWithdrawalFlow: ObservableObject {
    @Published public private(set) var saved: [MemberOperationHandle] = []
    @Published public private(set) var handle: MemberOperationHandle?
    @Published public private(set) var review: FrozenMemberWithdrawal?
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    @Published public private(set) var result: MemberActResult?
    public var canApprove: Bool { !busy && review != nil && handle?.attempted == false && (handle?.expiresAt ?? 0) > now() && (session?.expiresAt ?? 0) > now() }
    private let environment: MemberEnvironment
    private let service: any MemberWithdrawalService
    private let passkeys: any MemberPasskeyAuthorising
    private let store: any MemberOperationStore
    private let now: () -> Int64
    private var session: MemberSessionInfo?
    private var prepared: MemberPreparedDecision?
    private var generation: UInt64 = 0
    public init(environment: MemberEnvironment, service: any MemberWithdrawalService, passkeys: any MemberPasskeyAuthorising, store: any MemberOperationStore, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.environment = environment; self.service = service; self.passkeys = passkeys; self.store = store; self.now = now
    }
    public func setSession(_ session: MemberSessionInfo?) {
        generation &+= 1; self.session = session; handle = nil; review = nil; prepared = nil; notice = ""; result = nil; refreshSaved()
    }
    public func closeReview() { generation &+= 1; handle = nil; review = nil; prepared = nil; notice = ""; result = nil }
    public func checkExpiry() {
        if (session?.expiresAt ?? 0) <= now() { setSession(nil) }
        else if let handle, handle.expiresAt <= now(), review != nil { review = nil; prepared = nil; notice = L("This review has expired. You can still check the result of anything you sent.") }
    }
    public func refreshSaved() {
        guard let session, session.expiresAt > now() else { saved = []; return }
        do {
            saved = try store.handles().filter { handle in
                handle.operationProfile == memberWithdrawalProfile && ReviewValidation.same(handle.environment, environment.name) && handle.origin == environment.origin &&
                ReviewValidation.same(handle.household, session.household) && session.presenters.contains(where: { ReviewValidation.same($0, handle.presenter) })
            }
        } catch { saved = []; notice = L("Your saved cancellations could not be read. Do not send one again before checking its result.") }
    }
    public func prepare(original: MemberOperationHandle) async {
        guard !busy, let session, session.expiresAt > now() else { return }
        busy = true; let current = generation; closeFields(); notice = ""; result = nil; defer { busy = false }
        do {
            let (h, p, frozen) = try await service.prepareWithdrawal(original, store: store)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            handle = h; refreshSaved()
            guard h.operationProfile == memberWithdrawalProfile, !h.attempted else { throw MemberFailure.scopeMismatch }
            review = frozen; prepared = p; notice = ""
        } catch { if current == generation { review = nil; prepared = nil; notice = L("This cancellation could not be prepared. Check the decision and the proposal, then try again."); refreshSaved() } }
    }
    private func closeFields() { handle = nil; review = nil; prepared = nil }
    public func approve() async {
        guard canApprove, let handle, let prepared, let session else { return }
        busy = true; let current = generation; notice = ""; defer { busy = false }
        var dispatchStarted = false
        do {
            let fresh = try await service.withdrawalReview(handle)
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), handle.expiresAt > now() else { return }
            guard fresh.operationState == "prepared", try digitalJSON(fresh.review) == digitalJSON(prepared.review),
                  fresh.profile == prepared.profile, fresh.operationID == prepared.operationID, fresh.expiresAt == prepared.expiresAt,
                  fresh.canonical == prepared.canonical, fresh.requestDigest == prepared.requestDigest, fresh.reviewedRevision == prepared.reviewedRevision,
                  fresh.publicKey == prepared.publicKey else { throw MemberFailure.scopeMismatch }
            let assertion = try await passkeys.authorise(.init(id: handle.id, expiresAt: handle.expiresAt, publicKey: fresh.publicKey), kind: .withdrawal)
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), handle.expiresAt > now() else { return }
            dispatchStarted = true; review = nil; self.prepared = nil
            let value = try await service.submitWithdrawal(handle, assertion: assertion, store: store)
            guard current == generation else { return }
            self.handle = try store.load(id: handle.id) ?? handle; show(value); refreshSaved()
        } catch {
            guard current == generation else { return }
            if !dispatchStarted && (error as? NativePasskeyFailure == .cancelled || error is CancellationError) { notice = L("Signing cancelled. Nothing was sent.") }
            else { review = nil; self.prepared = nil; if dispatchStarted { result = .unknown }; notice = L("We could not confirm the result. It may have arrived. Check the result before doing anything else.") }
            refreshSaved()
        }
    }
    public func check(_ selected: MemberOperationHandle) async {
        guard !busy, saved.contains(selected) else { return }
        busy = true; let current = generation; handle = selected; review = nil; prepared = nil; defer { busy = false }
        let value = await service.withdrawalOutcome(selected)
        guard current == generation, !Task.isCancelled else { return }; show(value)
    }
    public func cancelPrepared() async {
        guard !busy, let handle, !handle.attempted, saved.contains(handle) else { return }
        busy = true; let current = generation; defer { busy = false }
        do {
            try await service.cancelOperation(handle)
            guard current == generation else { return }
            closeFields(); notice = L("Review closed. Your decision still stands.")
        } catch { if current == generation { review = nil; prepared = nil; notice = L("We could not confirm that the review was closed. Check the result.") } }
    }
    private func show(_ value: MemberWithdrawalOutcome) {
        switch value {
        case .recorded: result = .recorded(amount: nil); notice = L("Your decision was cancelled. Refresh the proposal before choosing again.")
        case .pending: result = .pending; notice = L("No recorded cancellation was found yet. Nothing was sent again.")
        case .unresolved: result = .unknown; notice = L("We could not read the result. Check again later, and do not send it again.")
        }
    }
}
