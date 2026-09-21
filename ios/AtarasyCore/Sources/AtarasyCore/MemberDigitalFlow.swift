import Foundation
import Combine

public protocol MemberDecisionService: Sendable {
    func prepareDecision(_ local: PreparedMemberDecision, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedDecision)
    func decisionReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedDecision
    func submitDecision(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberDecisionOutcome
    func decisionOutcome(_ handle: MemberOperationHandle) async -> MemberDecisionOutcome
    func cancelOperation(_ handle: MemberOperationHandle) async throws
}
extension MemberClient: MemberDecisionService {}

@MainActor public final class MemberDigitalFlow: ObservableObject {
    @Published public private(set) var saved: [MemberOperationHandle] = []
    @Published public private(set) var handle: MemberOperationHandle?
    @Published public private(set) var review: FrozenMemberDecision?
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    public var canApprove: Bool { !busy && review != nil && handle?.attempted == false && (handle?.expiresAt ?? 0) > now() && (session?.expiresAt ?? 0) > now() }
    private let environment: MemberEnvironment
    private let service: any MemberDecisionService
    private let passkeys: any MemberPasskeyAuthorising
    private let store: any MemberOperationStore
    private let now: () -> Int64
    private var session: MemberSessionInfo?
    private var prepared: MemberPreparedDecision?
    private var generation: UInt64 = 0
    public init(environment: MemberEnvironment, service: any MemberDecisionService, passkeys: any MemberPasskeyAuthorising, store: any MemberOperationStore, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.environment = environment; self.service = service; self.passkeys = passkeys; self.store = store; self.now = now
    }
    public func setSession(_ session: MemberSessionInfo?) {
        generation &+= 1; self.session = session; handle = nil; review = nil; prepared = nil; notice = ""; refreshSaved()
    }
    public func closeReview() { generation &+= 1; handle = nil; review = nil; prepared = nil; notice = "" }
    public func checkExpiry() {
        if (session?.expiresAt ?? 0) <= now() { setSession(nil) }
        else if let handle, handle.expiresAt <= now(), review != nil { review = nil; prepared = nil; notice = "The approval window ended. You can still check the saved result." }
    }
    public func refreshSaved() {
        guard let session, session.expiresAt > now() else { saved = []; return }
        do {
            saved = try store.handles().filter { handle in
                handle.operationProfile == memberDecisionProfile && ReviewValidation.same(handle.environment, environment.name) && handle.origin == environment.origin &&
                ReviewValidation.same(handle.household, session.household) && session.presenters.contains(where: { ReviewValidation.same($0, handle.presenter) })
            }
        } catch { saved = []; notice = "Saved decisions could not be read. Do not repeat an earlier submission." }
    }
    public func prepare(detail: MemberOfferDetail, draft: MemberDigitalDraft) async {
        guard !busy, let session, session.expiresAt > now() else { return }
        busy = true; let current = generation; closeFields(); notice = ""; defer { busy = false }
        do {
            let local = try PreparedMemberDecision(environment: environment, session: session, detail: detail, draft: draft, now: now())
            let (h, p) = try await service.prepareDecision(local, store: store)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            handle = h; refreshSaved()
            let frozen = try FrozenMemberDecision(p, local: local, now: now())
            guard h.operationProfile == memberDecisionProfile, !h.attempted else { throw MemberFailure.scopeMismatch }
            review = frozen; prepared = p; notice = "Review the frozen choices, terms and mandate before signing."
        } catch { if current == generation { review = nil; prepared = nil; notice = "The decision could not be prepared. Refresh the proposal and check saved results before trying again."; refreshSaved() } }
    }
    private func closeFields() { handle = nil; review = nil; prepared = nil }
    public func approve() async {
        guard canApprove, let handle, let prepared, let session else { return }
        busy = true; let current = generation; notice = ""; defer { busy = false }
        var dispatchStarted = false
        do {
            let fresh = try await service.decisionReview(handle)
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), handle.expiresAt > now() else { return }
            guard fresh.operationState == "prepared", try digitalJSON(fresh.review) == digitalJSON(prepared.review),
                  fresh.profile == prepared.profile, fresh.operationID == prepared.operationID, fresh.expiresAt == prepared.expiresAt,
                  fresh.canonical == prepared.canonical, fresh.requestDigest == prepared.requestDigest, fresh.reviewedRevision == prepared.reviewedRevision,
                  fresh.publicKey == prepared.publicKey else { throw MemberFailure.scopeMismatch }
            let assertion = try await passkeys.authorise(.init(id: handle.id, expiresAt: handle.expiresAt, publicKey: fresh.publicKey), kind: .decision)
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), handle.expiresAt > now() else { return }
            dispatchStarted = true; review = nil; self.prepared = nil
            let value = try await service.submitDecision(handle, assertion: assertion, store: store)
            guard current == generation else { return }
            self.handle = try store.load(id: handle.id) ?? handle; show(value); refreshSaved()
        } catch {
            guard current == generation else { return }
            if !dispatchStarted && (error as? NativePasskeyFailure == .cancelled || error is CancellationError) { notice = "Approval cancelled. No assertion was submitted." }
            else { review = nil; self.prepared = nil; notice = "Approval could not be confirmed. Check the saved result before taking another action." }
            refreshSaved()
        }
    }
    public func check(_ selected: MemberOperationHandle) async {
        guard !busy, saved.contains(selected) else { return }
        busy = true; let current = generation; handle = selected; review = nil; prepared = nil; defer { busy = false }
        let value = await service.decisionOutcome(selected)
        guard current == generation, !Task.isCancelled else { return }; show(value)
    }
    public func cancelPrepared() async {
        guard !busy, let handle, !handle.attempted, saved.contains(handle) else { return }
        busy = true; let current = generation; defer { busy = false }
        do {
            try await service.cancelOperation(handle)
            guard current == generation else { return }
            closeFields(); notice = "Prepared decision cancelled. No decision was submitted by this action."
        } catch { if current == generation { review = nil; prepared = nil; notice = "Cancellation could not be confirmed. Check the saved result." } }
    }
    private func show(_ value: MemberDecisionOutcome) {
        switch value {
        case .recorded: notice = "Decision recorded for this saved operation. This is the original decision, not a payment confirmation or current order status."
        case .pending(let state): notice = "No committed decision is reported. State: \(state). Nothing was resubmitted."
        case .unresolved: notice = "The result could not be read. Check again later; do not repeat the submission."
        }
    }
}
