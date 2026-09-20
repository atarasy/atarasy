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
    private var mandateReview: MemberMandateReview?
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
    private func read(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> (MemberHTTPReply, MemberSessionInfo) {
        guard let session = active else { throw MemberFailure.expired }
        guard live(session.info.expiresAt) else {
            generation &+= 1; active = nil; try vault.remove(environment: environment, household: session.info.household); throw MemberFailure.expired
        }
        let started = generation
        let reply = try await send(path, query: query, body: body, token: session.token)
        guard generation == started else { throw MemberFailure.superseded }
        guard live(session.info.expiresAt) else { active = nil; generation &+= 1; try vault.remove(environment: environment, household: session.info.household); throw MemberFailure.expired }
        if reply.status == 401 { active = nil; generation &+= 1; try vault.remove(environment: environment, household: session.info.household); throw MemberFailure.http(401) }
        return (reply, session.info)
    }
    private func identifier(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
    }
    /// §13.2, question 55. A mandate's identifier is its household's, a full stop and a label, and a
    /// household's is `key:` and the base64url SHA-256 of its public key.
    private func mandateIdentifier(_ id: String) throws {
        guard id.range(of: "^key:[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\\.[A-Za-z0-9_-]{1,64}\\z", options: .regularExpression) != nil else { throw MemberFailure.invalidInput }
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
        if detail.binding == "physical" && detail.state == "settled" {
            let (reply, session) = try await read("/offers/" + detail.id + "/settlement")
            guard same(session.household, detail.household), session.presenters.contains(where: { same($0, detail.presenter) }) else { throw MemberFailure.scopeMismatch }
            let receipt = try ReferenceResponseReader.settlement(status: reply.status, contentType: reply.contentType, data: reply.data, expectedOffer: detail.id)
            guard same(receipt.payer, detail.household), same(receipt.signedBy, detail.presenter) else { throw MemberFailure.scopeMismatch }
            return .settlement(receipt)
        }
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
        try mandateIdentifier(id); let (reply, info) = try await read("/_node/mandates/" + id)
        return try ReferenceResponseReader.mandate(status: reply.status, contentType: reply.contentType, data: reply.data, expectedID: id, expectedHousehold: info.household)
    }
    private func operationScope(_ handle: MemberOperationHandle) throws {
        guard UUID(uuidString: handle.id)?.uuidString.lowercased() == handle.id,
              let session = active?.info, live(session.expiresAt),
              same(handle.environment, environment.name), handle.origin == environment.origin,
              // Not the session id: binding to it stranded a result after signing in again. The journal
              // authorises by credential ownership, which the client cannot check because session info
              // carries no credential; a different passkey for this household is refused by the server.
              same(handle.household, session.household),
              session.presenters.contains(where: { same($0, handle.presenter) }) else { throw MemberFailure.scopeMismatch }
    }
    private func preparedOperation(_ reply: MemberHTTPReply, canonical: String, household: String, offer: String) throws -> MemberPreparedOperation {
        let result = try decode(MemberPreparedOperation.self, reply, keys: ["profile", "operationID", "requestDigest", "reviewedRevision", "expiresAt", "canonical", "review", "operationState", "publicKey", "authorisation"])
        guard result.profile == "atarasy.member-statement-authorisation.1",
              UUID(uuidString: result.operationID)?.uuidString.lowercased() == result.operationID,
              [result.requestDigest, result.reviewedRevision].allSatisfy({ $0.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil }),
              same(result.canonical, canonical), result.expiresAt >= 0, result.expiresAt <= Canonical.maximumInteger,
              ["prepared", "dispatching", "uncertain", "committed", "cancelled", "refused"].contains(result.operationState),
              ["prepared", "verified"].contains(result.authorisation),
              result.publicKey["rpId"] == .string(environment.origin.host!), result.publicKey["userVerification"] == .string("required"),
              case .array(let credentials) = result.publicKey["allowCredentials"], credentials.count == 1,
              case .object(let credential) = credentials[0], credential["type"] == .string("public-key"),
              case .string(let credentialID) = credential["id"], !credentialID.isEmpty else { throw MemberFailure.malformed }
        guard case .object(let review) = result.review, case .object(let statement) = review["statement"],
              statement["household"] == .string(household), statement["offer"] == .string(offer),
              case .object(let mandate) = review["mandate"], mandate["household"] == .string(household),
              case .integer(let carriage) = statement["carriage"], case .array(let rows) = statement["lines"],
              case .array(let disputed) = review["disputed"] else { throw MemberFailure.scopeMismatch }
        let lines = try rows.map { row -> StatementLine in
            guard case .object(let line) = row, case .string(let candidate) = line["candidate"],
                  case .string(let valence) = line["valence"], case .integer(let amount) = line["amount"] else { throw MemberFailure.malformed }
            return .init(candidate: candidate, valence: valence, amount: amount, disputed: disputed.contains(.string(candidate)))
        }
        guard same(try Canonical.statement(offer: offer, carriage: carriage, lines: lines), canonical) else { throw MemberFailure.scopeMismatch }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let scope = MemberJSON.array([.integer(1), .string(environment.name), .string(environment.origin.absoluteString), .string(environment.origin.host!)])
        let scopeText = String(decoding: try encoder.encode(scope), as: UTF8.self)
        let envelope = MemberJSON.array([.string(result.profile), .string(scopeText), .string(result.operationID), .string(result.requestDigest), .string(result.reviewedRevision)])
        let challenge = Canonical.challenge(String(decoding: try encoder.encode(envelope), as: UTF8.self))
        guard result.publicKey["challenge"] == .string(challenge) else { throw MemberFailure.scopeMismatch }
        return result
    }
    public func prepareStatement(_ local: PreparedMemberStatement, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedOperation) {
        guard let info = active?.info, same(local.sessionID, info.id), local.environment == environment,
              same(local.household, info.household), info.presenters.contains(where: { same($0, local.presenter) }) else { throw MemberFailure.scopeMismatch }
        struct Input: Encodable { let offer: String; let disputed: [String] }
        let (reply, _) = try await read("/member/statements/prepare", body: JSONEncoder().encode(Input(offer: local.offer, disputed: local.disputed)))
        let prepared = try preparedOperation(reply, canonical: local.canonical, household: local.household, offer: local.offer)
        guard prepared.operationState == "prepared", live(prepared.expiresAt), prepared.expiresAt <= info.expiresAt else { throw MemberFailure.expired }
        guard case .string(let challenge) = prepared.publicKey["challenge"], case .array(let allowed) = prepared.publicKey["allowCredentials"], case .object(let credential) = allowed[0], case .string(let credentialID) = credential["id"] else { throw MemberFailure.malformed }
        let handle = MemberOperationHandle(id: prepared.operationID, environment: environment.name, origin: environment.origin, sessionID: info.id, household: info.household, presenter: local.presenter, offer: local.offer, canonical: local.canonical, expiresAt: prepared.expiresAt, requestDigest: prepared.requestDigest, reviewedRevision: prepared.reviewedRevision, challenge: challenge, credentialID: credentialID, attempted: false)
        // A handle saved by an earlier session for the same operation is the one to keep: its session
        // id differs, and `claim` compares against what is stored.
        do { try store.save(handle); return (try store.load(id: handle.id) ?? handle, prepared) } catch { throw MemberFailure.storage }
    }
    public func operationReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedOperation {
        try operationScope(handle)
        let (reply, _) = try await read("/member/operations/" + handle.id)
        let result = try preparedOperation(reply, canonical: handle.canonical, household: handle.household, offer: handle.offer)
        guard result.operationID == handle.id, result.expiresAt == handle.expiresAt, result.requestDigest == handle.requestDigest, result.reviewedRevision == handle.reviewedRevision, result.publicKey["challenge"] == .string(handle.challenge) else { throw MemberFailure.scopeMismatch }
        return result
    }
    private func operationOutcome(_ reply: MemberHTTPReply, handle: MemberOperationHandle) throws -> MemberOperationOutcome {
        struct Envelope: Decodable { let operationID: String; let operationState: String; let receipt: MemberJSON }
        let value = try decode(Envelope.self, reply, keys: ["operationID", "operationState", "receipt"])
        guard value.operationID == handle.id else { throw MemberFailure.scopeMismatch }
        if value.operationState != "committed" {
            guard ["prepared", "dispatching", "uncertain", "cancelled", "refused"].contains(value.operationState), value.receipt == .null else { throw MemberFailure.malformed }
            return .pending(value.operationState)
        }
        let receipt = try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: JSONEncoder().encode(value.receipt), expectedOffer: handle.offer)
        guard same(receipt.payer, handle.household), same(receipt.signedBy, handle.presenter), receipt.signedAs == "agent" else { throw MemberFailure.scopeMismatch }
        let canonicalParts = handle.canonical.split(separator: "\n", omittingEmptySubsequences: false)
        guard canonicalParts.count >= 3, let carriage = Int64(canonicalParts[2]) else { throw MemberFailure.malformed }
        // Question 46: a line the collection recorded missing is on the signed statement at 0,
        // while the receipt carries it at its stock value. A lost line the deadline made is
        // on the receipt and not on the statement, so only lost lines the statement names stay.
        let signedLost = Set(canonicalParts.dropFirst(3).compactMap { part -> String? in
            let fields = part.split(separator: ":", omittingEmptySubsequences: false)
            return fields.count == 4 && fields[1] == "lost" ? String(fields[0]) : nil
        })
        // A receipt cannot say the household disputed a line it was never shown.
        guard !receipt.lines.contains(where: { $0.valence == "lost" && $0.disputed && !signedLost.contains($0.candidate) }) else { throw MemberFailure.scopeMismatch }
        let lines = receipt.lines.compactMap { line -> StatementLine? in
            if line.valence == "lost" {
                guard signedLost.contains(line.candidate) else { return nil }
                return StatementLine(candidate: line.candidate, valence: "lost", amount: 0, disputed: line.disputed)
            }
            return StatementLine(candidate: line.candidate, valence: line.valence, amount: line.amount, disputed: line.disputed)
        }
        guard same(try Canonical.statement(offer: handle.offer, carriage: carriage, lines: lines), handle.canonical) else { throw MemberFailure.scopeMismatch }
        // The receipt names the signature that settled the offer. Matching lines do not show it was
        // this device's: another device, or a second attempt, signs the same statement.
        guard handle.attempted else { return .settledElsewhere(receipt) }
        guard let fingerprint = handle.confirmationFingerprint else { return .settledUnverified(receipt) }
        guard let confirmation = receipt.confirmation, same(Canonical.digest(confirmation), fingerprint) else { return .settledElsewhere(receipt) }
        return .committed(receipt)
    }
    /// A failed read never establishes that dispatch had no effect.
    public func operationOutcome(_ handle: MemberOperationHandle) async -> MemberOperationOutcome {
        do {
            try Task.checkCancellation(); try operationScope(handle)
            let (reply, _) = try await read("/member/operations/" + handle.id + "/outcome")
            try Task.checkCancellation()
            return try operationOutcome(reply, handle: handle)
        } catch { return .unresolved }
    }
    public func submitStatement(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberOperationOutcome {
        try Task.checkCancellation(); try operationScope(handle)
        guard live(handle.expiresAt), !handle.attempted else { throw MemberFailure.expired }
        guard same(assertion.id, handle.credentialID), case .string(let encoded) = assertion.response["clientDataJSON"] else { throw MemberFailure.invalidInput }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              let clientData = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              clientData["type"] as? String == "webauthn.get", clientData["challenge"] as? String == handle.challenge,
              clientData["origin"] as? String == environment.origin.absoluteString,
              case .string(let signature) = assertion.response["signature"], !signature.isEmpty else { throw MemberFailure.scopeMismatch }
        struct Input: Encodable { let assertion: MemberPasskeyResponse }
        let body = try JSONEncoder().encode(Input(assertion: assertion))
        guard body.count <= 16_384 else { throw MemberFailure.invalidInput }
        // No suspension between checking the session and claiming the durable attempt.
        try store.claim(handle, confirmation: signature)
        do {
            let (reply, _) = try await read("/member/operations/" + handle.id + "/submit", body: body)
            try Task.checkCancellation()
            return try operationOutcome(reply, handle: handle.markedAttempted(confirmation: signature))
        } catch { return .unresolved }
    }
    public func cancelOperation(_ handle: MemberOperationHandle) async throws {
        try operationScope(handle)
        let (reply, _) = try await read("/member/operations/" + handle.id + "/cancel", body: Data("{}".utf8))
        // The public cancellation route returns only an acknowledgement, not the journal row.
        guard reply.status == 200 else { throw MemberFailure.http(reply.status) }
        struct CancellationReply: Decodable { let cancelled: Bool }
        guard let acknowledgement = try? JSONDecoder().decode(CancellationReply.self, from: reply.data),
              acknowledgement.cancelled else { throw MemberFailure.malformed }
    }

}


