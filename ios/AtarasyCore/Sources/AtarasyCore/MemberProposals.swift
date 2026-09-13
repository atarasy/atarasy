import Foundation
import Combine

public protocol MemberProposalService: Sendable {
    func offers(presenter: String) async throws -> [MemberOfferSummary]
}
public struct MemberProposalSource: Identifiable, Sendable {
    public enum Status: Sendable { case loading, available, unavailable }
    public var id: String { Data(presenter.utf8).base64EncodedString() }
    public let presenter: String
    public internal(set) var status: Status
    public internal(set) var offers: [MemberOfferSummary]
}
private enum ProposalRead: Sendable {
    case success(Int, [MemberOfferSummary]), failed(Int), invalidSession
}
@MainActor public final class MemberProposals: ObservableObject {
    @Published public private(set) var sources: [MemberProposalSource] = []
    @Published public private(set) var loading = false
    @Published public private(set) var sessionIdentity: UUID?
    public var incomplete: Bool { sources.contains { $0.status == .unavailable } }
    var onSessionUnavailable: (() -> Void)?
    private let service: any MemberProposalService
    private let now: () -> Int64
    private var session: MemberSessionInfo?
    private var generation: UInt64 = 0
    public init(service: any MemberProposalService, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.service = service; self.now = now
    }
    public func setSession(_ session: MemberSessionInfo?) {
        generation &+= 1; self.session = session; sources = []; loading = false
        sessionIdentity = session == nil ? nil : UUID()
    }
    private func invalidate() { setSession(nil); onSessionUnavailable?() }
    public func refresh() async {
        guard !loading, let session else { return }
        guard session.expiresAt > now() else { invalidate(); return }
        generation &+= 1; let started = generation
        var seen = Set<Data>()
        let presenters = session.presenters.filter { seen.insert(Data($0.utf8)).inserted }
        sources = presenters.map { MemberProposalSource(presenter: $0, status: .loading, offers: []) }
        loading = true
        defer { if generation == started { loading = false } }
        let service = self.service
        await withTaskGroup(of: ProposalRead.self) { group in
            func enqueue(_ index: Int) {
                let presenter = presenters[index]
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let rows = try await service.offers(presenter: presenter)
                        var ids = Set<Data>()
                        guard rows.allSatisfy({ Data($0.household.utf8) == Data(session.household.utf8) && Data($0.presenter.utf8) == Data(presenter.utf8) && !$0.id.isEmpty && ids.insert(Data($0.id.utf8)).inserted && ["digital", "physical"].contains($0.binding) && !$0.state.isEmpty }) else { return .failed(index) }
                        return .success(index, rows)
                    } catch MemberFailure.expired { return .invalidSession }
                    catch MemberFailure.http(401) { return .invalidSession }
                    catch { return .failed(index) }
                }
            }
            var next = min(4, presenters.count)
            for index in 0..<next { enqueue(index) }
            for await result in group {
                guard generation == started else { group.cancelAll(); continue }
                guard session.expiresAt > now() else { invalidate(); group.cancelAll(); continue }
                if Task.isCancelled {
                    // A cancelled refresh is incomplete, never a checked empty list.
                    for index in sources.indices where sources[index].status == .loading { sources[index].status = .unavailable }
                    group.cancelAll(); continue
                }
                switch result {
                case .success(let index, let rows): sources[index].offers = rows; sources[index].status = .available
                case .failed(let index): sources[index].status = .unavailable
                case .invalidSession: invalidate(); group.cancelAll(); continue
                }
                if next < presenters.count { enqueue(next); next += 1 }
            }
        }
    }
}
