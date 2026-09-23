import SwiftUI
import AtarasyCore

private actor DialsFixtureService: MemberAccountService {
    let household = "key:member-fixture"
    let session = MemberSessionInfo(id: "dials-session", household: "key:member-fixture", presenters: [], expiresAt: 2_000_000_000_000)
    var effective: [MemberMandate]
    var changes: [MemberMandateChange]
    init() {
        let first = MemberMandate(id: "key:member-fixture.zero", household: "key:member-fixture", ceilingOutOfNetwork: 0, ceilingDaily: 0, coolingSeconds: 86_400, coSigners: [], lapsesAt: 1_900_000_000_000, version: 1)
        let protected = MemberMandate(id: "key:member-fixture.family", household: "key:member-fixture", ceilingOutOfNetwork: 5_000, ceilingDaily: 10_000, coolingSeconds: 3_600, coSigners: ["key:family-fixture"], lapsesAt: 1_900_000_000_000, version: 3)
        let proposed = MemberMandate(id: protected.id, household: protected.household, ceilingOutOfNetwork: 7_500, ceilingDaily: nil, coolingSeconds: 600, coSigners: protected.coSigners, lapsesAt: protected.lapsesAt, version: 4)
        effective = [first, protected]
        changes = [.init(id: "11111111-1111-4111-8111-111111111111", before: protected, mandate: proposed, requiredSigners: ["key:member-fixture", "key:family-fixture"], signedBy: ["key:member-fixture"], state: "pending", createdAt: 1_800_000_000_000, updatedAt: 1_800_000_000_001)]
    }
    func registrationOptions(invitation: String) async throws -> MemberCeremony { throw MemberFailure.unavailable }
    func loginOptions() async throws -> MemberCeremony { throw MemberFailure.unavailable }
    func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws { throw MemberFailure.unavailable }
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo { session }
    func restore(household: String) async throws -> MemberSessionInfo? { session }
    func logout() async throws -> MemberLogoutOutcome { .revoked }
    func offers(presenter: String) async throws -> [MemberOfferSummary] { [] }
    func effectiveMandates() async throws -> [MemberMandate] { effective }
    func mandateChanges() async throws -> [MemberMandateChange] { changes }
    private func prepared(_ change: MemberMandateChange) -> PreparedMemberMandateChange {
        .init(change: change, ceremony: .init(id: change.id, expiresAt: 2_000_000_000_000, publicKey: [:]), sessionID: session.id, credentialID: "fixture")
    }
    func prepareMandateChange(_ mandate: MemberMandate) async throws -> PreparedMemberMandateChange {
        guard let before = effective.first(where: { $0.id == mandate.id }) else { throw MemberFailure.unavailable }
        let required = [household] + (mandate.ceilingOutOfNetwork > before.ceilingOutOfNetwork ? before.coSigners : [])
        let value = MemberMandateChange(id: "22222222-2222-4222-8222-222222222222", before: before, mandate: mandate, requiredSigners: Array(Set(required)).sorted(), signedBy: [], state: "pending", createdAt: 1_800_000_000_002, updatedAt: 1_800_000_000_002)
        changes.removeAll { $0.id == value.id }; changes.append(value); return prepared(value)
    }
    func prepareMandateSignature(_ id: String) async throws -> PreparedMemberMandateChange {
        guard let value = changes.first(where: { $0.id == id }) else { throw MemberFailure.unavailable }; return prepared(value)
    }
    func submitMandateChange(_ value: PreparedMemberMandateChange, assertion: MemberPasskeyResponse) async throws -> MemberMandateChange {
        let signed = Array(Set(value.change.signedBy + [household])).sorted()
        let state = Set(signed) == Set(value.change.requiredSigners) ? "effective" : "pending"
        let result = MemberMandateChange(id: value.change.id, before: value.change.before, mandate: value.change.mandate, requiredSigners: value.change.requiredSigners, signedBy: signed, state: state, createdAt: value.change.createdAt, updatedAt: value.change.updatedAt + 1)
        changes.removeAll { $0.id == result.id }; changes.append(result)
        if state == "effective" { effective.removeAll { $0.id == result.mandate.id }; effective.append(result.mandate) }
        return result
    }
    func cancelMandateChange(_ id: String) async throws -> MemberMandateChange {
        guard let value = changes.first(where: { $0.id == id }) else { throw MemberFailure.unavailable }
        let result = MemberMandateChange(id: value.id, before: value.before, mandate: value.mandate, requiredSigners: value.requiredSigners, signedBy: value.signedBy, state: "cancelled", createdAt: value.createdAt, updatedAt: value.updatedAt + 1)
        changes.removeAll { $0.id == id }; changes.append(result); return result
    }
}

@MainActor private final class DialsFixturePasskeys: MemberPasskeyAuthorising {
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        .assertion(id: "fixture", clientDataJSON: "fixture", authenticatorData: "fixture", signature: "fixture", userHandle: "fixture")
    }
}

struct MemberDialsFixtureView: View {
    @StateObject private var account: MemberAccount
    init() {
        let service = DialsFixtureService()
        _account = StateObject(wrappedValue: MemberAccount(service: service, passkeys: DialsFixturePasskeys()))
    }
    var body: some View {
        MemberLimitsView(account: account)
            .task { if account.session == nil { await account.restore(household: "key:member-fixture"); await account.refreshDials() } }
    }
}
