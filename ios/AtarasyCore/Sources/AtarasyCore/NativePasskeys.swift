import Foundation
import AuthenticationServices

public enum NativePasskeyFailure: Error, Equatable, Sendable {
    case cancelled, unavailable, invalidOptions, invalidCredential
}
public enum PasskeyBytes {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ value: String, maximum: Int = 1024) throws -> Data {
        guard maximum > 0, maximum <= 1_048_576, !value.isEmpty, value.utf8.count <= maximum * 2,
              value.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else { throw NativePasskeyFailure.invalidOptions }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.count <= maximum, encode(bytes) == value else { throw NativePasskeyFailure.invalidOptions }
        return bytes
    }
}

// Only the pinned service's platform-passkey subset is accepted. No browser defaults become policy.
public struct NativePasskeyOptions: Sendable {
    public enum Kind: Sendable { case registration, assertion, statement, decision, withdrawal, recovery, hostMove }
    public let kind: Kind
    public let relyingParty: String
    public let challenge: Data
    public let allowedCredentialIDs: [Data]
    public let userID: Data?
    public let userName: String?
    public init(ceremony: MemberCeremony, environment: MemberEnvironment, kind: Kind, now: Int64) throws {
        guard ceremony.expiresAt > now, ceremony.expiresAt <= 9_007_199_254_740_991 else { throw MemberFailure.expired }
        let p = ceremony.publicKey
        guard UUID(uuidString: ceremony.id) != nil, case .string(let raw) = p["challenge"] else { throw NativePasskeyFailure.invalidOptions }
        if kind != .statement && kind != .decision && kind != .withdrawal { guard case .integer(let timeout) = p["timeout"], timeout > 0 else { throw NativePasskeyFailure.invalidOptions } }
        challenge = try PasskeyBytes.decode(raw, maximum: 32)
        guard challenge.count == 32, let host = environment.origin.host else { throw NativePasskeyFailure.invalidOptions }
        relyingParty = host; self.kind = kind
        switch kind {
        case .registration:
            guard case .object(let rp) = p["rp"], rp["id"] == .string(host),
                  p["attestation"] == .string("none"), p["excludeCredentials"] == .array([]),
                  p["pubKeyCredParams"] == .array([.object(["type": .string("public-key"), "alg": .integer(-7)])]),
                  case .object(let selection) = p["authenticatorSelection"], selection["residentKey"] == .string("required"), selection["userVerification"] == .string("required"),
                  case .object(let user) = p["user"], case .string(let handle) = user["id"], case .string(let name) = user["name"], !name.isEmpty else { throw NativePasskeyFailure.invalidOptions }
            allowedCredentialIDs = []; userID = try PasskeyBytes.decode(handle, maximum: 64); userName = name
        case .assertion:
            guard p["rpId"] == .string(host), p["userVerification"] == .string("required"), p["allowCredentials"] == .array([]) else { throw NativePasskeyFailure.invalidOptions }
            allowedCredentialIDs = []; userID = nil; userName = nil
        case .statement, .decision, .withdrawal, .recovery, .hostMove:
            guard p["rpId"] == .string(host), p["userVerification"] == .string("required"),
                  case .array(let allowed) = p["allowCredentials"], allowed.count == 1,
                  case .object(let credential) = allowed[0], Set(credential.keys) == ["type", "id"],
                  credential["type"] == .string("public-key"), case .string(let id) = credential["id"] else { throw NativePasskeyFailure.invalidOptions }
            allowedCredentialIDs = [try PasskeyBytes.decode(id, maximum: 1024)]
            userID = nil; userName = nil
        }
    }
    @MainActor public func request() -> ASAuthorizationRequest {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        switch kind {
        case .registration:
            let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName!, userID: userID!)
            request.userVerificationPreference = .required
            request.attestationPreference = .none
            return request
        case .assertion, .statement, .decision, .withdrawal, .recovery, .hostMove:
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            request.userVerificationPreference = .required
            request.allowedCredentials = allowedCredentialIDs.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            return request
        }
    }
}

