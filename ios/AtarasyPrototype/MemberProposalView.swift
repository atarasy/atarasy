import SwiftUI
import AtarasyCore

struct MemberProposalSections: View {
    @ObservedObject var model: MemberProposals
    var statements: MemberStatementFlow? = nil
    var decisions: MemberDigitalFlow? = nil
    var body: some View {
        Group {
        Section("Member proposals") {
            Text("These summaries make no decision. Open a proposal to review the actions available for it.").font(.footnote)
            Button("Refresh proposals") { Task { await model.refresh() } }.disabled(model.loading).accessibilityIdentifier("refreshMemberProposals")
            if model.loading { ProgressView("Checking your sources").accessibilityIdentifier("memberSourcesLoading") }
            if model.stale { Text("These rows may be stale until every configured source is checked.").accessibilityIdentifier("memberSourcesStale") }
            if model.incomplete { Text("Some sources could not be checked. This list may be incomplete.").accessibilityIdentifier("memberSourcesIncomplete") }
            if model.sources.isEmpty && !model.loading { Text("No presenter sources in this session.").accessibilityIdentifier("memberNoSources") }
        }
        ForEach(model.sources) { source in
            Section {
                Text(source.presenter).font(.headline)
                if let verified = source.verifiedAt { Text("Last verified \(Date(timeIntervalSince1970: Double(verified) / 1000).formatted())").font(.caption).foregroundStyle(.secondary) }
                switch source.status {
                case .loading: Text("Checking this source")
                case .unavailable:
                    Text(source.offers.isEmpty ? "Source unavailable. Refresh to check again." : "Source unavailable. Showing rows from the last verified check.").accessibilityIdentifier("memberSourceUnavailable-" + source.presenter)
                    ForEach(Array(source.offers.enumerated()), id: \.offset) { _, offer in proposal(offer) }
                case .available:
                    if source.offers.isEmpty { Text("No proposals from this source.").accessibilityIdentifier("memberSourceEmpty-" + source.presenter) }
                    ForEach(Array(source.offers.enumerated()), id: \.offset) { _, offer in proposal(offer) }
                }
            }
        }
        }
        .task(id: model.sessionIdentity) { await model.refresh() }
    }
    private func proposal(_ offer: MemberOfferSummary) -> some View {
        NavigationLink { MemberOfferDetailView(model: model, selected: offer, statements: statements, decisions: decisions) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(offer.binding == "physical" ? "Physical proposal" : "Digital proposal").font(.headline)
                Text(offer.id).textSelection(.enabled)
                Text("Service state: \(offer.state)").font(.caption)
            }
        }.accessibilityIdentifier("memberProposal-" + offer.id)
    }
}
