import Foundation

public enum MemberFailure: Error, Equatable, Sendable {
    case invalidInput, malformed, scopeMismatch, expired, superseded, busy, storage
    case unavailable, uncertainVerification, remoteLogoutUnconfirmed
    case http(Int)
}
public struct MemberEnvironment: Sendable, Equatable {
    public let name: String
    public let origin: URL
    public init(name: String, origin: URL) throws {
        guard name.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil,
              var c = URLComponents(url: origin, resolvingAgainstBaseURL: false), c.scheme == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, ["", "/"].contains(c.path) else { throw MemberFailure.invalidInput }
        c.path = ""; if c.port == 443 { c.port = nil }
        guard let canonical = c.url else { throw MemberFailure.invalidInput }
        self.name = name; self.origin = canonical
    }
}
public struct MemberHTTPReply: Sendable {
    public let url: URL; public let status: Int; public let contentType: String?; public let cacheControl: String?; public let data: Data
    public init(url: URL, status: Int, contentType: String?, cacheControl: String?, data: Data) {
        self.url = url; self.status = status; self.contentType = contentType; self.cacheControl = cacheControl; self.data = data
    }
}
public protocol MemberHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> MemberHTTPReply }
final class DenyMemberRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let observer: (@Sendable () -> Void)?
    init(observer: (@Sendable () -> Void)? = nil) { self.observer = observer }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { observer?(); completionHandler(nil) }
}
public final class URLSessionMemberTransport: MemberHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let limit: Int
    public convenience init(timeout: TimeInterval, maximumResponseBytes: Int) throws {
        try self.init(timeout: timeout, maximumResponseBytes: maximumResponseBytes, protocolClasses: nil)
    }
    // Internal protocol injection is only for controlled URLSession tests.
    init(timeout: TimeInterval, maximumResponseBytes: Int, protocolClasses: [AnyClass]?, redirectObserver: (@Sendable () -> Void)? = nil) throws {
        guard timeout.isFinite, timeout > 0, maximumResponseBytes > 0 else { throw MemberFailure.invalidInput }
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCache = nil; c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout; c.protocolClasses = protocolClasses
        session = URLSession(configuration: c, delegate: DenyMemberRedirects(observer: redirectObserver), delegateQueue: nil); limit = maximumResponseBytes
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        guard request.url?.scheme == "https" else { throw MemberFailure.invalidInput }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let url = http.url, url == request.url else { throw MemberFailure.scopeMismatch }
        if http.expectedContentLength > Int64(limit) { throw MemberFailure.malformed }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw MemberFailure.malformed }
            data.append(byte)
        }
        return MemberHTTPReply(url: url, status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), cacheControl: http.value(forHTTPHeaderField: "Cache-Control"), data: data)
    }
}

public enum MemberJSON: Codable, Equatable, Sendable {
    // `fraction` exists because an engine offer carries `predicted_conversion`, a
    // number in [0, 1]. Without it the raw offer inside a digital decision's outcome
    // could not be decoded, so every Vox-presented decision read back as unresolved
    // after it had been recorded (found on a device, 2026-09-23).
    case string(String), integer(Int64), fraction(Double), bool(Bool), array([MemberJSON]), object([String: MemberJSON]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .fraction(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([MemberJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: MemberJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .fraction(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
public struct MemberCeremony: Decodable, Sendable {
    public let id: String; public let expiresAt: Int64; public let publicKey: [String: MemberJSON]
    public init(id: String, expiresAt: Int64, publicKey: [String: MemberJSON]) { self.id = id; self.expiresAt = expiresAt; self.publicKey = publicKey }
}
public struct MemberPasskeyResponse: Encodable, Sendable {
    public let id: String; public let rawId: String
    public let type = "public-key"
    public let clientExtensionResults: [String: MemberJSON] = [:]
    public let response: [String: MemberJSON]
    public static func assertion(id: String, clientDataJSON: String, authenticatorData: String, signature: String, userHandle: String) -> Self {
        Self(id: id, rawId: id, response: ["clientDataJSON": .string(clientDataJSON), "authenticatorData": .string(authenticatorData), "signature": .string(signature), "userHandle": .string(userHandle)])
    }
    public static func registration(id: String, clientDataJSON: String, attestationObject: String) -> Self {
        Self(id: id, rawId: id, response: ["clientDataJSON": .string(clientDataJSON), "attestationObject": .string(attestationObject)])
    }
}
public struct MemberSessionInfo: Codable, Equatable, Sendable {
    public let id: String; public let household: String; public let presenters: [String]; public let expiresAt: Int64
    public init(id: String, household: String, presenters: [String], expiresAt: Int64) { self.id = id; self.household = household; self.presenters = presenters; self.expiresAt = expiresAt }
}
public struct MemberOfferSummary: Decodable, Equatable, Sendable {
    /// What a list row can say without a second request per offer (`04b` §1b). Every field
    /// here is optional so a list from an engine that sends less still draws its rows; the
    /// authoritative checks are the detail's, made when the row is opened.
    public struct Line: Decodable, Equatable, Sendable {
        public let product: String
        public let merchant: String
        public let quantity: Int64?
        public let unitPrice: Int64?
        public let givenBy: String?
        public let valence: String?
        public let collectedAs: String?
        public let name: String?
        public let variant: String?
        public init(product: String, merchant: String, quantity: Int64? = nil, unitPrice: Int64? = nil, givenBy: String? = nil, valence: String? = nil, collectedAs: String? = nil, name: String? = nil, variant: String? = nil) {
            self.product = product; self.merchant = merchant; self.quantity = quantity; self.unitPrice = unitPrice
            self.givenBy = givenBy; self.valence = valence; self.collectedAs = collectedAs; self.name = name; self.variant = variant
        }
        enum CodingKeys: String, CodingKey {
            case product, merchant, quantity, valence, name, variant
            case unitPrice = "unit_price", givenBy = "given_by", collectedAs = "collected_as"
        }
    }
    public let id: String; public let household: String; public let presenter: String; public let binding: String; public let state: String
    public let presentedAt: Int64?
    public let expiresAt: Int64?
    public let decidedAt: Int64?
    public let candidates: [Line]?
    enum CodingKeys: String, CodingKey {
        case id, household, presenter, binding, state, candidates
        case presentedAt = "presented_at", expiresAt = "expires_at", decidedAt = "decided_at"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); household = try c.decode(String.self, forKey: .household)
        presenter = try c.decode(String.self, forKey: .presenter); binding = try c.decode(String.self, forKey: .binding)
        state = try c.decode(String.self, forKey: .state)
        presentedAt = try? c.decodeIfPresent(Int64.self, forKey: .presentedAt)
        expiresAt = try? c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        decidedAt = try? c.decodeIfPresent(Int64.self, forKey: .decidedAt)
        // A row whose lines cannot be read still lists; its detail is where a malformed offer is refused.
        candidates = try? c.decodeIfPresent([Line].self, forKey: .candidates)
    }
    public init(id: String, household: String, presenter: String, binding: String, state: String, presentedAt: Int64? = nil, expiresAt: Int64? = nil, decidedAt: Int64? = nil, candidates: [Line]? = nil) {
        self.id = id; self.household = household; self.presenter = presenter; self.binding = binding; self.state = state
        self.presentedAt = presentedAt; self.expiresAt = expiresAt; self.decidedAt = decidedAt; self.candidates = candidates
    }
    /// The date a row is ordered by: when it was presented, which is when it arrived, and its
    /// expiry for a row never presented, as the web hub's `byArrival` does.
    public var arrivedAt: Int64 { presentedAt ?? expiresAt ?? 0 }
}
