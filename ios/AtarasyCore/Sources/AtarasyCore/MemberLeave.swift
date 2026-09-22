import Foundation

/// §14.3. Apple Guideline 5.1.1(v): an app that creates accounts must let a member delete
/// one in the app. `kind` is kept as the raw string the server sent: a blocker kind this
/// build does not recognise must still be shown, never silently dropped.
public struct MemberLeaveBlocker: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String
}
public struct MemberLeaveStatus: Codable, Equatable, Sendable {
    public let profile: String
    public let household: String
    public let blockers: [MemberLeaveBlocker]
}
public struct PreparedMemberLeave: Sendable {
    public let ceremony: MemberCeremony
    public let id: String
    public let household: String
    public let origin: String
    public let rpID: String
    public let digest: String
}
public struct MemberLeft: Codable, Equatable, Sendable {
    public let profile: String
    public let household: String
    public let leftAt: Int64
    public let deleted: MemberJSON
}
/// `node` and `privateRecords` are kept as the exact bytes the host sent for those two
/// fields, so a saved export file reproduces them byte-for-byte rather than through a
/// decode/re-encode round trip that could reorder keys or reformat numbers.
public struct MemberExport: Sendable {
    public let profile: String
    public let household: String
    public let exportedAt: Int64
    public let node: Data
    public let privateRecords: Data
}
public extension MemberExport {
    /// Reassembles the full export document for saving to a file. The two byte-exact
    /// fields are spliced in verbatim; the three scalar fields round-trip losslessly.
    func fileContents() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        var out = Data("{\"profile\":".utf8)
        out.append(try encoder.encode(profile))
        out.append(Data(",\"household\":".utf8)); out.append(try encoder.encode(household))
        out.append(Data(",\"exportedAt\":".utf8)); out.append(Data(String(exportedAt).utf8))
        out.append(Data(",\"node\":".utf8)); out.append(node)
        out.append(Data(",\"privateRecords\":".utf8)); out.append(privateRecords)
        out.append(Data("}".utf8))
        return out
    }
}
/// Thrown by `prepareLeave()` on a `409 leave_blocked`. Carries the same blocker list the
/// status route reports, so a caller does not need a second read to show why the request
/// was refused.
public enum MemberLeaveError: Error, Equatable, Sendable {
    case blocked([MemberLeaveBlocker])
}

private enum LeaveWire {
    static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(value.keys) == keys else { throw MemberFailure.malformed }
        return value
    }
    static func whole(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        let result = number.int64Value
        return result >= 0 && number.doubleValue == Double(result) ? result : nil
    }
    /// Byte ranges, as `Data`, of each top-level key's value in a JSON object. A nested
    /// value's own keys are never inspected: `skipValue` consumes an object or array as an
    /// opaque balanced span, so a key of the same name buried inside `node` or
    /// `privateRecords` can never be mistaken for the top-level one.
    static func topLevelValues(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data), n = bytes.count
        var i = 0
        func atEnd() -> Bool { i >= n }
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        func skipSpace() { while !atEnd(), isSpace(bytes[i]) { i += 1 } }
        func expect(_ byte: UInt8) throws { guard !atEnd(), bytes[i] == byte else { throw MemberFailure.malformed }; i += 1 }
        // Consumes a JSON string starting at `i` (which must be `"`), including both quotes.
        func skipString() throws {
            try expect(0x22)
            while true {
                guard !atEnd() else { throw MemberFailure.malformed }
                let b = bytes[i]
                if b == 0x5C { i += 2; continue }
                i += 1
                if b == 0x22 { return }
            }
        }
        func parseKey() throws -> String {
            try expect(0x22)
            let start = i
            while true {
                guard !atEnd() else { throw MemberFailure.malformed }
                let b = bytes[i]
                if b == 0x5C { i += 2; continue }
                if b == 0x22 { let text = String(decoding: bytes[start..<i], as: UTF8.self); i += 1; return text }
                i += 1
            }
        }
        func skipValue() throws {
            skipSpace()
            guard !atEnd() else { throw MemberFailure.malformed }
            switch bytes[i] {
            case 0x22: try skipString()
            case 0x7B, 0x5B:
                let open = bytes[i], close: UInt8 = open == 0x7B ? 0x7D : 0x5D
                var depth = 0
                while !atEnd() {
                    let b = bytes[i]
                    if b == 0x22 { try skipString(); continue }
                    if b == open { depth += 1; i += 1; continue }
                    if b == close { depth -= 1; i += 1; if depth == 0 { return }; continue }
                    i += 1
                }
                throw MemberFailure.malformed
            default:
                let start = i
                while !atEnd(), !isSpace(bytes[i]), bytes[i] != 0x2C, bytes[i] != 0x7D, bytes[i] != 0x5D { i += 1 }
                guard i > start else { throw MemberFailure.malformed }
            }
        }
        skipSpace(); try expect(0x7B)
        var result: [String: Data] = [:]
        skipSpace()
        if !atEnd(), bytes[i] == 0x7D { i += 1 } else {
            while true {
                skipSpace()
                let key = try parseKey()
                skipSpace(); try expect(0x3A); skipSpace()
                let start = i
                try skipValue()
                guard result[key] == nil else { throw MemberFailure.malformed }
                result[key] = Data(bytes[start..<i])
                skipSpace()
                guard !atEnd() else { throw MemberFailure.malformed }
                if bytes[i] == 0x2C { i += 1; continue }
                try expect(0x7D); break
            }
        }
        skipSpace()
        guard atEnd() else { throw MemberFailure.malformed }
        return result
    }
}

