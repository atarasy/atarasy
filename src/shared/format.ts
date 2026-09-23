/**
 * How amounts, dates and goods are written for a member. Vault `80` §6.3 and
 * D-3, and the iOS `MemberFormat` this mirrors.
 *
 * Every screen prints money, a date or a candidate's title through here,
 * rather than a raw integer, an epoch or a protocol word. A pure module so
 * the suite can hold it to the same rule the iOS app measures itself
 * against: `MemberFormat.goods`, `.money` and `.day` in
 * `ios/AtarasyPrototype/MemberFormat.swift`.
 */

/**
 * D-1, catalogue revision 3. The goods' own name where the catalogue gave
 * one, with the variant beside it; otherwise the merchant's product
 * reference, which is the merchant's own text too (clause 54). Rendered
 * verbatim: never composed, translated or shortened.
 *
 * `name` and `variant` are absent from a candidate published before revision
 * 3, which is why both are optional and the fallback is the reference this
 * screen has always shown.
 */
export function goodsTitle(goods: { name?: string | null; variant?: string | null; product: string }): string {
  if (!goods.name) return goods.product;
  return goods.variant ? `${goods.name} ${goods.variant}` : goods.name;
}

/**
 * D-3. A host serves one currency for the length of a deployment, so an
 * amount is formatted with grouping and no decimal places (whole yen for
 * JPY): `Intl.NumberFormat` in currency style, never `toLocaleString` on the
 * bare integer, which carried no symbol and no unit.
 */
export function formatMoney(amount: number, currency = "JPY", locale?: string): string {
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency,
    maximumFractionDigits: 0,
    minimumFractionDigits: 0,
  }).format(amount);
}

/**
 * "Thu 2 Oct." A digital proposal's close and a box's next swap are days, not
 * moments, and clause 30 forbids a countdown, so nothing here counts down to
 * one.
 */
export function formatDay(ms: number, locale?: string): string {
  return new Date(ms).toLocaleDateString(locale, { weekday: "short", day: "numeric", month: "short" });
}

/**
 * Who sells what, said once: one merchant by name, several as "A, B and C"
 * (or its Japanese equivalent). Mirrors iOS's `MemberParties.sellers`, which
 * lists a row's or a screen's distinct merchants the same way.
 */
export function sellers(merchants: readonly string[], locale?: string): string {
  return new Intl.ListFormat(locale, { style: "long", type: "conjunction" }).format(merchants);
}

/** The same day, with the clock time beside it, for a deadline that is also an hour. */
export function formatDayTime(ms: number, locale?: string): string {
  return new Date(ms).toLocaleString(locale, {
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "numeric",
    minute: "2-digit",
  });
}
