import CryptoKit
import Foundation
import XCTest
@testable import AtarasyCore

private final class HostMoveVault: MemberSessionVault, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: StoredMemberSession] = [:]
    private func key(_ environment: MemberEnvironment, _ household: String) -> String { environment.origin.absoluteString + "|" + household }
    func load(environment: MemberEnvironment, household: String) throws -> StoredMemberSession? { lock.withLock { values[key(environment, household)] } }
    func save(_ session: StoredMemberSession, environment: MemberEnvironment) throws { lock.withLock { values[key(environment, session.info.household)] = session } }
    func remove(environment: MemberEnvironment, household: String) throws { _ = lock.withLock { values.removeValue(forKey: key(environment, household)) } }
}
private actor HostMoveTransport: MemberHTTPTransport {
    struct Reply: Sendable { let status: Int; let data: Data }
    var replies: [Reply]; var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> MemberHTTPReply {
        requests.append(request); guard !replies.isEmpty else { throw MemberFailure.unavailable }; let reply = replies.removeFirst()
        return .init(url: request.url!, status: reply.status, contentType: "application/json", cacheControl: "no-store", data: reply.data)
    }
    func requestCount() -> Int { requests.count }
}

@MainActor final class HostMoveTests: XCTestCase {
    private let household = "key:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    private let token = "amr1_" + String(repeating: "A", count: 43)
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func b64(_ data: Data) -> String { PasskeyBytes.encode(data) }
    private func ceremony(_ origin: String, receipt: [String: Any]? = nil) -> [String: Any] {
        var result: [String: Any] = ["profile": receipt == nil ? "atarasy.member-host-retirement-review.1" : "atarasy.member-host-import-attestation-review.1", "id": "22222222-2222-4222-8222-222222222222", "expiresAt": 2000, "publicKey": ["challenge": b64(Data(repeating: 3, count: 32)), "rpId": URL(string: origin)!.host!, "timeout": 1000, "userVerification": "required", "allowCredentials": [["type": "public-key", "id": "YQ"]]]]
        if let receipt { result["receipt"] = receipt } else { result["move"] = ["id": "11111111-1111-4111-8111-111111111111", "household": household, "targetOrigin": "https://target.example"]; result["attestation"] = NSNull(); result["receiptDigest"] = String(repeating: "D", count: 43) }
        return result
    }
    func testCapturedHostMoveWireRequiresTargetAttestationBeforeSourceRetirement() async throws {
        let sourceEnvironment = try MemberEnvironment(name: "test", origin: URL(string: "https://source.example")!), targetEnvironment = try MemberEnvironment(name: "test", origin: URL(string: "https://target.example")!), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000)
        let record: [String: Any] = ["id": "33333333-3333-4333-8333-333333333333", "revision": 1, "updatedAt": 1000, "envelope": ["profile": "atarasy.private-node-record.1", "nonce": b64(Data(repeating: 1, count: 12)), "ciphertext": b64(Data(repeating: 2, count: 32))]]
        let archive: [String: Any] = ["profile": "atarasy.member-host-archive.1", "move": "11111111-1111-4111-8111-111111111111", "household": household, "sourceOrigin": sourceEnvironment.origin.absoluteString, "targetOrigin": targetEnvironment.origin.absoluteString, "exportedAt": 1000, "node": [:], "privateRecords": [record], "recovery": [:]]
        let archiveBytes = try data(archive), encoded = b64(archiveBytes), digest = b64(Data(SHA256.hash(data: archiveBytes)))
        let moved = try JSONDecoder().decode([MemberPrivateNodeRecord].self, from: try data([record])); XCTAssertEqual(moved.count, 1)
        let exportReply: [String: Any] = ["profile": "atarasy.member-host-export.1", "id": archive["move"]!, "household": household, "sourceOrigin": sourceEnvironment.origin.absoluteString, "targetOrigin": targetEnvironment.origin.absoluteString, "digest": digest, "archive": encoded, "createdAt": 1000]
        let receipt: [String: Any] = ["profile": "atarasy.member-host-import-receipt.1", "move": archive["move"]!, "household": household, "sourceOrigin": sourceEnvironment.origin.absoluteString, "targetOrigin": targetEnvironment.origin.absoluteString, "archiveDigest": digest, "nodeDigest": String(repeating: "a", count: 64), "privateRecords": 1, "importedAt": 1001]
        let assertion = MemberPasskeyResponse.assertion(id: "YQ", clientDataJSON: "Yg", authenticatorData: "Yw", signature: "ZA", userHandle: "ZQ"), assertionObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assertion))
        let attestation: [String: Any] = ["profile": "atarasy.member-host-import-attestation.1", "receipt": receipt, "proof": ["credential": "YQ", "assertion": assertionObject]]
        var retirementReview = ceremony(sourceEnvironment.origin.absoluteString); retirementReview["attestation"] = attestation
        let retirement: [String: Any] = ["profile": "atarasy.member-host-retirement.1", "move": archive["move"]!, "household": household, "targetOrigin": targetEnvironment.origin.absoluteString, "archiveDigest": digest, "receiptDigest": String(repeating: "D", count: 43), "retiredAt": 1002]
        let sourceTransport = HostMoveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 201, data: try data(exportReply)), .init(status: 200, data: try data(retirementReview)), .init(status: 200, data: try data(retirement))])
        let targetTransport = HostMoveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 201, data: try data(receipt)), .init(status: 200, data: try data(ceremony(targetEnvironment.origin.absoluteString, receipt: receipt))), .init(status: 200, data: try data(attestation))])
        let vault = HostMoveVault(); try vault.save(.init(token: token, info: session), environment: sourceEnvironment); try vault.save(.init(token: token, info: session), environment: targetEnvironment)
        let source = MemberClient(environment: sourceEnvironment, transport: sourceTransport, vault: vault, now: { 1000 }), target = MemberClient(environment: targetEnvironment, transport: targetTransport, vault: vault, now: { 1000 }); _ = try await source.restore(household: household); _ = try await target.restore(household: household)
        let exported = try await source.exportHostMove(to: targetEnvironment); XCTAssertEqual(exported.privateRecords.count, 1)
        let imported = try await target.importHostMove(exported, privateRecords: moved); XCTAssertEqual(imported.archiveDigest, digest)
        let proofReview = try await target.prepareHostImportAttestation(digest: digest), proof = try await target.attestHostImport(proofReview, assertion: assertion)
        let prepared = try await source.prepareHostRetirement(move: exported.id, attestation: proof), retired = try await source.retireHost(prepared, assertion: assertion); XCTAssertEqual(retired.targetOrigin, targetEnvironment.origin.absoluteString)
        let sourceRequests = await sourceTransport.requests, targetRequests = await targetTransport.requests
        XCTAssertEqual(sourceRequests.map { $0.url!.path }, ["/auth/session", "/member/host-move/export", "/member/host-move/11111111-1111-4111-8111-111111111111/retirement/prepare", "/member/host-move/11111111-1111-4111-8111-111111111111/retirement/retire"])
        XCTAssertEqual(targetRequests.map { $0.url!.path }, ["/auth/session", "/member/host-move/import", "/member/host-move/imports/\(digest)/prepare", "/member/host-move/imports/\(digest)/attest"])
    }
    func testCorruptArchiveDigestNeverReachesTargetImport() async throws {
        let environment = try MemberEnvironment(name: "test", origin: URL(string: "https://source.example")!), target = try MemberEnvironment(name: "test", origin: URL(string: "https://target.example")!), session = MemberSessionInfo(id: "session", household: household, presenters: [], expiresAt: 5000), vault = HostMoveVault(); try vault.save(.init(token: token, info: session), environment: environment)
        let malformed: [String: Any] = ["profile": "atarasy.member-host-export.1", "id": "11111111-1111-4111-8111-111111111111", "household": household, "sourceOrigin": environment.origin.absoluteString, "targetOrigin": target.origin.absoluteString, "digest": String(repeating: "A", count: 43), "archive": b64(Data("{}".utf8)), "createdAt": 1000]
        let transport = HostMoveTransport([.init(status: 200, data: try JSONEncoder().encode(session)), .init(status: 201, data: try data(malformed))]), client = MemberClient(environment: environment, transport: transport, vault: vault, now: { 1000 }); _ = try await client.restore(household: household)
        do { _ = try await client.exportHostMove(to: target); XCTFail("Expected corrupt archive refusal") } catch {}
        let count = await transport.requestCount(); XCTAssertEqual(count, 2)
    }
}