public extension MemberClient {
    func leaveStatus() async throws -> MemberLeaveStatus {
        let (reply, info) = try await read("/member/account/leave")
        let value = try decode(MemberLeaveStatus.self, reply, keys: ["profile", "household", "blockers"])
        guard value.profile == "atarasy.member-leave-status.1", value.household == info.household,
              value.blockers.allSatisfy({ !$0.kind.isEmpty && !$0.id.isEmpty }) else { throw MemberFailure.scopeMismatch }
        return value
    }
    func prepareLeave() async throws -> PreparedMemberLeave {
        let (reply, info) = try await read("/member/account/leave/prepare", body: Data("{}".utf8))
        if reply.status == 409 {
            struct Blocked: Decodable { let error: String; let blockers: [MemberLeaveBlocker] }
            let value = try decode(Blocked.self, reply, status: 409, keys: ["error", "blockers"])
            guard value.error == "leave_blocked", value.blockers.allSatisfy({ !$0.kind.isEmpty && !$0.id.isEmpty }) else { throw MemberFailure.malformed }
            throw MemberLeaveError.blocked(value.blockers)
        }
        guard reply.status == 200 else { throw MemberFailure.http(reply.status) }
        let object = try LeaveWire.object(reply.data, keys: ["profile", "id", "household", "origin", "rpID", "expiresAt", "digest", "publicKey"])
        guard object["profile"] as? String == "atarasy.member-leave.1", object["household"] as? String == info.household,
              let id = object["id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let origin = object["origin"] as? String, origin == environment.origin.absoluteString,
              let rpID = object["rpID"] as? String, rpID == environment.origin.host!,
              let digest = object["digest"] as? String, digest.range(of: "^[A-Za-z0-9_-]{43}\\z", options: .regularExpression) != nil,
              LeaveWire.whole(object["expiresAt"]) != nil else { throw MemberFailure.malformed }
        let ceremonyData = try JSONSerialization.data(withJSONObject: ["id": id, "expiresAt": object["expiresAt"] as Any, "publicKey": object["publicKey"] as Any])
        guard let ceremony = try? JSONDecoder().decode(MemberCeremony.self, from: ceremonyData) else { throw MemberFailure.malformed }
        guard ceremony.publicKey["challenge"] == .string(digest) else { throw MemberFailure.scopeMismatch }
        let options = try NativePasskeyOptions(ceremony: ceremony, environment: environment, kind: .leave, now: now())
        guard options.allowedCredentialIDs.count == 1 else { throw MemberFailure.scopeMismatch }
        return .init(ceremony: ceremony, id: id, household: info.household, origin: origin, rpID: rpID, digest: digest)
    }
    func leave(_ prepared: PreparedMemberLeave, assertion: MemberPasskeyResponse) async throws -> MemberLeft {
        // `authorise(_:kind:)` already refused an expired ceremony before returning `assertion`,
        // matching how `retireHost` submits without a second expiry check.
        struct Input: Encodable { let preparation: String; let assertion: MemberPasskeyResponse }
        let (reply, info) = try await read("/member/account/leave/submit", body: JSONEncoder().encode(Input(preparation: prepared.id, assertion: assertion)))
        let value = try decode(MemberLeft.self, reply, keys: ["profile", "household", "leftAt", "deleted"])
        guard value.profile == "atarasy.member-left.1", value.household == prepared.household, value.household == info.household, value.leftAt >= 0, value.leftAt <= Canonical.maximumInteger else { throw MemberFailure.scopeMismatch }
        try removeRetiredLocalSession(info)
        return value
    }
    func exportAccount() async throws -> MemberExport {
        let (reply, info) = try await read("/member/account/export")
        guard reply.status == 200 else { throw MemberFailure.http(reply.status) }
        guard reply.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw MemberFailure.malformed }
        let object = try LeaveWire.object(reply.data, keys: ["profile", "household", "exportedAt", "node", "privateRecords"])
        guard object["profile"] as? String == "atarasy.member-export.1", object["household"] as? String == info.household,
              let exportedAt = LeaveWire.whole(object["exportedAt"]), exportedAt <= Canonical.maximumInteger else { throw MemberFailure.malformed }
        let raw = try LeaveWire.topLevelValues(reply.data)
        guard let node = raw["node"], let privateRecords = raw["privateRecords"] else { throw MemberFailure.malformed }
        // Defence in depth: the hand-rolled scanner above must have sliced valid JSON: if it
        // did not, the export would silently carry a corrupt fragment as "byte exact".
        guard (try? JSONSerialization.jsonObject(with: node, options: [.fragmentsAllowed])) != nil,
              (try? JSONSerialization.jsonObject(with: privateRecords, options: [.fragmentsAllowed])) != nil else { throw MemberFailure.malformed }
        return .init(profile: "atarasy.member-export.1", household: info.household, exportedAt: exportedAt, node: node, privateRecords: privateRecords)
    }
}
