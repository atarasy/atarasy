import SwiftUI
import Combine
import AtarasyCore

struct MemberOfferDetailView: View {
    @ObservedObject var model: MemberProposals
    let selected: MemberOfferSummary
    var statements: MemberStatementFlow? = nil
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Form {
            if model.sessionIdentity == nil {
                Text("Your session ended. Return to Member account to sign in.").accessibilityIdentifier("detailSessionEnded")
            } else {
                Section {
                    Text("Viewing this proposal does not make a decision or payment.").font(.footnote)
                }
                if model.detailLoading { ProgressView("Loading proposal") }
                else if let detail = model.detail {
                    Section {
                        Button(detail.binding == "physical" ? "Load physical statement" : "Load approval information") { Task { await model.loadReview(selected) } }
                            .disabled(model.reviewLoading).accessibilityIdentifier("loadMemberReview")
                    }
                    if model.reviewLoading { ProgressView("Loading review information") }
                    else if let review = model.review {
                        MemberReviewSections(review: review)
                        if case .statement(let statement) = review, let statements {
                            Section {
                                NavigationLink("Review and approve statement") { MemberStatementScreen(flow: statements, detail: detail, statement: statement) }
                                    .accessibilityIdentifier("openStatementApproval")
                            }
                        }
                    }
                    else if model.reviewUnavailable { Section { Text("Review information is unavailable or changed. Refresh to try again; no decision has been made.").accessibilityIdentifier("memberReviewUnavailable") } }
                    Section(detail.binding == "physical" ? "Collection proposal" : "Digital proposal") {
                        Text("Proposal: \(detail.id)")
                        Text("Presenter: \(detail.presenter)")
                        Text("Status: \(detail.state)")
                        Text("\(detail.binding == "physical" ? "Collection due" : "Proposal expiry"): \(Date(timeIntervalSince1970: Double(detail.expiresAt) / 1000).formatted())")
                        if detail.binding == "physical" { Text("The actual collection time, grace period and carriage charge are not included in this response.").font(.footnote) }
                        if let giver = detail.giver { Text("Giver: \(giver)") }
                        if let band = detail.priceBand { Text("Gift price band: \(band.min)–\(band.max), in the merchant's units") }
                        Text("Prices use the merchant's supplied units. Currency was not included.").font(.footnote)
                    }
                    ForEach(Array(detail.candidates.enumerated()), id: \.offset) { _, candidate in
                        Section("Product reference: \(candidate.product)") {
                            Text("Quantity: \(candidate.quantity)")
                            Text("Merchant: \(candidate.merchant)")
                            Text("Maker: \(candidate.maker)").accessibilityIdentifier("detailMaker-" + candidate.id)
                            Text("Carrier: \(candidate.ships)")
                            Text("Catalogue unit price: \(candidate.unitPrice)")
                            if let giver = candidate.givenBy { Text("Gift from \(giver). No goods charge to the recipient.").accessibilityIdentifier("detailGift") }
                            Text("\(detail.binding == "physical" ? "Reported outcome" : "Choice status"): \(candidate.valence)").accessibilityIdentifier("detailOutcome-" + candidate.id)
                        }
                    }
                    Section("Merchant disclosures") {
                        Text("The following text was supplied with the proposal. This device has not independently verified the disclosure signatures.").font(.footnote)
                        if detail.disclosures.isEmpty { Text("No disclosure blocks were supplied.") }
                    }
                    ForEach(Array(detail.disclosures.enumerated()), id: \.offset) { _, disclosure in
                        Section(disclosure.product.map { "Product disclosure: " + $0 } ?? "Standing disclosure") {
                            Text(disclosure.merchant)
                            Text("Version: \(disclosure.version)").font(.caption)
                            ForEach(Array(disclosure.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading) { Text(item.label).font(.headline); Text(item.value) }
                            }
                        }
                    }
                } else { Text("This proposal could not be loaded. Refresh to check again.").accessibilityIdentifier("detailUnavailable") }
            }
        }
        .navigationTitle(selected.binding == "physical" ? "Physical proposal" : "Digital proposal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { Task { await model.loadDetail(selected) } }
                    .disabled(model.sessionIdentity == nil || model.detailLoading)
                    .accessibilityIdentifier("refreshMemberDetail")
            }
        }
        .task(id: model.sessionIdentity) { await model.loadDetail(selected) }
        .onReceive(clock) { _ in model.checkExpiry() }
        .onDisappear { model.clearDetail() }
    }
}
