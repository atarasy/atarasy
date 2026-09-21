import SwiftUI
import AtarasyCore

struct MemberPermissionRequestsView: View {
    var currentTime: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    @ObservedObject var model: MemberPermissionRequests
    @State private var action: Task<Void, Never>?
    private func perform(_ work: @escaping @MainActor () async -> Void) { guard action == nil else { return }; action = Task { await work(); action = nil } }
    var body: some View {
        Form {
            Section {
                Text("Each request belongs to a specific action. Review who is asking, why, what they may read and when access ends.")
                Button("Refresh requests") { perform { await model.refresh() } }
            }
            if let row = model.review {
                Section(row.terms.action) {
                    Text("Requested by: \(row.terms.requester.name)")
                    Text(row.terms.purpose)
                    ForEach(row.terms.fields, id: \.id) { Text("Access: \($0.label)") }
                    Text("Access ends \(Date(timeIntervalSince1970: Double(row.terms.accessExpiresAt) / 1000).formatted())")
                    Text("Review by \(Date(timeIntervalSince1970: Double(row.terms.reviewExpiresAt) / 1000).formatted())")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let now = currentTime()
                        if row.state == "pending" {
                            Button("Allow this access") { perform { await model.decide(grant: true) } }.disabled(!model.ready || !row.canDecide(at: now))
                            Button("Cancel request", role: .cancel) { perform { await model.decide(grant: false) } }.disabled(!model.ready || !row.canDecide(at: now))
                            if !row.canDecide(at: now) { Text("This request has expired.") }
                        } else { Text(row.state.capitalized) }
                        if let permission = row.permission { Text("Access: \(permission.status(at: now))") }
                    }
                    Button("Check this request again") { perform { await model.open(row.id) } }
                }
            } else {
                ForEach(model.rows) { row in
                    Button { perform { await model.open(row.id) } } label: {
                        VStack(alignment: .leading) { Text(row.terms.action); Text(row.terms.requester.name).font(.subheadline); Text(row.state.capitalized).font(.caption) }
                    }
                }
            }
            if model.busy { ProgressView("Checking request") }
            if !model.notice.isEmpty { Text(model.notice).accessibilityIdentifier("requestNotice") }
        }
        .buttonStyle(.borderless)
        .navigationTitle("Access requests")
        .disabled(model.busy || action != nil)
        .task { await model.refresh() }
        .onDisappear { action?.cancel(); model.leave() }
    }
}
