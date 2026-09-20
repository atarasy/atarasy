import SwiftUI
import AtarasyCore

struct MemberPermissionsView: View {
    @ObservedObject var model: MemberPermissions
    @State private var action: Task<Void, Never>?
    private func perform(_ work: @escaping @MainActor () async -> Void) { guard action == nil else { return }; action = Task { await work(); action = nil } }
    var body: some View {
        Form {
            Section {
                Text("Permissions are limited to the stated purpose, fields and expiry. New access is requested when you use an action.")
                Button("Refresh permissions") { perform { await model.refresh() } }.accessibilityIdentifier("refreshPermissions")
            }
            if model.loaded && model.rows.isEmpty { Text("No permissions recorded.") }
            if !model.loaded && !model.rows.isEmpty { Text("Refresh to confirm current access.") }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = Int64(context.date.timeIntervalSince1970 * 1000)
                ForEach(model.rows) { row in
                    Section(row.purpose) {
                        Text(row.kind == "computation" ? "Aggregate computation" : "Shared access")
                        Text(row.status(at: now)).accessibilityIdentifier("permissionStatus-" + row.id)
                        Text("Expires \(Date(timeIntervalSince1970: Double(row.expires_at) / 1000).formatted())")
                        DisclosureGroup("Permission details") {
                            Text("Recipient: \(row.grantee)").textSelection(.enabled)
                            Text("Fields: \(row.scope.joined(separator: ", "))").textSelection(.enabled)
                        }
                        if row.status(at: now) == "Active" { Button("Revoke this permission", role: .destructive) { model.select(row) }.disabled(!model.loaded).accessibilityIdentifier("revokePermission-" + row.id) }
                    }
                }
            }
            if model.busy { ProgressView("Checking permissions") }
            if !model.notice.isEmpty { Text(model.notice).accessibilityIdentifier("permissionNotice") }
        }
        .buttonStyle(.borderless)
        .navigationTitle("Permissions")
        .disabled(model.busy || action != nil)
        .alert("Revoke this permission?", isPresented: Binding(get: { model.selected != nil }, set: { if !$0 { model.cancel() } })) {
            Button("Revoke permission", role: .destructive) { if let selected = model.selected { perform { await model.revoke(selected) } } }
            Button("Cancel", role: .cancel) { model.cancel() }
        } message: { Text(model.selected?.purpose ?? "") }
        .task { await model.refresh() }
        .onDisappear { action?.cancel(); model.leave() }
    }
}
