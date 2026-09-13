import Foundation
import Security
import LocalAuthentication
import CryptoKit

public struct StoredMemberSession: Codable, Sendable {
    public let token: String
    public let info: MemberSessionInfo
}
public protocol MemberSessionVault: Sendable {
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession?
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws
    func remove(environment: MemberEnvironment, household: String) throws
}
public final class KeychainMemberSessionVault: MemberSessionVault, Sendable {
    private let namespace: String
    public init(namespace: String) throws {
        guard !namespace.isEmpty else { throw MemberFailure.invalidInput }
        self.namespace = namespace
    }
    private func query(_ environment: MemberEnvironment, _ household: String) -> [String: Any] {
        let scope = try! JSONEncoder().encode([environment.name, environment.origin.absoluteString])
        let hash = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: namespace + ".member-session." + hash,
                kSecAttrAccount as String: Data(household.utf8).base64EncodedString(),
                kSecAttrSynchronizable as String: false]
    }
    public func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? {
        var q = query(environment, household); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(StoredMemberSession.self, from: data),
              Data(value.info.household.utf8) == Data(household.utf8) else { throw MemberFailure.storage }
        return value
    }
    public func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws {
        let q = query(environment, session.info.household)
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var create = q; create.merge(attributes) { _, new in new }
        let status = SecItemAdd(create as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(q as CFDictionary, attributes as CFDictionary) == errSecSuccess else { throw MemberFailure.storage }
        } else if status != errSecSuccess { throw MemberFailure.storage }
    }
    public func remove(environment: MemberEnvironment, household: String) throws {
        let status = SecItemDelete(query(environment, household) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MemberFailure.storage }
    }
}
