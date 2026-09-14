import Foundation
public struct DemoFixtures: Codable, Sendable { public var synthetic: Bool; public var households: [String]; public var merchants: [String]; public var offers: [DemoOffer] }
public extension DemoFixtures {
    func visibleOffers(household: String, binding: String, unavailablePresenter: String? = nil) -> [DemoOffer] {
        offers.filter { $0.household == household && $0.binding == binding && $0.presenter != unavailablePresenter }.sorted { $0.arrived > $1.arrived }
    }
}
public struct DemoLine: Codable, Identifiable, Sendable {
    public var id: String; public var name: String; public var maker: String; public var price: Int64; public var givenBy: String?; public var verdict: String
    /// A line the collection recorded missing (`lost`) is never charged (question 46).
    public var amount: Int64 { givenBy == nil && verdict != "lost" ? price : 0 }
}
public struct DemoOffer: Codable, Identifiable, Sendable {
    public var id: String; public var household: String; public var presenter: String; public var title: String; public var binding: String; public var arrived: Int; public var carriage: Int64?; public var lines: [DemoLine]
    public func amount(kept: Set<String>, disputed: Set<String>) -> Int64 {
        (carriage ?? 0) + lines.filter { binding == "digital" ? kept.contains($0.id) : !(disputed.contains($0.id) && $0.verdict == "consumed") }.reduce(0) { $0 + $1.amount }
    }
}
/// Demonstration-only local reducer. No server, credential or financial effect.
public struct DemoOperation: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case reviewing, ceremony, unknown, confirmed }
    public private(set) var phase: Phase = .reviewing
    public private(set) var simulatedEffects = 0
    public private(set) var contentDigest: String?
    public init() {}
    public mutating func review(_ text: String) { guard phase == .reviewing else { return }; contentDigest=Canonical.digest(text) }
    public mutating func begin() throws { guard phase == .reviewing, contentDigest != nil else { throw ContractError.invalidTransition }; phase = .ceremony }
    public mutating func cancel() throws { guard phase == .ceremony else { throw ContractError.invalidTransition }; phase = .reviewing }
    public mutating func submit(lostReply: Bool) throws { guard phase == .ceremony else { throw ContractError.invalidTransition }; simulatedEffects += 1; phase = lostReply ? .unknown : .confirmed }
    public mutating func reconcile() throws { guard phase == .unknown else { throw ContractError.invalidTransition }; phase = .confirmed }
}
