#if ATARASY_UI_TEST_FIXTURES
import SwiftUI
import AtarasyCore

// Compiled only by the dedicated UI-testing configuration, never Debug or Release.
private actor ProposalFixtureService: MemberProposalService {
    func offerDetail(id: String) async throws -> MemberOfferDetail { try MemberReviewFixtureData.detail(id: id) }
    func review(detail: MemberOfferDetail) async throws -> MemberReview { try MemberReviewFixtureData.review(detail: detail) }
    func offers(presenter: String) async throws -> [MemberOfferSummary] {
        if presenter == "Unavailable source" { throw MemberFailure.unavailable }
        if presenter == "Empty source" { return [] }
        let data = Data(#"[{"id":"fixture-member-offer","household":"test-household","presenter":"Available source","binding":"digital","state":"presented"},{"id":"fixture-member-physical","household":"test-household","presenter":"Available source","binding":"physical","state":"expired"}]"#.utf8)
        return try JSONDecoder().decode([MemberOfferSummary].self, from: data)
    }
}
struct MemberProposalFixtureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MemberProposals = {
        let model = MemberProposals(service: ProposalFixtureService(), now: { 1000 })
        let data = Data(#"{"id":"test-session","household":"test-household","presenters":["Available source","Unavailable source","Empty source"],"expiresAt":5000}"#.utf8)
        model.setSession(try! JSONDecoder().decode(MemberSessionInfo.self, from: data))
        return model
    }()
    var body: some View {
        Form {
            Section { Text("UI test fixture · no authentication or network").accessibilityIdentifier("memberListFixtureLabel") }
            MemberProposalSections(model: model)
        }
        .navigationTitle("Member proposal test")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
#endif