@MainActor public protocol MemberPasskeyAuthorising: AnyObject {
    func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse
}

@MainActor public final class NativePasskeyAuthoriser: NSObject, MemberPasskeyAuthorising, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let environment: MemberEnvironment
    private let anchor: () -> ASPresentationAnchor?
    private let now: () -> Int64
    private var continuation: CheckedContinuation<MemberPasskeyResponse, Error>?
    private var controller: ASAuthorizationController?
    private var window: ASPresentationAnchor?
    private var kind: NativePasskeyOptions.Kind?
    private var operation: UUID?
    public init(environment: MemberEnvironment, anchor: @escaping () -> ASPresentationAnchor?, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.environment = environment; self.anchor = anchor; self.now = now
    }
    public func authorise(_ ceremony: MemberCeremony, kind: NativePasskeyOptions.Kind) async throws -> MemberPasskeyResponse {
        guard continuation == nil else { throw MemberFailure.busy }
        try Task.checkCancellation()
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: kind, now: now())
        guard let window = anchor() else { throw NativePasskeyFailure.unavailable }
        let operation = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let controller = ASAuthorizationController(authorizationRequests: [options.request()])
                self.operation = operation; self.continuation = continuation; self.controller = controller; self.window = window; self.kind = kind
                controller.delegate = self; controller.presentationContextProvider = self
                if Task.isCancelled { finish(.failure(NativePasskeyFailure.cancelled)) }
                else { controller.performRequests() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.operation == operation else { return }
                self.controller?.cancel()
                self.finish(.failure(NativePasskeyFailure.cancelled))
            }
        }
    }
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window! }
    private func finish(_ result: Result<MemberPasskeyResponse, Error>) {
        let pending = continuation
        continuation = nil; controller = nil; kind = nil; operation = nil
        pending?.resume(with: result)
    }
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }
        switch (kind, authorization.credential) {
        case (.registration, let credential as ASAuthorizationPlatformPublicKeyCredentialRegistration):
            guard let attestation = credential.rawAttestationObject, !attestation.isEmpty, !credential.credentialID.isEmpty, !credential.rawClientDataJSON.isEmpty else { finish(.failure(NativePasskeyFailure.invalidCredential)); return }
            finish(.success(.registration(id: PasskeyBytes.encode(credential.credentialID), clientDataJSON: PasskeyBytes.encode(credential.rawClientDataJSON), attestationObject: PasskeyBytes.encode(attestation))))
        case (.assertion, let credential as ASAuthorizationPlatformPublicKeyCredentialAssertion), (.statement, let credential as ASAuthorizationPlatformPublicKeyCredentialAssertion), (.decision, let credential as ASAuthorizationPlatformPublicKeyCredentialAssertion), (.withdrawal, let credential as ASAuthorizationPlatformPublicKeyCredentialAssertion):
            guard !credential.credentialID.isEmpty, !credential.rawClientDataJSON.isEmpty, !credential.rawAuthenticatorData.isEmpty, !credential.signature.isEmpty, !credential.userID.isEmpty else { finish(.failure(NativePasskeyFailure.invalidCredential)); return }
            finish(.success(.assertion(id: PasskeyBytes.encode(credential.credentialID), clientDataJSON: PasskeyBytes.encode(credential.rawClientDataJSON), authenticatorData: PasskeyBytes.encode(credential.rawAuthenticatorData), signature: PasskeyBytes.encode(credential.signature), userHandle: PasskeyBytes.encode(credential.userID))))
        default: finish(.failure(NativePasskeyFailure.invalidCredential))
        }
    }
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        finish(.failure((error as? ASAuthorizationError)?.code == .canceled ? NativePasskeyFailure.cancelled : NativePasskeyFailure.unavailable))
    }
}
