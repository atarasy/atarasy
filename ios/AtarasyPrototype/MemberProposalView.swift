import SwiftUI
import AtarasyCore

struct MemberProposalSections: View {
    @ObservedObject var model: MemberProposals
    var body: some View {
        Group {
        Section("Member proposals") {
            Text("Read-only summaries. Open decisions and payment actions are not available here yet.").font(.footnote)
            Button("Refresh proposals") { Task { await model.refresh() } }.disabled(model.loading).accessibilityIdentifier("refreshMemberProposals")
            if model.loading { ProgressView("Checking your sources").accessibilityIdentifier("memberSourcesLoading") }
            if model.incomplete { Text("Some sources could not be checked. This list may be incomplete.").accessibilityIdentifier("memberSourcesIncomplete") }
            if model.sources.isEmpty && !model.loading { Text("No presenter sources in this session.").accessibilityIdentifier("memberNoSources") }
        }
        ForEach(model.sources) { source in
            Section {
                Text(source.presenter).font(.headline)
                switch source.status {
                case .loading: Text("Checking this source")
                case .unavailable: Text("Source unavailable. Refresh to check again.").accessibilityIdentifier("memberSourceUnavailable-" + source.presenter)
                case .available:
                    if source.offers.isEmpty { Text("No proposals from this source.").accessibilityIdentifier("memberSourceEmpty-" + source.presenter) }
                    ForEach(Array(source.offers.enumerated()), id: \.offset) { _, offer in
                        NavigationLink { MemberOfferDetailView(model: model, selected: offer) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(offer.binding == "physical" ? "Physical proposal" : "Digital proposal").font(.headline)
                            Text(offer.id).textSelection(.enabled)
                            Text("Service state: \(offer.state)").font(.caption)
                        }
                        }.accessibilityIdentifier("memberProposal-" + offer.id)
                    }
                }
            }
        }
        }
        .task(id: model.sessionIdentity) { await model.refresh() }
    }
}
