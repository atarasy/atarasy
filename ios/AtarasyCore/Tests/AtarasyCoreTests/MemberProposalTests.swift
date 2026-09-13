import XCTest
@testable import AtarasyCore

private actor ProposalService: MemberProposalService {
    var answers: [String: [MemberOfferSummary]] = [:]
    var failures: [String: MemberFailure] = [:]
    var held = false
    var calls: [String] = []
    var pending: [(String, CheckedContinuation<[MemberOfferSummary], Error>)] = []
    var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var peak = 0
    func configure(answers: [String: [MemberOfferSummary]] = [:], failures: [String: MemberFailure] = [:], held: Bool = false) { self.answers = answers; self.failures = failures; self.held = held }
    func offers(presenter: String) async throws -> [MemberOfferSummary] {
        calls.append(presenter)
        if held {
            return try await withCheckedThrowingContinuation { continuation in
                pending.append((presenter, continuation)); peak = max(peak, pending.count)
                notify()
            }
        }
        notify()
        if let failure = failures[presenter] { throw failure }; return answers[presenter] ?? []
    }
    private func notify() {
        let ready = observers.filter { calls.count >= $0.0 }; observers.removeAll { calls.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func releaseFirst(_ result: Result<[MemberOfferSummary], MemberFailure>) {
        let (_, continuation) = pending.removeFirst()
        continuation.resume(with: result.mapError { $0 as Error })
    }
    func releaseAll() { let old = pending; pending = []; for (_, continuation) in old { continuation.resume(returning: []) } }
}
@MainActor final class MemberProposalTests: XCTestCase {
    func info(_ presenters: [String], household: String = "home", expiry: Int64 = 5000) -> MemberSessionInfo {
        MemberSessionInfo(id: household, household: household, presenters: presenters, expiresAt: expiry)
    }
    func row(_ presenter: String, id: String = "offer", household: String = "home", binding: String = "digital") -> MemberOfferSummary {
        MemberOfferSummary(id: id, household: household, presenter: presenter, binding: binding, state: "presented")
    }
    func testPartialFailureAndCheckedEmptyKeepSourceOrder() async {
        let service = ProposalService(); await service.configure(answers: ["a": [row("a")]], failures: ["b": .unavailable])
        let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["a", "b", "c"]))
        await model.refresh()
        XCTAssertEqual(model.sources.map(\.presenter), ["a", "b", "c"])
        XCTAssertEqual(model.sources[0].offers.count, 1); XCTAssertEqual(model.sources[1].status, .unavailable)
        XCTAssertEqual(model.sources[2].status, .available); XCTAssertTrue(model.sources[2].offers.isEmpty)
        XCTAssertTrue(model.incomplete); XCTAssertFalse(model.loading)
    }
    func testRefreshDropsOldRowsAndBoundsConcurrencyAtFour() async {
        let service = ProposalService(); await service.configure(answers: ["a": [row("a")]])
        let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["a", "b", "c", "d", "e"]))
        await model.refresh(); XCTAssertFalse(model.sources[0].offers.isEmpty)
        await service.configure(held: true)
        let refresh = Task { await model.refresh() }; await service.waitForCalls(9)
        XCTAssertTrue(model.loading); XCTAssertTrue(model.sources.allSatisfy { $0.offers.isEmpty })
        let calls = await service.calls; XCTAssertEqual(calls.count, 9)
        await model.refresh(); let unchanged = await service.calls.count; XCTAssertEqual(unchanged, 9)
        await service.releaseFirst(.success([])); await service.waitForCalls(10)
        await service.releaseAll(); await refresh.value
        let peak = await service.peak; XCTAssertEqual(peak, 4); XCTAssertFalse(model.loading)
    }
    func testStaleSuccessAnd401CannotChangeNewSession() async {
        for reply in [Result<[MemberOfferSummary], MemberFailure>.success([row("old")]), .failure(.http(401))] {
            let service = ProposalService(); await service.configure(held: true)
            let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["old"]))
            let old = Task { await model.refresh() }; await service.waitForCalls(1)
            model.setSession(info(["new"], household: "other"))
            await service.configure(answers: ["new": [row("new", household: "other")]])
            await model.refresh(); await service.releaseFirst(reply); await old.value
            XCTAssertEqual(model.sources.map(\.presenter), ["new"]); XCTAssertEqual(model.sources[0].offers[0].household, "other")
            XCTAssertNotNil(model.sessionIdentity)
        }
    }
    func testLogoutAndExpiryDiscardHeldReads() async {
        let service = ProposalService(); await service.configure(held: true)
        let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["a"]))
        let reading = Task { await model.refresh() }; await service.waitForCalls(1)
        model.setSession(nil); await service.releaseFirst(.success([row("a")]))
        await reading.value; XCTAssertTrue(model.sources.isEmpty); XCTAssertNil(model.sessionIdentity)
        var clock: Int64 = 1000
        let expiring = MemberProposals(service: service, now: { clock }); expiring.setSession(info(["a"], expiry: 2000))
        var invalidated = false; expiring.onSessionUnavailable = { invalidated = true }
        let late = Task { await expiring.refresh() }; await service.waitForCalls(2)
        clock = 2000; await service.releaseFirst(.success([row("a")]))
        await late.value; XCTAssertTrue(invalidated); XCTAssertTrue(expiring.sources.isEmpty)
    }
    func testCurrent401ClearsAllRowsAndExpiredSessionDoesNotDispatch() async {
        let service = ProposalService(); await service.configure(answers: ["a": [row("a")]], failures: ["b": .http(401)])
        let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["a", "b"]))
        var invalidated = false; model.onSessionUnavailable = { invalidated = true }
        await model.refresh(); XCTAssertTrue(invalidated); XCTAssertTrue(model.sources.isEmpty); XCTAssertNil(model.sessionIdentity)
        let previous = await service.calls.count
        model.setSession(info(["a"], expiry: 1000)); await model.refresh()
        let after = await service.calls.count; XCTAssertEqual(after, previous)
    }
    func testForeignDuplicateAndUnknownBindingAreUnavailable() async {
        let service = ProposalService()
        await service.configure(answers: ["a": [row("a", household: "foreign")], "b": [row("b"), row("b")], "c": [row("c", binding: "unknown")]])
        let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["a", "b", "c"]))
        await model.refresh(); XCTAssertTrue(model.sources.allSatisfy { $0.status == .unavailable && $0.offers.isEmpty })
    }
    func testExactBytePresenterIdentityAndEmptyGrants() async {
        let service = ProposalService(), model = MemberProposals(service: ProposalService(), now: { 1000 })
        model.setSession(info([])); await model.refresh(); XCTAssertTrue(model.sources.isEmpty); XCTAssertFalse(model.incomplete)
        let exact = MemberProposals(service: service, now: { 1000 }); exact.setSession(info(["é", "e\u{301}", "é"]))
        await exact.refresh(); XCTAssertEqual(exact.sources.count, 2); XCTAssertNotEqual(exact.sources[0].id, exact.sources[1].id)
    }
    func testCancelledRefreshIsUnavailableNotEmptySuccess() async {
        let service = ProposalService(); await service.configure(held: true)
        let model = MemberProposals(service: service, now: { 1000 }); model.setSession(info(["a"]))
        let reading = Task { await model.refresh() }; await service.waitForCalls(1); reading.cancel()
        await service.releaseFirst(.success([])); await reading.value
        XCTAssertTrue(model.incomplete); XCTAssertEqual(model.sources[0].status, .unavailable)
    }
}
