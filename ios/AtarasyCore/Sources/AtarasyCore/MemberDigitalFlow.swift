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
    @Published public private(set) var result: MemberActResult?
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
                handle.operationProfile == memberDecisionProfile && ReviewValidation.same(handle.environment, environment.name) && handle.origin == environment.origin &&
                ReviewValidation.same(handle.household, session.household) && session.presenters.contains(where: { ReviewValidation.same($0, handle.presenter) })
            }
        } catch { saved = []; notice = L("Your saved decisions could not be read. Do not send a decision again before checking its result.") }
    }
    public func prepare(detail: MemberOfferDetail, draft: MemberDigitalDraft) async {
        guard !busy, let session, session.expiresAt > now() else { return }
        busy = true; let current = generation; closeFields(); notice = ""; result = nil; defer { busy = false }
        do {
            let local = try PreparedMemberDecision(environment: environment, session: session, detail: detail, draft: draft, now: now())
            let (h, p) = try await service.prepareDecision(local, store: store)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            handle = h; refreshSaved()
            let frozen = try FrozenMemberDecision(p, local: local, now: now())
            guard h.operationProfile == memberDecisionProfile, !h.attempted else { throw MemberFailure.scopeMismatch }
            review = frozen; prepared = p; notice = ""
        } catch { if current == generation { review = nil; prepared = nil; notice = L("This decision could not be prepared. Refresh the proposal, check My records, then try again."); refreshSaved() } }
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
            if !dispatchStarted && (error as? NativePasskeyFailure == .cancelled || error is CancellationError) { notice = L("Signing cancelled. Nothing was sent.") }
            else { review = nil; self.prepared = nil; if dispatchStarted { result = .unknown }; notice = L("We could not confirm the result. It may have arrived. Check the result before doing anything else.") }
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
            closeFields(); notice = L("Review closed. No decision was sent.")
        } catch { if current == generation { review = nil; prepared = nil; notice = L("We could not confirm that the review was closed. Check the result.") } }
    }
    private func show(_ value: MemberDecisionOutcome) {
        switch value {
        case .recorded: result = .recorded(amount: nil); notice = L("Your decision was recorded. This is not a payment confirmation.")
        case .pending: result = .pending; notice = L("No recorded decision was found yet. Nothing was sent again.")
        case .unresolved: result = .unknown; notice = L("We could not read the result. Check again later, and do not send it again.")
        }
    }
}
