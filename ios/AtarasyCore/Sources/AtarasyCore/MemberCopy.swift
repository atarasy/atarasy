import Foundation

/// A member-facing sentence from this package, in the member's language. The English text is
/// the key, so a locale without a table reads the English, which is what the tests assert.
func L(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: .module) }

/// What became of an act this device sent or checked, for a screen to draw rather than parse
/// out of a notice. `amount` is the goods amount of the settlement that stands, where one does.
public enum MemberActResult: Equatable, Sendable {
    /// This device's act is recorded.
    case recorded(amount: Int64?)
    /// A settlement stands that this device did not send.
    case settledElsewhere(amount: Int64)
    /// A settlement stands and this device cannot tell whether it is the one it saved.
    case settledUnverified(amount: Int64)
    /// Nothing is recorded yet. Nothing was sent again.
    case pending
    /// The act may have arrived and its result could not be read.
    case unknown
}

enum AtarasyCoreResources {
    static func url(_ localization: String) -> URL? {
        Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: localization)
    }
}
