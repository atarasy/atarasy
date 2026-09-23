import Foundation

/// What one inbox row says, decided from the list response alone (`04b` §1b). The same rules
/// as the web hub's `src/shared/inbox.ts`, which carries the reasoning for each; a row that
/// needs a second request to know its own state is a row that can be drawn wrong when the
/// request fails.
public enum MemberRowStatus: Equatable, Sendable {
    /// Goods in the home, nothing to sign yet. The date is when the box is swapped (§2.2b).
    case atHome(nextSwap: Int64?)
    /// The collection found goods used or missing and nothing has settled it (§6.5).
    /// `holdsNextBox` is whether this presenter's next box waits on the signature.
    case statementReady(holdsNextBox: Bool)
    /// A box that settled, or that closed owing nothing.
    case boxClosed(settled: Bool)
    /// Lines still this household's to answer. Nothing is bought if it closes (clause 32).
    case proposalOpen(closesAt: Int64?)
    /// This household has signed a set for it.
    case proposalDecided
    /// Closed with nothing chosen, withdrawn by the presenter, or settled.
    case proposalClosed
}

public extension MemberOfferSummary {
    private var lines: [Line] { candidates ?? [] }
    /// A line the collection recorded missing. An engine before `collected_as` cannot say, so
    /// such a line counts, as the web hub counts it.
    private func missing(_ line: Line) -> Bool { line.valence == "lost" && (line.collectedAs == "missing" || line.collectedAs == nil) }

    var awaitsStatement: Bool {
        binding == "physical" && (state == "decided" || state == "expired") &&
            lines.contains { $0.valence == "consumed" || missing($0) }
    }
    var holdsNextBox: Bool {
        lines.contains { $0.valence == "consumed" } ||
            (lines.contains(where: missing) && lines.contains { $0.valence == "kept" || $0.valence == "defaulted" })
    }
    var awaitsDecision: Bool { state == "presented" && lines.contains { $0.valence == "offered" } }

    var rowStatus: MemberRowStatus {
        if binding == "physical" {
            if state == "settled" { return .boxClosed(settled: true) }
            if awaitsStatement { return .statementReady(holdsNextBox: holdsNextBox) }
            if state == "presented" { return .atHome(nextSwap: expiresAt) }
            return .boxClosed(settled: false)
        }
        switch state {
        case "presented": return candidates == nil || awaitsDecision ? .proposalOpen(closesAt: expiresAt) : .proposalDecided
        case "decided": return .proposalDecided
        default: return .proposalClosed
        }
    }
    /// Whether the row asks something of the member now, which puts it in the "Waiting for you" strip.
    var needsMember: Bool {
        switch rowStatus {
        case .statementReady, .proposalOpen: return true
        default: return false
        }
    }
    /// The merchants of record on this offer, in the order their lines arrive, each once.
    var merchants: [String] {
        var seen = Set<Data>()
        return lines.map(\.merchant).filter { seen.insert(Data($0.utf8)).inserted }
    }
}
