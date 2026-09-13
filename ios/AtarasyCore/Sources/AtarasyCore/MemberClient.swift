import Foundation

public enum MemberLogoutOutcome: Sendable { case noLocalSession, revoked }
public actor MemberClient {
    private let environment: MemberEnvironment
    private let transport: any MemberHTTPTransport
    private let vault: any MemberSessionVault
    private let now: @Sendable () -> Int64
    private var active: StoredMemberSession?
    private var generation: UInt64 = 0
    private var authenticating = false
    public init(environment: MemberEnvironment, transport: any MemberHTTPTransport, vault: any MemberSessionVault, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.environment = environment; self.transport = transport; self.vault = vault; self.now = now
    }
    private func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
    private func live(_ expiry: Int64) -> Bool { expiry > now() && expiry <= 9_007_199_254_740_991 }
    private func valid(_ info: MemberSessionInfo) -> Bool {
        !info.id.isEmpty && !info.household.isEmpty && live(info.expiresAt) && info.presenters.allSatisfy { !$0.isEmpty }
    }
    private func tokenValid(_ token: String) -> Bool { token.range(of: "^amr1_[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil }
    private func send(_ path: String, query: [URLQueryItem] = [], body: Data? = nil, token: String? = nil) async throws -> MemberHTTPReply {
        var c = URLComponents(url: environment.origin, resolvingAgainstBaseURL: false)!
        c.path = path; c.queryItems = query.isEmpty ? nil : query
        // URLSearchParams on the service decodes a literal + as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { throw MemberFailure.invalidInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { guard tokenValid(token) else { throw MemberFailure.malformed }; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let reply: MemberHTTPReply
        do { reply = try await transport.send(request) } catch { throw MemberFailure.unavailable }
        guard reply.url == url else { throw MemberFailure.scopeMismatch }
        guard reply.cacheControl?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("no-store") == true else { throw MemberFailure.malformed }
        return reply
    }
    private func decode<T: Decodable>(_ type: T.Type, _ reply: MemberHTTPReply, status: Int = 200, keys: Set<String>? = nil) throws -> T {
        guard reply.status == status else { throw MemberFailure.http(reply.status) }
        guard reply.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw MemberFailure.malformed }
        if let keys {
            guard let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any], Set(object.keys) == keys else { throw MemberFailure.malformed }
        }
        do { return try JSONDecoder().decode(type, from: reply.data) } catch { throw MemberFailure.malformed }
    }
    private func ceremony(_ reply: MemberHTTPReply, registration: Bool) throws -> MemberCeremony {
        let value = try decode(MemberCeremony.self, reply, keys: ["id", "expiresAt", "publicKey"])
        guard UUID(uuidString: value.id) != nil, live(value.expiresAt), case .string(let challenge) = value.publicKey["challenge"],
              challenge.range(of: "^[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil else { throw MemberFailure.malformed }
        if registration {
            guard case .object(let rp) = value.publicKey["rp"], rp["id"] == .string(environment.origin.host!),
                  case .object(let selection) = value.publicKey["authenticatorSelection"], selection["userVerification"] == .string("required"), selection["residentKey"] == .string("required"),
                  value.publicKey["pubKeyCredParams"] == .array([.object(["type": .string("public-key"), "alg": .integer(-7)])]),
                  case .object(let user) = value.publicKey["user"], case .string(let handle) = user["id"], !handle.isEmpty else { throw MemberFailure.scopeMismatch }
        } else {
            guard value.publicKey["rpId"] == .string(environment.origin.host!), value.publicKey["userVerification"] == .string("required"), value.publicKey["allowCredentials"] == .array([]) else { throw MemberFailure.scopeMismatch }
        }
        return value
    }
    public func registrationOptions(invitation: String) async throws -> MemberCeremony {
        guard invitation.range(of: "^aen1_[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
        let started = generation
        let reply = try await send("/auth/enrollment/options", body: JSONEncoder().encode(["invitation": invitation]))
        guard started == generation else { throw MemberFailure.superseded }
        return try ceremony(reply, registration: true)
    }
    public func loginOptions() async throws -> MemberCeremony {
        let started = generation
        let reply = try await send("/auth/login/options", body: Data("{}".utf8))
        guard started == generation else { throw MemberFailure.superseded }
        return try ceremony(reply, registration: false)
    }
    private struct Verification: Encodable { let id: String; let response: MemberPasskeyResponse }
    public func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws {
        guard live(ceremony.expiresAt) else { throw MemberFailure.expired }
        struct Registered: Decodable { let registered: Bool }
        do {
            let result = try decode(Registered.self, await send("/auth/enrollment/verify", body: JSONEncoder().encode(Verification(id: ceremony.id, response: response))), status: 201, keys: ["registered"])
            guard result.registered else { throw MemberFailure.malformed }
        } catch MemberFailure.http(let status) { throw MemberFailure.http(status) }
        catch { throw MemberFailure.uncertainVerification }
    }
    public func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo {
        guard !authenticating else { throw MemberFailure.busy }
        guard live(ceremony.expiresAt) else { throw MemberFailure.expired }
        authenticating = true; defer { authenticating = false }
        generation &+= 1; let started = generation; active = nil
        struct Grant: Decodable { let id: String; let token: String; let expiresAt: Int64 }
        do {
            let grant = try decode(Grant.self, await send("/auth/login/verify", body: JSONEncoder().encode(Verification(id: ceremony.id, response: response))), keys: ["id", "token", "expiresAt"])
            guard started == generation else { throw MemberFailure.superseded }
            guard tokenValid(grant.token), live(grant.expiresAt), !grant.id.isEmpty else { throw MemberFailure.malformed }
            let info = try decode(MemberSessionInfo.self, await send("/auth/session", token: grant.token), keys: ["id", "household", "presenters", "expiresAt"])
            guard started == generation else { throw MemberFailure.superseded }
            guard valid(info), same(info.id, grant.id), info.expiresAt == grant.expiresAt else { throw MemberFailure.scopeMismatch }
            let stored = StoredMemberSession(token: grant.token, info: info)
            do { try vault.save(stored, environment: environment) } catch { throw MemberFailure.storage }
            active = stored; return info
        } catch MemberFailure.superseded { throw MemberFailure.superseded }
        catch MemberFailure.storage { throw MemberFailure.storage }
        catch MemberFailure.http(let status) { throw MemberFailure.http(status) }
        catch { throw MemberFailure.uncertainVerification }
    }
    public func restore(household: String) async throws -> MemberSessionInfo? {
        generation &+= 1; let started = generation; active = nil
        let saved: StoredMemberSession?
        do { saved = try vault.load(environment: environment, household: household) } catch { throw MemberFailure.storage }
        guard let saved else { return nil }
        guard tokenValid(saved.token), valid(saved.info), same(saved.info.household, household) else {
            try vault.remove(environment: environment, household: household); throw MemberFailure.expired
        }
        let reply = try await send("/auth/session", token: saved.token)
        guard started == generation else { throw MemberFailure.superseded }
        if reply.status == 401 { try vault.remove(environment: environment, household: household); throw MemberFailure.http(401) }
        let info = try decode(MemberSessionInfo.self, reply, keys: ["id", "household", "presenters", "expiresAt"])
        guard valid(info), same(info.id, saved.info.id), same(info.household, household), info.expiresAt == saved.info.expiresAt else { throw MemberFailure.scopeMismatch }
        let current = StoredMemberSession(token: saved.token, info: info)
        try vault.save(current, environment: environment); active = current; return info
    }
    public func logout() async throws -> MemberLogoutOutcome {
        generation &+= 1; let old = active; active = nil
        guard let old else { return .noLocalSession }
        do { try vault.remove(environment: environment, household: old.info.household) } catch { throw MemberFailure.storage }
        do {
            let reply = try await send("/auth/logout", body: Data("{}".utf8), token: old.token)
            guard reply.status == 204, reply.data.isEmpty else { throw MemberFailure.malformed }
            return .revoked
        } catch { throw MemberFailure.remoteLogoutUnconfirmed }
    }
    private func read(_ path: String, query: [URLQueryItem] = []) async throws -> (MemberHTTPReply, MemberSessionInfo) {
        guard let session = active else { throw MemberFailure.expired }
        guard live(session.info.expiresAt) else {
            generation &+= 1; active = nil; try vault.remove(environment: environment, household: session.info.household); throw MemberFailure.expired
        }
        let started = generation
        let reply = try await send(path, query: query, token: session.token)
        guard generation == started else { throw MemberFailure.superseded }
        guard live(session.info.expiresAt) else { active = nil; generation &+= 1; try vault.remove(environment: environment, household: session.info.household); throw MemberFailure.expired }
        if reply.status == 401 { active = nil; generation &+= 1; try vault.remove(environment: environment, household: session.info.household); throw MemberFailure.http(401) }
        return (reply, session.info)
    }
    private func identifier(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
    }
    public func offers(presenter: String) async throws -> [MemberOfferSummary] {
        guard let info = active?.info, info.presenters.contains(where: { same($0, presenter) }) else { throw MemberFailure.scopeMismatch }
        let (reply, session) = try await read("/offers", query: [URLQueryItem(name: "household", value: info.household), URLQueryItem(name: "presenter", value: presenter)])
        struct List: Decodable { let offers: [MemberOfferSummary] }
        let offers = try decode(List.self, reply, keys: ["offers"]).offers
        guard offers.allSatisfy({ same($0.household, session.household) && same($0.presenter, presenter) && !$0.id.isEmpty }) else { throw MemberFailure.scopeMismatch }
        return offers
    }
    public func offer(id: String) async throws -> MemberOfferSummary {
        try identifier(id); let (reply, session) = try await read("/offers/" + id)
        let offer = try decode(MemberOfferSummary.self, reply)
        guard same(offer.id, id), same(offer.household, session.household), session.presenters.contains(where: { same($0, offer.presenter) }) else { throw MemberFailure.scopeMismatch }
        return offer
    }
    public func offerDetail(id: String) async throws -> MemberOfferDetail {
        try identifier(id); let (reply, session) = try await read("/offers/" + id)
        guard reply.status == 200 else { throw MemberFailure.http(reply.status) }
        guard reply.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw MemberFailure.malformed }
        let value = try MemberOfferDetail.decode(reply.data, expectedID: id, household: session.household)
        guard session.presenters.contains(where: { same($0, value.presenter) }) else { throw MemberFailure.scopeMismatch }
        return value
    }
    public func review(detail: MemberOfferDetail) async throws -> MemberReview {
        try identifier(detail.id)
        guard ["physical", "digital"].contains(detail.binding) else { throw MemberFailure.invalidInput }
        let (reply, session) = try await read("/offers/" + detail.id + (detail.binding == "physical" ? "/statement" : "/approval"))
        guard Data(session.household.utf8) == Data(detail.household.utf8), session.presenters.contains(where: { Data($0.utf8) == Data(detail.presenter.utf8) }) else { throw MemberFailure.scopeMismatch }
        guard reply.status == 200 else { throw MemberFailure.http(reply.status) }
        guard reply.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw MemberFailure.malformed }
        return try detail.binding == "physical" ? .statement(MemberStatement.decode(reply.data, detail: detail)) : .approval(MemberApproval.decode(reply.data, detail: detail))
    }
    /// Read-only reconciliation. No failure here authorises a retry of a write.
    public func reconcile(_ pending: PendingMemberStatement) async -> MemberStatementReadback {
        guard !Task.isCancelled else { return .unresolved }
        guard let session = active?.info, pending.permits(environment: environment, session: session, now: now()) else { return .sessionUnavailable }
        do {
            let (reply, current) = try await read("/offers/" + pending.prepared.offer + "/settlement")
            guard pending.permits(environment: environment, session: current, now: now()) else { return .sessionUnavailable }
            let receipt = try ReferenceResponseReader.settlement(status: reply.status, contentType: reply.contentType, data: reply.data, expectedOffer: pending.prepared.offer)
            guard !Task.isCancelled else { return .unresolved }
            return pending.inspect(receipt)
        } catch {
            if active == nil || error as? MemberFailure == .expired || error as? MemberFailure == .superseded { return .sessionUnavailable }
            return .unresolved
        }
    }
    public func settlement(offerID: String) async throws -> ProtocolSettlement {
        try identifier(offerID); let (reply, _) = try await read("/offers/" + offerID + "/settlement")
        return try ReferenceResponseReader.settlement(status: reply.status, contentType: reply.contentType, data: reply.data, expectedOffer: offerID)
    }
    public func mandate(id: String) async throws -> Mandate {
        try identifier(id); let (reply, info) = try await read("/_node/mandates/" + id)
        return try ReferenceResponseReader.mandate(status: reply.status, contentType: reply.contentType, data: reply.data, expectedID: id, expectedHousehold: info.household)
    }
}
