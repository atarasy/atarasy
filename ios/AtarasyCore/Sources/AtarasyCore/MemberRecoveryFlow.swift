import Foundation
import Combine
import CryptoKit

public protocol MemberRecoveryService: Sendable {
    func recoveryKeyStatus() async throws -> MemberRecoveryKeyStatus
    func prepareRecoveryKey(_ key: String) async throws -> PreparedMemberRecoveryKey
    func registerRecoveryKey(_ prepared: PreparedMemberRecoveryKey, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryKeyStatus
    func recoveryParticipant(_ household: String) async throws -> MemberRecoveryParticipantKey
    func recoveryConfiguration() async throws -> MemberRecoveryConfiguration
    func prepareRecoveryConfiguration(_ draft: MemberRecoveryConfigurationDraft, recovererKeyDigest: String) async throws -> PreparedMemberRecoveryConfiguration
    func submitRecoveryConfiguration(_ prepared: PreparedMemberRecoveryConfiguration, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryConfiguration
    func createRecoveryRequest(requesterPublicKey: String) async throws -> MemberRecoveryRequest
    func recoveryRequests() async throws -> [MemberRecoveryRequest]
    func recoveryRequest(id: String) async throws -> MemberRecoveryRequest
    func prepareRecoveryApproval(id: String, release: String) async throws -> PreparedMemberRecoveryApproval
    func approveRecovery(_ prepared: PreparedMemberRecoveryApproval, assertion: MemberPasskeyResponse) async throws -> MemberRecoveryRequest
    func recoveryLog() async throws -> MemberRecoveryLog
}
extension MemberClient: MemberRecoveryService {}

@MainActor public final class MemberRecoveryFlow: ObservableObject {
    @Published public private(set) var keyStatus: MemberRecoveryKeyStatus?
    @Published public private(set) var configuration: MemberRecoveryConfiguration?
    @Published public private(set) var requests: [MemberRecoveryRequest] = []
    @Published public private(set) var log: MemberRecoveryLog?
    @Published public private(set) var notice = ""
    @Published public private(set) var busy = false
    @Published public private(set) var currentHousehold: String?
    public var canConfigure: Bool { noticeChannel != nil }
    private let environment: MemberEnvironment
    private let service: any MemberRecoveryService
    private let privateNode: MemberPrivateNode
    private let passkeys: any MemberPasskeyAuthorising
    private let vault: any MemberRecoveryMaterialVault
    private let noticeChannel: String?
    private var session: MemberSessionInfo?
    private var generation: UInt64 = 0
    public init(environment: MemberEnvironment, service: any MemberRecoveryService, privateNode: MemberPrivateNode, passkeys: any MemberPasskeyAuthorising, vault: any MemberRecoveryMaterialVault, noticeChannel: String?) {
        self.environment = environment; self.service = service; self.privateNode = privateNode; self.passkeys = passkeys; self.vault = vault; self.noticeChannel = noticeChannel
    }
    public func setSession(_ session: MemberSessionInfo?) {
        generation &+= 1; self.session = session; currentHousehold = session?.household; keyStatus = nil; configuration = nil; requests = []; log = nil; notice = ""
    }
    private func scope(_ household: String) -> String {
        SHA256.hash(data: MemberRecoveryCodec.canonical(["atarasy.private-node-scope.1", environment.name, environment.origin.absoluteString, household])).map { String(format: "%02x", $0) }.joined()
    }
    private func run(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await work() } catch is CancellationError { notice = "Recovery action cancelled. Nothing was changed." }
        catch { notice = "Recovery is not complete. Existing records have not been replaced." }
    }
    public func refresh() async {
        guard session != nil else { return }
        await run {
            let started = generation, key = try await service.recoveryKeyStatus(), configuration = try await service.recoveryConfiguration(), requests = try await service.recoveryRequests(), log = try await service.recoveryLog()
            guard started == generation else { return }; self.keyStatus = key; self.configuration = configuration; self.requests = requests; self.log = log; notice = "Recovery status refreshed."
        }
    }
    public func registerRecoveryKey() async {
        guard let session else { return }
        await run {
            let started = generation, pair = try vault.agreementKey(scope: scope(session.household), create: true); guard let pair else { throw MemberFailure.storage }
            let prepared = try await service.prepareRecoveryKey(pair.publicKey), assertion = try await passkeys.authorise(prepared.ceremony, kind: .recovery)
            guard started == generation, self.session?.id == session.id else { return }
            keyStatus = try await service.registerRecoveryKey(prepared, assertion: assertion); notice = "This device can now act only in a named recovery ceremony."
        }
    }
    public func configure(recoverer: String) async {
        guard let session, let noticeChannel, !recoverer.isEmpty, recoverer != session.household else { notice = "An independent recovery notice channel and a different recoverer are required."; return }
        await run {
            let started = generation, current = try await service.recoveryConfiguration(), participant = try await service.recoveryParticipant(recoverer), key = try await privateNode.recoveryKey(session: session), shares = try MemberRecoveryShares.split(key: key), digest = try MemberRecoveryShares.digest(key), epoch = (current.epoch ?? 0) + 1
            guard let device = shares.first(where: { $0.participant == .device }), let recovererShare = shares.first(where: { $0.participant == .recoverer }), let host = shares.first(where: { $0.participant == .host }) else { throw MemberFailure.storage }
            let context = MemberRecoveryPacketContext(purpose: "recoverer-share", owner: session.household, recoverer: recoverer, reference: "configuration", epoch: epoch)
            let packet = try MemberRecoveryPackets.seal(recovererShare.bytes, recipientPublicKey: participant.publicKey, context: context)
            let draft = MemberRecoveryConfigurationDraft(epoch: epoch, recoverer: recoverer, keyDigest: digest, hostShare: MemberRecoveryCodec.b64(host.bytes), recovererPacket: packet, noticeChannel: noticeChannel)
            let prepared = try await service.prepareRecoveryConfiguration(draft, recovererKeyDigest: participant.keyDigest), assertion = try await passkeys.authorise(prepared.ceremony, kind: .recovery)
            guard started == generation, self.session?.id == session.id else { return }
            configuration = try await service.submitRecoveryConfiguration(prepared, assertion: assertion)
            try vault.saveDeviceShare(device, scope: scope(session.household), epoch: epoch); notice = "Recovery was configured with this device, the named recoverer and the host."
        }
    }
    public func beginLostDeviceRecovery() async {
        guard let session else { return }
        await run {
            let started = generation, pair = try vault.requesterKey(scope: scope(session.household), create: true); guard let pair else { throw MemberFailure.storage }
            let request = try await service.createRecoveryRequest(requesterPublicKey: pair.publicKey)
            guard started == generation else { return }; requests.removeAll { $0.id == request.id }; requests.append(request); requests.sort { $0.id < $1.id }; notice = "Waiting for the named recoverer and independent notice delivery."
        }
    }
    public func approve(_ request: MemberRecoveryRequest) async {
        guard let session, request.recoverer == session.household, let packet = request.recovererPacket else { return }
        await run {
            let started = generation, pair = try vault.agreementKey(scope: scope(session.household), create: false); guard let pair else { throw MemberFailure.storage }
            let inbound = MemberRecoveryPacketContext(purpose: "recoverer-share", owner: request.owner, recoverer: request.recoverer, reference: "configuration", epoch: request.epoch)
            let clear = try MemberRecoveryPackets.open(packet, recipient: pair, context: inbound), share = try MemberRecoveryShare(participant: .recoverer, bytes: clear)
            let outbound = MemberRecoveryPacketContext(purpose: "requester-release", owner: request.owner, recoverer: request.recoverer, reference: request.id, epoch: request.epoch)
            let release = try MemberRecoveryPackets.seal(share.bytes, recipientPublicKey: request.requesterPublicKey, context: outbound)
            let prepared = try await service.prepareRecoveryApproval(id: request.id, release: release), assertion = try await passkeys.authorise(prepared.ceremony, kind: .recovery)
            guard started == generation else { return }; let result = try await service.approveRecovery(prepared, assertion: assertion)
            requests.removeAll { $0.id == result.id }; requests.append(result); requests.sort { $0.id < $1.id }; notice = "Recovery approval recorded. It grants no everyday record access."
        }
    }
    public func finish(_ request: MemberRecoveryRequest) async {
        guard let session, request.owner == session.household else { return }
        await run {
            let latest = try await service.recoveryRequest(id: request.id)
            guard latest.state == "completed", let release = latest.release, let hostEncoded = latest.hostShare, let expected = latest.keyDigest,
                  let requester = try vault.requesterKey(scope: scope(session.household), create: false) else { throw MemberFailure.unavailable }
            let context = MemberRecoveryPacketContext(purpose: "requester-release", owner: latest.owner, recoverer: latest.recoverer, reference: latest.id, epoch: latest.epoch)
            let recovererBytes = try MemberRecoveryPackets.open(release, recipient: requester, context: context), recovererShare = try MemberRecoveryShare(participant: .recoverer, bytes: recovererBytes), hostShare = try MemberRecoveryShare(participant: .host, bytes: MemberRecoveryCodec.data(hostEncoded)), key = try MemberRecoveryShares.recover(recovererShare, hostShare)
            guard try MemberRecoveryShares.digest(key) == expected else { throw MemberFailure.storage }
            try await privateNode.installRecoveredKey(key, session: session); try vault.removeRequesterKey(scope: scope(session.household)); requests = try await service.recoveryRequests(); log = try await service.recoveryLog(); notice = "Recovery completed after the independent notice was delivered."
        }
    }
}
