import SwiftUI
import AtarasyCore

/// How numbers, dates and goods are written for a member (vault `80` §6.3). Everything a
/// screen shows about money or time goes through here, so a screen never prints a raw
/// integer, an epoch or a protocol word.
enum MemberFormat {
    /// Valence §14b, decided 2026-09-23 (vault `80` D-3): a host serves one currency and the
    /// trusted build names it. Every integer amount on that host is in this currency.
    static let currencyCode: String = (Bundle.main.object(forInfoDictionaryKey: "AtarasyMemberCurrency") as? String) ?? "JPY"

    static func money(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        // Integers on the rail are whole units of the currency (whole yen for JPY).
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? String(amount)
    }

    /// Quantity times unit price, saturating rather than trapping; both were checked as safe integers on decode.
    static func lineTotal(_ unitPrice: Int64, _ quantity: Int64) -> Int64 {
        let (value, overflow) = unitPrice.multipliedReportingOverflow(by: quantity)
        return overflow ? Int64.max : value
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// "Thu 2 Oct". A day is what a digital close and a box swap are about; nothing here counts down (clause 30).
    static func day(_ ms: Int64) -> String {
        date(ms).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    static func dayAndTime(_ ms: Int64) -> String {
        date(ms).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// A cooling period or any other span in the largest unit that reads naturally.
    static func duration(seconds: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds % 86_400 == 0 && seconds >= 86_400 ? [.day] : seconds % 3_600 == 0 && seconds >= 3_600 ? [.hour] : seconds >= 60 ? [.minute] : [.second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }

    /// The goods' own name where the catalogue gave one (catalogue revision 3), with the
    /// variant beside it; otherwise the merchant's product reference, which is the merchant's
    /// text too. Rendered verbatim: never composed, translated or shortened (clause 54).
    static func goods(name: String?, variant: String?, product: String) -> String {
        guard let name else { return product }
        return variant.map { name + " " + $0 } ?? name
    }
}

extension MemberOfferSummary.Line { var title: String { MemberFormat.goods(name: name, variant: variant, product: product) } }
extension MemberOfferDetail.Candidate { var title: String { MemberFormat.goods(name: name, variant: variant, product: product) } }
extension MemberApproval.Candidate { var title: String { MemberFormat.goods(name: name, variant: variant, product: product) } }
extension MemberStatement.Line { var title: String { MemberFormat.goods(name: name, variant: variant, product: product) } }
extension ProtocolSettlement.Line { var title: String { MemberFormat.goods(name: name, variant: variant, product: product) } }

/// Shared look. One accent, cards on grouped backgrounds, and amounts in tabular digits.
enum MemberStyle {
    static let corner: CGFloat = 14
    static let accent = Color.accentColor
}

struct MemberCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: MemberStyle.corner, style: .continuous))
    }
}

/// A small label beside a line: a gift, something new to the household, a line already settled.
struct MemberTag: View {
    let text: LocalizedStringKey
    var systemImage: String? = nil
    var tint: Color = .secondary
    var body: some View {
        Label { Text(text) } icon: { if let systemImage { Image(systemName: systemImage) } }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// A leading/trailing pair (a name and its amount, most often) that sits on one line at ordinary
/// text sizes and stacks the trailing part below the leading part, right-aligned, once Dynamic
/// Type would otherwise squeeze one side off the screen or force an overlap (IOS-17, UX-T11).
/// `ViewThatFits` measures both arrangements and keeps whichever is not clipped.
struct MemberWrappingRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { leading; Spacer(minLength: 12); trailing }
            VStack(alignment: .leading, spacing: 2) {
                leading
                HStack { Spacer(minLength: 0); trailing }
            }
        }
    }
}

/// A row of label and amount, the amount right-aligned in tabular digits. Falls back to a
/// two-line layout at accessibility text sizes rather than truncating either side.
struct MemberAmountRow: View {
    let label: LocalizedStringKey
    let amount: String
    var emphasised = false
    var body: some View {
        MemberWrappingRow {
            Text(label)
        } trailing: {
            Text(verbatim: amount).monospacedDigit()
        }
        .font(emphasised ? .headline : .body)
        .accessibilityElement(children: .combine)
    }
}

/// A banner for a state the member should know about before anything else on the screen.
struct MemberBanner: View {
    let text: String
    var systemImage = "exclamationmark.circle"
    var tint: Color = .orange
    var body: some View {
        Label { Text(verbatim: text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: systemImage) }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