extension MemberClient {
    private func checkedMandate(_ mandate: MemberMandate, household: String) throws {
        try mandateIdentifier(mandate.id)
        guard same(mandate.household, household), mandate.id.hasPrefix(household + "."), live(mandate.lapsesAt),
              Set(mandate.coSigners).count == mandate.coSigners.count,
              mandate.coSigners.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }) else { throw MemberFailure.scopeMismatch }
        _ = try mandate.canonical(host: environment.origin.host!)
    }
    public func unsignedMandates() async throws -> [MemberMandate] {
        struct List: Decodable { let mandates: [MemberMandate] }
        let (reply, info) = try await read("/member/mandates/list", body: Data("{}".utf8))
        let list = try decode(List.self, reply, keys: ["mandates"]).mandates
        guard list.count <= 100, Set(list.map(\.id)).count == list.count else { throw MemberFailure.malformed }
        for mandate in list { try checkedMandate(mandate, household: info.household) }
        return list
    }
    public func prepareMandate(_ selected: MemberMandate) async throws -> MemberMandateReview {
        mandateReview = nil
        struct Prepared: Decodable { let mandate: MemberMandate; let publicKey: [String: MemberJSON] }
        let (reply, info) = try await read("/member/mandates/prepare", body: JSONEncoder().encode(["mandate": selected.id]))
        let prepared = try decode(Prepared.self, reply, keys: ["mandate", "publicKey"])
        try checkedMandate(prepared.mandate, household: info.household)
        let host = environment.origin.host!
        guard prepared.mandate == selected, prepared.publicKey["challenge"] == .string(try Canonical.challenge(selected.canonical(host: host))) else { throw MemberFailure.scopeMismatch }
        // This local review deadline is not a server-issued expiry or operation ID.
        let ceremony = MemberCeremony(id: UUID().uuidString, expiresAt: min(info.expiresAt, now() + 300_000), publicKey: prepared.publicKey)
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .statement, now: now())
        guard options.allowedCredentialIDs.count == 1 else { throw MemberFailure.scopeMismatch }
        let review = MemberMandateReview(mandate: selected, host: host, ceremony: ceremony, sessionID: info.id, credentialID: PasskeyBytes.encode(options.allowedCredentialIDs[0]))
        mandateReview = review
        return review
    }
    public func submitMandate(_ review: MemberMandateReview, assertion: MemberPasskeyResponse) async throws {
        guard let held = mandateReview, held.ceremony.id == review.ceremony.id, let active,
              same(active.info.id, held.sessionID), live(active.info.expiresAt), live(held.ceremony.expiresAt),
              same(assertion.id, held.credentialID), case .string(let encoded) = assertion.response["clientDataJSON"] else { throw MemberFailure.scopeMismatch }
        let bytes = try PasskeyBytes.decode(encoded, maximum: 8192)
        guard let clientData = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              clientData["type"] as? String == "webauthn.get", clientData["origin"] as? String == environment.origin.absoluteString,
              clientData["challenge"] as? String == Canonical.challenge(try held.mandate.canonical(host: held.host)) else { throw MemberFailure.scopeMismatch }
        // The mandate engine takes the flat assertion contract, not the login
        // WebAuthn response envelope. Its three byte fields use standard base64.
        func field(_ key: String) throws -> String {
            guard case .string(let value) = assertion.response[key] else { throw MemberFailure.invalidInput }
            return try PasskeyBytes.decode(value, maximum: 8192).base64EncodedString()
        }
        struct EngineAssertion: Encodable { let client_data_json: String; let authenticator_data: String; let signature: String }
        struct Input: Encodable { let mandate: String; let assertion: EngineAssertion }
        let wire = try EngineAssertion(client_data_json: field("clientDataJSON"), authenticator_data: field("authenticatorData"), signature: field("signature"))
        let body = try JSONEncoder().encode(Input(mandate: held.mandate.id, assertion: wire))
        guard body.count <= 16_384 else { throw MemberFailure.invalidInput }
        try Task.checkCancellation()
        // Consume before suspension. An uncertain answer must be inspected, never replayed.
        mandateReview = nil
        do {
            let (reply, _) = try await read("/member/mandates/submit", body: body)
            let recorded = try decode(MemberMandate.self, reply)
            guard recorded == held.mandate else { throw MemberFailure.scopeMismatch }
        } catch { throw MemberFailure.uncertainVerification }
    }
}
