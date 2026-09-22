import SwiftUI
import Combine
import AtarasyCore

struct MemberOfferDetailView: View {
    @ObservedObject var model: MemberProposals
    let selected: MemberOfferSummary
    var statements: MemberStatementFlow? = nil
    var decisions: MemberDigitalFlow? = nil
    @State private var digitalDraft: MemberDigitalDraft?
    @State private var draftNow = Date()
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
                        Button(detail.binding == "physical" ? (detail.state == "settled" ? "Load settlement" : "Load physical statement") : "Load approval information") { Task { await model.loadReview(selected) } }
                            .disabled(model.reviewLoading).accessibilityIdentifier("loadMemberReview")
                    }
                    if model.reviewLoading { ProgressView("Loading review information") }
                    else if let review = model.review {
                        MemberReviewSections(review: review, digitalDraft: $digitalDraft)
                        if let draft = digitalDraft, case .approval = review {
                            Section("Unsent choices") {
                                Text("Choices stay on this screen. Leaving or refreshing discards them. Nothing is signed, sent or ordered.").font(.footnote)
                                if let summary = try? draft.summary(now: Int64(draftNow.timeIntervalSince1970 * 1000)) {
                                    Text("Selected goods: \(summary.goods)")
                                    Text("Carriage: \(summary.carriage)")
                                    Text("Draft total: \(summary.total), in the merchant's supplied units")
                                        .accessibilityIdentifier("digitalDraftTotal")
                                } else {
                                    Text("A draft total requires a choice for every item, known carriage and unexpired terms.")
                                }
                                if let decisions {
                                    NavigationLink("Review digital decision") { MemberDigitalScreen(flow: decisions, detail: detail, draft: draft) }
                                        .disabled((try? draft.summary(now: Int64(draftNow.timeIntervalSince1970 * 1000))) == nil)
                                        .accessibilityIdentifier("openDigitalDecision")
                                } else { Text("Submitting a digital decision is not available in this view.").font(.footnote) }
                                Button("Discard choices") { digitalDraft?.discard() }
                            }
                        }
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
                            Text(detail.binding == "physical" && candidate.valence == "lost" ? MemberOfferDetail.lostOutcome(candidate.collectedAs, supplied: detail.collectedAsSupplied == true) : "\(detail.binding == "physical" ? "Reported outcome" : "Choice status"): \(candidate.valence)").accessibilityIdentifier("detailOutcome-" + candidate.id)
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
                            // Question 72. Rendered exactly as signed, beside this block's
                            // own terms. Tapping is the household's own act; nothing here
                            // sends anything or composes a message on its behalf.
                            if let contact = disclosure.contact {
                                if let url = contact.url { Link(contact.value, destination: url) } else { Text(verbatim: contact.value) }
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
        .onChange(of: model.review) { _, review in
            digitalDraft = nil
            if model.detail?.state == "presented", case .approval(let approval) = review {
                digitalDraft = MemberDigitalDraft(approval: approval)
            }
        }
        .onChange(of: model.sessionIdentity) { _, _ in digitalDraft = nil }
        .onReceive(clock) { date in draftNow = date; model.checkExpiry() }
        .onDisappear { digitalDraft = nil; model.clearDetail() }
    }
}
