import Foundation

public enum MemberAPNSEnvironment: String, Codable, Sendable { case sandbox, production }
public struct MemberRefreshSubscription: Codable, Equatable, Sendable {
    public let profile: String; public let active: Bool; public let apnsEnvironment: MemberAPNSEnvironment?; public let updatedAt: Int64?
}

public enum MemberRefreshHint {
    public static func validate(_ data: Data) -> Bool {
        guard data.count <= 1024, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(root.keys) == ["aps", "atarasy"],
              let aps = root["aps"] as? [String: Any], Set(aps.keys) == ["content-available"], let available = aps["content-available"] as? NSNumber,
              CFGetTypeID(available) != CFBooleanGetTypeID(), available.intValue == 1,
              let custom = root["atarasy"] as? [String: Any], Set(custom.keys) == ["profile"], custom["profile"] as? String == "atarasy.member-refresh-hint.1" else { return false }
        return true
    }
}

public extension MemberClient {
    func refreshSubscription() async throws -> MemberRefreshSubscription {
        let (reply, _) = try await read("/member/refresh")
        return try validatedRefreshSubscription(reply)
    }
    func registerRefresh(token: Data, apnsEnvironment: MemberAPNSEnvironment) async throws -> MemberRefreshSubscription {
        guard token.count >= 32, token.count <= 100 else { throw MemberFailure.invalidInput }
        struct Input: Encodable { let token: String; let apnsEnvironment: MemberAPNSEnvironment }
        let text = token.map { String(format: "%02x", $0) }.joined()
        let (reply, _) = try await read("/member/refresh/subscription", body: JSONEncoder().encode(Input(token: text, apnsEnvironment: apnsEnvironment)))
        let value = try validatedRefreshSubscription(reply); guard value.active, value.apnsEnvironment == apnsEnvironment else { throw MemberFailure.scopeMismatch }; return value
    }
    func disableRefresh() async throws -> MemberRefreshSubscription {
        let (reply, _) = try await read("/member/refresh/disable", body: Data("{}".utf8))
        let value = try validatedRefreshSubscription(reply); guard !value.active else { throw MemberFailure.scopeMismatch }; return value
    }
    private func validatedRefreshSubscription(_ reply: MemberHTTPReply) throws -> MemberRefreshSubscription {
        let value = try decode(MemberRefreshSubscription.self, reply, keys: ["profile", "active", "apnsEnvironment", "updatedAt"])
        guard value.profile == "atarasy.member-refresh-subscription.1", value.updatedAt.map({ $0 >= 0 }) ?? !value.active,
              value.active ? value.apnsEnvironment != nil && value.updatedAt != nil : true else { throw MemberFailure.malformed }
        return value
    }
}
