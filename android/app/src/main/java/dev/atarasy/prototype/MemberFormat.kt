package dev.atarasy.prototype

import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Currency
import java.util.Locale

/**
 * How numbers, dates and goods are written for a member (vault `80` §6.3), ported from the
 * iOS `MemberFormat`. Everything a screen shows about money or time goes through here, so a
 * screen never prints a raw integer, an epoch or a protocol word.
 */
object MemberFormat {
    /** Valence §14b, decided 2026-09-23 (vault `80` D-3): a host serves one currency and the
     * trusted build names it. Every integer amount on that host is in this currency. */
    var currencyCode: String = "JPY"

    fun money(amount: Long, locale: Locale = Locale.getDefault()): String {
        val currency = try { Currency.getInstance(currencyCode) } catch (_: Exception) { Currency.getInstance("JPY") }
        val formatter = NumberFormat.getCurrencyInstance(locale)
        formatter.currency = currency
        // Integers on the rail are whole units of the currency (whole yen for JPY).
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.format(amount)
    }

    /** Quantity times unit price, saturating rather than trapping; both were checked as safe integers on decode. */
    fun lineTotal(unitPrice: Long, quantity: Long): Long {
        val result = try { Math.multiplyExact(unitPrice, quantity) } catch (_: ArithmeticException) { Long.MAX_VALUE }
        return result
    }

    fun instant(ms: Long): Instant = Instant.ofEpochMilli(ms)

    /** "Thu 2 Oct". A day is what a digital close and a box swap are about; nothing here counts down (clause 30). */
    fun day(ms: Long, locale: Locale = Locale.getDefault()): String {
        val formatter = DateTimeFormatter.ofPattern(if (locale.language == "ja") "M月d日(E)" else "EEE d MMM", locale)
        return formatter.withZone(ZoneId.systemDefault()).format(instant(ms))
    }

    fun dayAndTime(ms: Long, locale: Locale = Locale.getDefault()): String {
        val formatter = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale)
        return formatter.withZone(ZoneId.systemDefault()).format(instant(ms))
    }

    /** A cooling period or any other span in the largest unit that reads naturally. */
    fun duration(seconds: Long, locale: Locale = Locale.getDefault()): String {
        val ja = locale.language == "ja"
        return when {
            seconds % 86_400 == 0L && seconds >= 86_400 -> {
                val days = seconds / 86_400
                if (ja) "${days}日" else if (days == 1L) "1 day" else "$days days"
            }
            seconds % 3_600 == 0L && seconds >= 3_600 -> {
                val hours = seconds / 3_600
                if (ja) "${hours}時間" else if (hours == 1L) "1 hour" else "$hours hours"
            }
            seconds >= 60 -> {
                val minutes = seconds / 60
                if (ja) "${minutes}分" else if (minutes == 1L) "1 minute" else "$minutes minutes"
            }
            else -> if (ja) "${seconds}秒" else if (seconds == 1L) "1 second" else "$seconds seconds"
        }
    }

    /** The goods' own name where the catalogue gave one (catalogue revision 3), with the
     * variant beside it; otherwise the merchant's product reference, which is the merchant's
     * text too. Rendered verbatim: never composed, translated or shortened (clause 54). */
    fun goods(name: String?, variant: String?, product: String): String {
        if (name == null) return product
        return if (variant != null) "$name $variant" else name
    }
}

val MemberOfferSummaryLine.title: String get() = MemberFormat.goods(name, variant, product)
val MemberCandidate.title: String get() = MemberFormat.goods(name, variant, product)
val MemberApprovalCandidate.title: String get() = MemberFormat.goods(name, variant, product)
val MemberStatementLine.title: String get() = MemberFormat.goods(name, variant, product)
val ProtocolSettlementLine.title: String get() = MemberFormat.goods(name, variant, product)
