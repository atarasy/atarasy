import Foundation
import Combine

public protocol MemberStatementService: Sendable {
    func prepareStatement(_ local: PreparedMemberStatement, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedOperation)
    func operationReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedOperation
    func submitStatement(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberOperationOutcome
    func operationOutcome(_ handle: MemberOperationHandle) async -> MemberOperationOutcome
    func cancelOperation(_ handle: MemberOperationHandle) async throws
    func settlement(offerID: String) async throws -> ProtocolSettlement
}
extension MemberClient: MemberStatementService {}

public struct FrozenMemberStatement: Sendable {
    public let statement: MemberStatement
    public let mandate: Mandate
    public let disputed: [String]
    public let goodsCharged: Int64
    public let disputedAmount: Int64
    init(_ prepared: MemberPreparedOperation, detail: MemberOfferDetail) throws {
        guard case .object(let view) = prepared.review, Set(view.keys) == ["statement", "mandate", "disputed"],
              case .object(var statement) = view["statement"], let mandate = view["mandate"],
              case .array(let disputed) = view["disputed"] else { throw MemberFailure.malformed }
        self.disputed = try disputed.map { guard case .string(let id) = $0 else { throw MemberFailure.malformed }; return id }
        guard Set(self.disputed.map { Data($0.utf8) }).count == self.disputed.count,
              case .integer(let carriage) = statement["carriage"], case .array(let rows) = statement["lines"] else { throw MemberFailure.malformed }
        let lines = try rows.map { row -> StatementLine in
            guard case .object(let line) = row, case .string(let id) = line["candidate"], case .string(let valence) = line["valence"], case .integer(let amount) = line["amount"] else { throw MemberFailure.malformed }
            return .init(candidate: id, valence: valence, amount: amount, disputed: false)
        }
        statement["challenge"] = .string(Canonical.challenge(try Canonical.statement(offer: detail.id, carriage: carriage, lines: lines)))
        let disputedIDs = self.disputed
        let charged = lines.filter { !disputedIDs.contains($0.candidate) }.map(\.amount)
        let contested = lines.filter { disputedIDs.contains($0.candidate) }.map(\.amount)
        func sum(_ amounts: [Int64]) throws -> Int64 {
            try amounts.reduce(0) { total, amount in guard amount >= 0, total <= Canonical.maximumInteger - amount else { throw MemberFailure.malformed }; return total + amount }
        }
        goodsCharged = try sum(charged); disputedAmount = try sum(contested)
        self.statement = try MemberStatement.decode(JSONEncoder().encode(MemberJSON.object(statement)), detail: detail)
        self.mandate = try ReferenceResponseReader.mandate(status: 200, contentType: "application/json", data: JSONEncoder().encode(mandate), expectedID: detail.mandate, expectedHousehold: detail.household)
    }
}

@MainActor public final class MemberStatementFlow: ObservableObject {
    @Published public private(set) var saved: [MemberOperationHandle] = []
    @Published public private(set) var handle: MemberOperationHandle?
    @Published public private(set) var review: FrozenMemberStatement?
    @Published public private(set) var busy = false
    @Published public private(set) var notice = ""
    /// Offers this flow has seen settle. A statement review loaded before settling is still on the
    /// screen that opened this flow, so the screen asks here rather than offering preparation again.
    @Published public private(set) var settledOffers: Set<String> = []
    public var canApprove: Bool { !busy && review != nil && handle?.attempted == false && (handle?.expiresAt ?? 0) > now() && (session?.expiresAt ?? 0) > now() }
    private let environment: MemberEnvironment
    private let service: any MemberStatementService
    private let passkeys: any MemberPasskeyAuthorising
    private let store: any MemberOperationStore
    private let diagnostic: (String) -> Void
    private let now: () -> Int64
    private var session: MemberSessionInfo?
    private var prepared: MemberPreparedOperation?
    private var generation: UInt64 = 0
    public init(environment: MemberEnvironment, service: any MemberStatementService, passkeys: any MemberPasskeyAuthorising, store: any MemberOperationStore, diagnostic: @escaping (String) -> Void = { _ in }, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.environment = environment; self.service = service; self.passkeys = passkeys; self.store = store; self.diagnostic = diagnostic; self.now = now
    }
    public func setSession(_ session: MemberSessionInfo?) {
        generation &+= 1; self.session = session; handle = nil; prepared = nil; review = nil; saved = []; notice = ""; settledOffers = []
        refreshSaved()
    }
    /// A box can settle by another route while its statement review is open: the web hub, another device,
    /// or a race. Reading the settlement when the statement screen opens keeps it from offering preparation
    /// for a box that has settled. No settlement, or a failed read, leaves the screen as it was.
    public func checkSettled(offerID: String) async {
        guard let session, session.expiresAt > now() else { return }
        let current = generation
        guard let receipt = try? await service.settlement(offerID: offerID), current == generation,
              Data(receipt.offer.utf8) == Data(offerID.utf8), Data(receipt.payer.utf8) == Data(session.household.utf8),
              session.presenters.contains(where: { Data($0.utf8) == Data(receipt.signedBy.utf8) }) else { return }
        settledOffers.insert(offerID)
    }
    public func closeReview() { generation &+= 1; handle = nil; prepared = nil; review = nil; notice = "" }
    public func checkExpiry() {
        if (session?.expiresAt ?? 0) <= now() { setSession(nil) }
        else if let handle, handle.expiresAt <= now(), review != nil { review = nil; prepared = nil; notice = "This approval window ended. You can still check the recorded result." }
    }
    public func refreshSaved() {
        guard let session, session.expiresAt > now() else { saved = []; return }
        do {
            saved = try store.handles().filter {
                $0.operationProfile == "atarasy.member-statement-authorisation.1" && Data($0.environment.utf8) == Data(environment.name.utf8) && $0.origin == environment.origin &&
                Data($0.household.utf8) == Data(session.household.utf8) &&
                session.presenters.contains($0.presenter)
            }
        } catch { saved = []; notice = "Saved operations could not be read. Do not repeat an earlier submission." }
    }
    public func prepare(detail: MemberOfferDetail, statement: MemberStatement, disputed: [String]) async {
        guard !busy, let session, session.expiresAt > now() else { return }
        busy = true; let current = generation; notice = ""; handle = nil; review = nil; prepared = nil
        defer { busy = false }
        do {
            let local = try PreparedMemberStatement(environment: environment, session: session, detail: detail, statement: statement, disputed: disputed, now: now())
            let (handle, prepared) = try await service.prepareStatement(local, store: store)
            guard current == generation, !Task.isCancelled, session.expiresAt > now() else { return }
            self.handle = handle; refreshSaved()
            let frozen = try FrozenMemberStatement(prepared, detail: detail)
            guard Data(local.canonical.utf8) == Data(prepared.canonical.utf8), frozen.disputed.map({ Data($0.utf8) }).sorted(by: { $0.lexicographicallyPrecedes($1) }) == disputed.map({ Data($0.utf8) }).sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw MemberFailure.scopeMismatch }
            self.prepared = prepared; review = frozen
            notice = "Read the frozen statement and mandate before approving."
        } catch { if current == generation { notice = "The statement could not be prepared. The box may already have settled; go back and load it again, and check saved operations before trying again."; refreshSaved() } }
    }
    public func approve() async {
        guard canApprove, let handle, let prepared, let session else { return }
        busy = true; let current = generation; notice = ""; defer { busy = false }
        var dispatchStarted = false
        var stage = "review-read"
        do {
            let fresh = try await service.operationReview(handle)
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), handle.expiresAt > now() else { return }
            stage = "review-comparison"
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard fresh.operationState == "prepared", fresh.operationID == prepared.operationID,
                  fresh.reviewedRevision == prepared.reviewedRevision, fresh.publicKey == prepared.publicKey,
                  try encoder.encode(fresh.review) == encoder.encode(prepared.review) else { throw MemberFailure.scopeMismatch }
            let ceremony = MemberCeremony(id: handle.id, expiresAt: handle.expiresAt, publicKey: fresh.publicKey)
            stage = "passkey-presentation"
            let assertion = try await passkeys.authorise(ceremony, kind: .statement)
            guard current == generation, !Task.isCancelled, session.expiresAt > now(), handle.expiresAt > now() else { return }
            stage = "submission"
            dispatchStarted = true; review = nil; self.prepared = nil
            let outcome = try await service.submitStatement(handle, assertion: assertion, store: store)
            guard current == generation else { return }
            self.handle = try store.load(id: handle.id) ?? handle; show(outcome); refreshSaved()
        } catch {
            guard current == generation else { return }
            // Fixed labels only: never pass credentials, payloads, or arbitrary error descriptions.
            let reason: String
            switch error {
            case NativePasskeyFailure.unavailable: reason = "passkey-unavailable"
            case NativePasskeyFailure.invalidOptions: reason = "invalid-options"
            case NativePasskeyFailure.cancelled: reason = "cancelled"
            case MemberFailure.scopeMismatch: reason = "scope-mismatch"
            case MemberFailure.malformed: reason = "malformed"
            case MemberFailure.expired: reason = "expired"
            default: reason = "other"
            }
            diagnostic(stage + ":" + reason)
            if !dispatchStarted && (error as? NativePasskeyFailure == .cancelled || error is CancellationError) { notice = "Approval cancelled. No assertion was submitted." }
            else { review = nil; self.prepared = nil; notice = "Approval could not be confirmed. Check the saved result before taking another action." }
            refreshSaved()
        }
    }
    public func check(_ selected: MemberOperationHandle) async {
        guard !busy, saved.contains(selected) else { return }
        busy = true; let current = generation; handle = selected; review = nil; prepared = nil
        defer { busy = false }
        let outcome = await service.operationOutcome(selected)
        guard current == generation, !Task.isCancelled else { return }
        show(outcome)
    }
    public func cancelPrepared() async {
        guard !busy, let handle, !handle.attempted, saved.contains(handle) else { return }
        busy = true; let current = generation; defer { busy = false }
        do {
            try await service.cancelOperation(handle)
            guard current == generation else { return }
            self.handle = nil; review = nil; prepared = nil; notice = "Prepared statement cancelled. No approval was submitted by this action."
        } catch { if current == generation { review = nil; prepared = nil; notice = "Cancellation could not be confirmed. Check the saved result." } }
    }
    private func show(_ outcome: MemberOperationOutcome) {
        switch outcome {
        case .committed(let receipt): settledOffers.insert(receipt.offer); notice = "Statement recorded. Goods amount: \(receipt.charged). This record does not confirm provider payment."
        case .settledElsewhere(let receipt): settledOffers.insert(receipt.offer); notice = "This box has settled, but not by an approval this device sent. Goods amount of the settlement that stands: \(receipt.charged). Nothing was resubmitted."
        case .settledUnverified(let receipt): settledOffers.insert(receipt.offer); notice = "This box has settled. This approval was saved before this device recorded what it signed, so it cannot say the settlement is this approval. Goods amount of the settlement that stands: \(receipt.charged). Nothing was resubmitted."
        case .pending(let state): notice = "No committed result is reported. Current state: \(state). Nothing was resubmitted."
        case .unresolved: notice = "The result could not be read. Check again later. An approval made with another passkey cannot be read on this one; do not repeat a submission this passkey made."
        }
    }
}
