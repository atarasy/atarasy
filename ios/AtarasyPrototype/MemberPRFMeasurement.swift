import SwiftUI
import AuthenticationServices
import CryptoKit
import UIKit

/// Vault `81` option D, and K3 of `74`: does a passkey synced through iCloud Keychain return the
/// same PRF output on a second device? If it does, a household's ledger key can be derived from the
/// passkey and a second device or a reinstall stops losing the private records.
///
/// This screen measures that and nothing else. It never contacts the member service: the passkey
/// ceremonies run against the app's own relying party with a challenge made here, and what it shows is
/// a short fingerprint of the PRF output under a salt used for this measurement only, never the output.
/// It appears in TestFlight and development builds, never in an App Store build (`isAvailable`).
struct MemberPRFMeasurementView: View {
    let relyingParty: String
    @StateObject private var probe = MemberPRFProbe()
    var body: some View {
        List {
            Section {
                Text("For the team. This checks whether this passkey gives the same result on another device. Nothing is sent to Atarasy, and no account changes.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button("Create a test passkey") { probe.register(relyingParty: relyingParty) }.accessibilityIdentifier("prfRegister")
            } header: { Text("Step 1, on the first device only") } footer: {
                Text("Creates a passkey named Atarasy PRF test in your iCloud Keychain. Delete it in the Passwords app afterwards.")
            }
            Section {
                Button("Measure") { probe.measure(relyingParty: relyingParty) }.accessibilityIdentifier("prfMeasure")
            } header: { Text("Step 2, on each device") } footer: {
                Text("Choose Atarasy PRF test when asked. Then write down the two values below from each device.")
            }
            if !probe.rows.isEmpty {
                Section("Result") {
                    ForEach(probe.rows, id: \.0) { row in
                        LabeledContent(row.0) { Text(verbatim: row.1).font(.body.monospaced()).textSelection(.enabled) }
                    }
                }
            }
            if !probe.notice.isEmpty { Section { Text(verbatim: probe.notice).accessibilityIdentifier("prfNotice") } }
        }
        .navigationTitle("Passkey device check")
    }

    /// TestFlight installs carry a sandbox receipt; an App Store install does not. Development and
    /// UI-testing builds always show it.
    static var isAvailable: Bool {
        #if ATARASY_RELEASE
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #else
        return true
        #endif
    }
}

@MainActor final class MemberPRFProbe: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    @Published var rows: [(String, String)] = []
    @Published var notice = ""
    /// A salt used for this measurement only, so the fingerprint it produces is of no use to anything else.
    private static let salt = Data(SHA256.hash(data: Data("atarasy.prf-measurement.1".utf8)))
    private var controller: ASAuthorizationController?

    func register(relyingParty: String) {
        notice = ""; rows = []
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let request = provider.createCredentialRegistrationRequest(challenge: Self.random(), name: "Atarasy PRF test", userID: Self.random(16))
        guard #available(iOS 18.0, *) else { notice = String(localized: "This check needs iOS 18 or later."); return }
        request.prf = .checkForSupport
        run(request)
    }
    func measure(relyingParty: String) {
        notice = ""; rows = []
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: Self.random())
        guard #available(iOS 18.0, *) else { notice = String(localized: "This check needs iOS 18 or later."); return }
        request.prf = .inputValues(.saltInput1(Self.salt))
        run(request)
    }
    private func run(_ request: ASAuthorizationRequest) {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self; controller.presentationContextProvider = self
        self.controller = controller; controller.performRequests()
    }
    private static func random(_ count: Int = 32) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
    private static func short(_ data: Data) -> String { SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined() }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard #available(iOS 18.0, *) else { return }
            if let created = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
                rows = [("Passkey", Self.short(created.credentialID)), ("PRF supported", created.prf?.isSupported == true ? "yes" : "no")]
            } else if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                let output = assertion.prf?.first.withUnsafeBytes { Data($0) }
                rows = [("Passkey", Self.short(assertion.credentialID)), ("PRF fingerprint", output.map(Self.short) ?? "none returned")]
            }
            self.controller = nil
        }
    }
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let text = (error as? ASAuthorizationError)?.code == .canceled ? "Cancelled." : "Failed: " + String(describing: (error as NSError).code)
        MainActor.assumeIsolated { notice = text; self.controller = nil }
    }
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
