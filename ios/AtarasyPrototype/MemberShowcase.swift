#if ATARASY_UI_TEST_FIXTURES
import SwiftUI
import AtarasyCore

// A synthetic household for driving the member's app end to end in the UI-testing configuration
// only: a box collected with goods used, a box at home, a digital proposal and a settled box, from
// two shops. No network, provider or authenticator. Shop, maker and product names are invented.
// Launch with `--showcase`; add `--showcase-lose-reply` to lose the response to the first
// signature, which is the case IOS-10 and IOS-16 are about.

private enum Showcase {
    static let household = "key:showcase" + String(repeating: "x", count: 34) + "A"
    static let mandateID = household + ".home"
    static let shopA = "vox_presenter_showcase_a"
    static let shopB = "vox_presenter_showcase_b"
    static let merchantA = "みどり薬局 本町店"
    static let merchantB = "暮らしの道具 ことり"
    static let origin = URL(string: "https://showcase.atarasy.invalid")!
    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let day: Int64 = 86_400_000
    static let started = now

    static func block(_ merchant: String) -> [String: Any] {
        ["merchant": merchant, "product": NSNull(), "version": "2026-09", "signature": "showcase-signature",
         "items": [["label": "お支払い", "value": "ご利用明細に署名いただいた後、登録済みのカードで決済します。"],
                   ["label": "お届け", "value": "週に一度、ご自宅へお届けし、前回の箱を回収します。"],
                   ["label": "返品", "value": "未開封の商品は次回の回収時にお戻しください。開封済みの商品はお使いになった分のみのお支払いです。"],
                   ["label": "送料", "value": "1回のお届けにつき350円。ご利用がない回はいただきません。"]],
         "contact": ["kind": "email", "value": "support@example.invalid"]]
    }
    static func candidate(_ id: String, _ product: String, _ name: String, _ variant: String?, merchant: String, maker: String, price: Int64, valence: String, collected: String?, giver: String? = nil, exploration: Bool = false) -> [String: Any] {
        var c: [String: Any] = ["id": id, "product": product, "quantity": 1, "unit_price": price, "merchant": merchant, "maker": maker, "ships": "ことり便",
                                "category": NSNull(), "predicted_conversion": NSNull(), "is_exploration": exploration, "given_by": giver ?? NSNull(),
                                "valence": valence, "decided_at": NSNull(), "kept_as": NSNull(), "lineage": NSNull(), "collected_as": collected ?? NSNull(), "name": name]
        if let variant { c["variant"] = variant }
        return c
    }
    static func offer(_ id: String, binding: String, presenter: String, state: String, presentedAgo: Int64, expiresIn: Int64, candidates: [[String: Any]], merchants: [String]) -> [String: Any] {
        ["id": id, "binding": binding, "household": household, "presenter": presenter, "presenter_attested": true, "purpose": binding == "physical" ? "trial" : "replenish",
         "price_band": NSNull(), "giver": NSNull(), "config_version": "showcase-1", "presented_at": started - presentedAgo, "expires_at": started + expiresIn,
         "state": state, "exploration_floor_met": true, "mandate": mandateID, "candidates": candidates, "disclosures": merchants.map(block)]
    }
    static var mandateJSON: [String: Any] {
        ["id": mandateID, "household": household, "ceiling_out_of_network": 5_000, "ceiling_daily": 20_000, "cooling_seconds": 86_400, "co_signers": [String](), "lapses_at": started + 180 * day, "version": 1]
    }
    static func int(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
    static func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static func hex(_ text: String) -> String { Canonical.digest(text) }
    /// The challenge `MemberPreparedDecision.validate` recomputes from the envelope.
    static func challenge(environment: MemberEnvironment, profile: String, operation: String, digest: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let scope = MemberJSON.array([.integer(1), .string(environment.name), .string(environment.origin.absoluteString), .string(environment.origin.host!)])
        let scopeText = String(decoding: try! encoder.encode(scope), as: UTF8.self)
        let envelope = MemberJSON.array([.string(profile), .string(scopeText), .string(operation), .string(digest), .string(digest)])
        return Canonical.challenge(String(decoding: try! encoder.encode(envelope), as: UTF8.self))
    }
}

private actor ShowcaseService: MemberAccountService, MemberStatementService, MemberDecisionService, MemberWithdrawalService {
    let environment: MemberEnvironment
    let loseReply: Bool
    var offers: [String: [String: Any]] = [:]
    var settlements: [String: [String: Any]] = [:]
    var prepared: [String: [String: Any]] = [:]
    var outcomes: [String: Any] = [:]
    var effective: [MemberMandate]
    var changes: [MemberMandateChange] = []
    var lostOnce = false
    let session: MemberSessionInfo

    init(environment: MemberEnvironment, loseReply: Bool) {
        self.environment = environment; self.loseReply = loseReply
        session = MemberSessionInfo(id: "showcase-session", household: Showcase.household, presenters: [Showcase.shopA, Showcase.shopB], expiresAt: Showcase.started + Showcase.day)
        effective = [MemberMandate(id: Showcase.mandateID, household: Showcase.household, ceilingOutOfNetwork: 5_000, ceilingDaily: 20_000, coolingSeconds: 86_400, coSigners: [], lapsesAt: Showcase.started + 180 * Showcase.day, version: 1)]
        let a = Showcase.merchantA, b = Showcase.merchantB, d = Showcase.day
        offers["box-collected"] = Showcase.offer("box-collected", binding: "physical", presenter: Showcase.shopA, state: "expired", presentedAgo: 8 * d, expiresIn: -1 * d, candidates: [
            Showcase.candidate("c1", "hand-cream-50", "薬用ハンドクリーム", "50g", merchant: a, maker: "やまと製薬", price: 880, valence: "consumed", collected: "consumed"),
            Showcase.candidate("c2", "sencha-20", "煎茶 ティーバッグ", "20包", merchant: a, maker: "丸山茶園", price: 540, valence: "consumed", collected: "consumed"),
            Showcase.candidate("c3", "wipes-30", "除菌ウェットシート", "30枚", merchant: a, maker: "しろくま生活", price: 330, valence: "returned", collected: "returned"),
            Showcase.candidate("c4", "soap-gift", "手づくり石けん", "ミニサイズ", merchant: a, maker: "森の石けん工房", price: 600, valence: "consumed", collected: "consumed", giver: "森の石けん工房"),
            Showcase.candidate("c5", "swabs-200", "綿棒", "200本", merchant: a, maker: "しろくま生活", price: 220, valence: "lost", collected: "missing"),
        ], merchants: [a])
        offers["box-home"] = Showcase.offer("box-home", binding: "physical", presenter: Showcase.shopB, state: "presented", presentedAgo: 1 * d, expiresIn: 6 * d, candidates: [
            Showcase.candidate("h1", "bamboo-brush-2", "竹の歯ブラシ", "2本組", merchant: b, maker: "ことり工房", price: 660, valence: "offered", collected: nil),
            Showcase.candidate("h2", "beeswax-wrap-m", "蜜蝋ラップ", "Mサイズ", merchant: b, maker: "はちみつ舎", price: 1_320, valence: "offered", collected: nil, exploration: true),
            Showcase.candidate("h3", "herb-tea", "季節のハーブティー", "5包", merchant: b, maker: "ハーブ農園 そよぎ", price: 700, valence: "offered", collected: nil, giver: "ハーブ農園 そよぎ"),
        ], merchants: [b])
        offers["proposal-refill"] = Showcase.offer("proposal-refill", binding: "digital", presenter: Showcase.shopA, state: "presented", presentedAgo: 2 * 3_600_000, expiresIn: 2 * d, candidates: [
            Showcase.candidate("p1", "detergent-refill", "洗濯洗剤 詰め替え", "1.2kg", merchant: a, maker: "しろくま生活", price: 598, valence: "offered", collected: nil),
            Showcase.candidate("p2", "softener-refill", "柔軟剤 詰め替え", "無香料 480ml", merchant: a, maker: "やまと製薬", price: 480, valence: "offered", collected: nil, exploration: true),
        ], merchants: [a])
        offers["box-settled"] = Showcase.offer("box-settled", binding: "physical", presenter: Showcase.shopB, state: "settled", presentedAgo: 20 * d, expiresIn: -13 * d, candidates: [
            Showcase.candidate("s1", "linen-towel", "リネンのふきん", nil, merchant: b, maker: "ことり工房", price: 990, valence: "consumed", collected: "consumed"),
            Showcase.candidate("s2", "candle", "みつろうキャンドル", nil, merchant: b, maker: "はちみつ舎", price: 1_100, valence: "returned", collected: "returned"),
        ], merchants: [b])
        settlements["box-settled"] = ["offer": "box-settled", "settled_at": Showcase.started - 12 * d, "kept_amount": 0, "consumed_amount": 990, "lost_amount": 0, "charged": 990, "disputed_amount": 0,
            "lines": [["candidate": "s1", "product": "linen-towel", "merchant": b, "maker": "ことり工房", "ships": "ことり便", "valence": "consumed", "amount": 990, "disputed": false, "name": "リネンのふきん"]],
            "payer": Showcase.household, "signed_by": Showcase.shopB, "signed_as": "agent", "receipt": "showcase-receipt", "confirmation": NSNull()]
    }

    // MARK: account
    func registrationOptions(invitation: String) async throws -> MemberCeremony { throw MemberFailure.unavailable }
    func loginOptions() async throws -> MemberCeremony { throw MemberFailure.unavailable }
    func register(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws { throw MemberFailure.unavailable }
    func login(ceremony: MemberCeremony, response: MemberPasskeyResponse) async throws -> MemberSessionInfo { session }
    func restore(household: String) async throws -> MemberSessionInfo? { session }
    func logout() async throws -> MemberLogoutOutcome { .revoked }
    func unsignedMandates() async throws -> [MemberMandate] { [] }
    func effectiveMandates() async throws -> [MemberMandate] { effective }
    func mandateChanges() async throws -> [MemberMandateChange] { changes }
    func prepareMandateChange(_ mandate: MemberMandate) async throws -> PreparedMemberMandateChange {
        guard let before = effective.first(where: { $0.id == mandate.id }) else { throw MemberFailure.unavailable }
        let change = MemberMandateChange(id: UUID().uuidString.lowercased(), before: before, mandate: mandate, requiredSigners: [Showcase.household] + before.coSigners, signedBy: [], state: "pending", createdAt: Showcase.now, updatedAt: Showcase.now)
        changes.append(change)
        return PreparedMemberMandateChange(change: change, ceremony: MemberCeremony(id: change.id, expiresAt: Showcase.now + 600_000, publicKey: [:]), sessionID: session.id, credentialID: "showcase")
    }
    func prepareMandateSignature(_ id: String) async throws -> PreparedMemberMandateChange {
        guard let change = changes.first(where: { $0.id == id }) else { throw MemberFailure.unavailable }
        return PreparedMemberMandateChange(change: change, ceremony: MemberCeremony(id: id, expiresAt: Showcase.now + 600_000, publicKey: [:]), sessionID: session.id, credentialID: "showcase")
    }
    func submitMandateChange(_ prepared: PreparedMemberMandateChange, assertion: MemberPasskeyResponse) async throws -> MemberMandateChange {
        let c = prepared.change, signed = Array(Set(c.signedBy + [Showcase.household])).sorted()
        let state = Set(signed) == Set(c.requiredSigners) ? "effective" : "pending"
        let result = MemberMandateChange(id: c.id, before: c.before, mandate: c.mandate, requiredSigners: c.requiredSigners, signedBy: signed, state: state, createdAt: c.createdAt, updatedAt: Showcase.now)
        changes.removeAll { $0.id == c.id }; changes.append(result)
        if state == "effective" { effective = [result.mandate] }
        return result
    }
    func cancelMandateChange(_ id: String) async throws -> MemberMandateChange {
        guard let c = changes.first(where: { $0.id == id }) else { throw MemberFailure.unavailable }
        let result = MemberMandateChange(id: c.id, before: c.before, mandate: c.mandate, requiredSigners: c.requiredSigners, signedBy: c.signedBy, state: "cancelled", createdAt: c.createdAt, updatedAt: Showcase.now)
        changes.removeAll { $0.id == id }; changes.append(result); return result
    }

    // MARK: proposals
    func offers(presenter: String) async throws -> [MemberOfferSummary] {
        try offers.values.filter { $0["presenter"] as? String == presenter }.map { try JSONDecoder().decode(MemberOfferSummary.self, from: Showcase.data($0)) }
    }
    func offerDetail(id: String) async throws -> MemberOfferDetail {
        guard let value = offers[id] else { throw MemberFailure.unavailable }
        return try MemberOfferDetail.decode(Showcase.data(value), expectedID: id, household: Showcase.household)
    }
    func review(detail: MemberOfferDetail) async throws -> MemberReview {
        if detail.binding == "digital" { return .approval(try MemberApproval.decode(Showcase.data(approvalJSON(detail.id)), detail: detail)) }
        if detail.state == "settled", let s = settlements[detail.id] {
            return .settlement(try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: Showcase.data(s), expectedOffer: detail.id), nil, detail.disclosures)
        }
        return .statement(try MemberStatement.decode(Showcase.data(statementJSON(detail.id, challenge: true)), detail: detail))
    }
    private func approvalJSON(_ id: String) -> [String: Any] {
        let offer = offers[id]!, candidates = offer["candidates"] as! [[String: Any]]
        let why: [String: (alternatives: [String], against: String)] = [
            "p1": (["同じ洗剤の本体ボトル（820円）", "今回は見送る"], "前回の詰め替えから3週間で、まだ半分ほど残っている可能性があります。"),
            "p2": (["いまお使いの柔軟剤を続ける", "柔軟剤を使わない"], "初めての商品です。香りの好みに合わない場合、開封後は返品できません。"),
        ]
        return ["offer": id, "presenter": offer["presenter"]!, "expires_at": offer["expires_at"]!, "carriage": 300, "price_band": NSNull(), "reminded": false,
                "disclosures": offer["disclosures"]!, "mandate": ["kind": "standing", "scope": "日用品の補充", "lapses_at": Showcase.started + 180 * Showcase.day],
                "excluded": [["product": "洗剤の定期便セット", "reason": "auto_renewal"]],
                "candidates": candidates.map { c -> [String: Any] in
                    var row: [String: Any] = [:]
                    for key in ["id", "product", "quantity", "unit_price", "merchant", "maker", "ships", "given_by", "is_exploration", "valence", "collected_as", "name", "variant"] { if let v = c[key] { row[key] = v } }
                    let id = c["id"] as! String
                    row["alternatives"] = why[id]?.alternatives ?? ["今回は見送る"]; row["argument_against"] = why[id]?.against ?? "必要でなければ選ばなくて構いません。"
                    row["disclosure"] = ["merchant": c["merchant"]!, "product": NSNull()]
                    return row
                }]
    }
    private func statementJSON(_ id: String, challenge: Bool) -> [String: Any] {
        let offer = offers[id]!, candidates = offer["candidates"] as! [[String: Any]]
        let lines: [[String: Any]] = candidates.compactMap { c in
            let valence = c["valence"] as! String
            guard ["kept", "defaulted", "consumed"].contains(valence) || (valence == "lost" && c["collected_as"] as? String == "missing") else { return nil }
            let gift = !(c["given_by"] is NSNull)
            var row: [String: Any] = [:]
            for key in ["product", "merchant", "maker", "ships", "given_by", "valence", "quantity", "unit_price", "name", "variant"] { if let v = c[key] { row[key] = v } }
            row["candidate"] = c["id"]!; row["disclosure"] = ["merchant": c["merchant"]!, "product": NSNull()]
            row["amount"] = valence == "lost" || gift ? Int64(0) : Showcase.int(c["unit_price"]) * Showcase.int(c["quantity"])
            row["note"] = valence == "lost" ? "回収時に箱の中に見当たりませんでした。" : NSNull()
            return row
        }
        var value: [String: Any] = ["offer": id, "household": Showcase.household, "expires_at": offer["expires_at"]!, "lines": lines, "disclosures": offer["disclosures"]!, "carriage": 350]
        if challenge {
            let canonical = try! Canonical.statement(offer: id, carriage: 350, lines: lines.map { .init(candidate: $0["candidate"] as! String, valence: $0["valence"] as! String, amount: Showcase.int($0["amount"]), disputed: false) })
            value["challenge"] = Canonical.challenge(canonical)
        }
        return value
    }
    private func handle(_ id: String, profile: String, offer: String, presenter: String, canonical: String, digest: String, challenge: String, expires: Int64) throws -> MemberOperationHandle {
        let h: [String: Any] = ["id": id, "environment": environment.name, "origin": environment.origin.absoluteString, "sessionID": session.id, "household": Showcase.household,
                                "presenter": presenter, "offer": offer, "canonical": canonical, "expiresAt": expires, "requestDigest": digest, "reviewedRevision": digest,
                                "challenge": challenge, "credentialID": "c2hvd2Nhc2U", "attempted": false, "profile": profile]
        return try JSONDecoder().decode(MemberOperationHandle.self, from: Showcase.data(h))
    }
    private func publicKey(_ challenge: String) -> [String: Any] {
        ["challenge": challenge, "rpId": environment.origin.host!, "userVerification": "required", "allowCredentials": [["type": "public-key", "id": "c2hvd2Nhc2U"]]]
    }

    // MARK: statements
    func prepareStatement(_ local: PreparedMemberStatement, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedOperation) {
        let id = UUID().uuidString.lowercased(), profile = "atarasy.member-statement-authorisation.1", digest = Showcase.hex(local.canonical)
        let challenge = Showcase.challenge(environment: environment, profile: profile, operation: id, digest: digest), expires = Showcase.now + 15 * 60_000
        var statement = statementJSON(local.offer, challenge: false); statement.removeValue(forKey: "challenge")
        let value: [String: Any] = ["profile": profile, "operationID": id, "requestDigest": digest, "reviewedRevision": digest, "expiresAt": expires, "canonical": local.canonical,
                                    "review": ["statement": statement, "mandate": Showcase.mandateJSON, "disputed": local.disputed], "operationState": "prepared", "publicKey": publicKey(challenge), "authorisation": "prepared"]
        let h = try handle(id, profile: profile, offer: local.offer, presenter: local.presenter, canonical: local.canonical, digest: digest, challenge: challenge, expires: expires)
        try store.save(h); prepared[id] = value
        return (h, try JSONDecoder().decode(MemberPreparedOperation.self, from: Showcase.data(value)))
    }
    func operationReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedOperation {
        guard let value = prepared[handle.id] else { throw MemberFailure.unavailable }
        return try JSONDecoder().decode(MemberPreparedOperation.self, from: Showcase.data(value))
    }
    func submitStatement(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberOperationOutcome {
        try store.claim(handle, confirmation: "c2hvd2Nhc2U")
        let disputed = ((prepared[handle.id]?["review"] as? [String: Any])?["disputed"] as? [String]) ?? []
        let receipt = settle(handle.offer, disputed: disputed)
        outcomes[handle.id] = receipt
        if loseReply && !lostOnce { lostOnce = true; throw URLError(.networkConnectionLost) }
        return .committed(receipt)
    }
    func operationOutcome(_ handle: MemberOperationHandle) async -> MemberOperationOutcome {
        if let receipt = outcomes[handle.id] as? ProtocolSettlement { return .committed(receipt) }
        return .pending("prepared")
    }
    func cancelOperation(_ handle: MemberOperationHandle) async throws { prepared.removeValue(forKey: handle.id) }
    func settlement(offerID: String) async throws -> ProtocolSettlement {
        guard let s = settlements[offerID] else { throw MemberFailure.unavailable }
        return try ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: Showcase.data(s), expectedOffer: offerID)
    }
    private func settle(_ offerID: String, disputed: [String]) -> ProtocolSettlement {
        let statement = statementJSON(offerID, challenge: false), rows = statement["lines"] as! [[String: Any]]
        var consumed: Int64 = 0, kept: Int64 = 0, contested: Int64 = 0
        let lines: [[String: Any]] = rows.map { r in
            let id = r["candidate"] as! String, valence = r["valence"] as! String, amount = Showcase.int(r["amount"]), isDisputed = disputed.contains(id)
            if valence == "consumed" { if isDisputed { contested += amount } else { consumed += amount } } else if valence != "lost" { kept += amount }
            var line: [String: Any] = ["candidate": id, "product": r["product"]!, "merchant": r["merchant"]!, "maker": r["maker"]!, "ships": r["ships"]!, "valence": valence, "amount": amount, "disputed": isDisputed]
            if let n = r["name"] { line["name"] = n }; if let v = r["variant"] { line["variant"] = v }
            return line
        }
        let s: [String: Any] = ["offer": offerID, "settled_at": Showcase.now, "kept_amount": kept, "consumed_amount": consumed, "lost_amount": 0, "charged": kept + consumed, "disputed_amount": contested,
                                "lines": lines, "payer": Showcase.household, "signed_by": offers[offerID]!["presenter"]!, "signed_as": "agent", "receipt": "showcase-receipt-" + offerID, "confirmation": "c2hvd2Nhc2U"]
        settlements[offerID] = s; offers[offerID]?["state"] = "settled"
        return try! ReferenceResponseReader.settlement(status: 200, contentType: "application/json", data: Showcase.data(s), expectedOffer: offerID)
    }

    // MARK: decisions
    func prepareDecision(_ local: PreparedMemberDecision, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedDecision) {
        let id = UUID().uuidString.lowercased(), digest = Showcase.hex(local.canonical)
        let challenge = Showcase.challenge(environment: environment, profile: memberDecisionProfile, operation: id, digest: digest), expires = Showcase.now + 15 * 60_000
        let rows: [[String: Any]] = local.decisions.map { $0.valence == "kept" ? ["candidate": $0.candidate, "valence": "kept", "kept_as": "self"] : ["candidate": $0.candidate, "valence": "returned"] }
        let value: [String: Any] = ["profile": memberDecisionProfile, "operationID": id, "requestDigest": digest, "reviewedRevision": digest, "expiresAt": expires, "canonical": local.canonical,
                                    "review": ["approval": approvalJSON(local.detail.id), "mandate": Showcase.mandateJSON, "decisions": rows, "goods": local.summary.goods, "carriage": local.summary.carriage, "total": local.summary.total],
                                    "operationState": "prepared", "publicKey": publicKey(challenge)]
        let h = try handle(id, profile: memberDecisionProfile, offer: local.detail.id, presenter: local.detail.presenter, canonical: local.canonical, digest: digest, challenge: challenge, expires: expires)
        try store.save(h); prepared[id] = value
        return (h, try JSONDecoder().decode(MemberPreparedDecision.self, from: Showcase.data(value)))
    }
    func decisionReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedDecision {
        guard let value = prepared[handle.id] else { throw MemberFailure.unavailable }
        return try JSONDecoder().decode(MemberPreparedDecision.self, from: Showcase.data(value))
    }
    func submitDecision(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberDecisionOutcome {
        try store.claim(handle, confirmation: "c2hvd2Nhc2U")
        let rows = ((prepared[handle.id]?["review"] as? [String: Any])?["decisions"] as? [[String: Any]]) ?? []
        if var offer = offers[handle.offer], var candidates = offer["candidates"] as? [[String: Any]] {
            for i in candidates.indices { if let row = rows.first(where: { $0["candidate"] as? String == candidates[i]["id"] as? String }) { candidates[i]["valence"] = row["valence"]!; candidates[i]["decided_at"] = Showcase.now; if row["valence"] as? String == "kept" { candidates[i]["kept_as"] = "self" } } }
            offer["candidates"] = candidates; offer["state"] = "decided"; offer["decided_at"] = Showcase.now; offers[handle.offer] = offer
        }
        outcomes[handle.id] = true
        if loseReply && !lostOnce { lostOnce = true; throw URLError(.networkConnectionLost) }
        return .recorded(try await offerDetail(id: handle.offer))
    }
    func decisionOutcome(_ handle: MemberOperationHandle) async -> MemberDecisionOutcome {
        guard outcomes[handle.id] != nil, let detail = try? await offerDetail(id: handle.offer) else { return .pending("prepared") }
        return .recorded(detail)
    }

    // MARK: undo (not modelled here; the screen shows why it cannot proceed)
    func prepareWithdrawal(_ original: MemberOperationHandle, store: any MemberOperationStore) async throws -> (MemberOperationHandle, MemberPreparedDecision, FrozenMemberWithdrawal) { throw MemberFailure.unavailable }
    func withdrawalReview(_ handle: MemberOperationHandle) async throws -> MemberPreparedDecision { throw MemberFailure.unavailable }
    func submitWithdrawal(_ handle: MemberOperationHandle, assertion: MemberPasskeyResponse, store: any MemberOperationStore) async throws -> MemberWithdrawalOutcome { throw MemberFailure.unavailable }
    func withdrawalOutcome(_ handle: MemberOperationHandle) async -> MemberWithdrawalOutcome { .unresolved }
}

@MainActor private final class ShowcasePasskeys: MemberPasskeyAuthorising {
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        .assertion(id: "c2hvd2Nhc2U", clientDataJSON: "c2hvd2Nhc2U", authenticatorData: "c2hvd2Nhc2U", signature: "c2hvd2Nhc2U", userHandle: "c2hvd2Nhc2U")
    }
}

struct MemberShowcaseRootView: View {
    @StateObject private var account: MemberAccount
    init() {
        let environment = try! MemberEnvironment(name: "showcase", origin: Showcase.origin)
        let service = ShowcaseService(environment: environment, loseReply: ProcessInfo.processInfo.arguments.contains("--showcase-lose-reply"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-operations")
        try? FileManager.default.removeItem(at: directory)
        let store = try! FileMemberOperationStore(directory: directory)
        let passkeys = ShowcasePasskeys()
        _account = StateObject(wrappedValue: MemberAccount(service: service, passkeys: passkeys,
            statements: MemberStatementFlow(environment: environment, service: service, passkeys: passkeys, store: store),
            decisions: MemberDigitalFlow(environment: environment, service: service, passkeys: passkeys, store: store),
            withdrawals: MemberWithdrawalFlow(environment: environment, service: service, passkeys: passkeys, store: store),
            operations: store))
    }
    var body: some View {
        MemberAppView(account: account)
            .task { if account.session == nil && !ProcessInfo.processInfo.arguments.contains("--showcase-signed-out") { await account.restore(household: Showcase.household) } }
    }
}
#endif
