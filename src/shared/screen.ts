/**
 * The decisions the screens make, separated from the drawing of them.
 *
 * **This module exists because of a measurement.** On 2026-09-12 a sufficiency
 * pass took a copy of this hub, reverted five screen fixes at once (a product
 * block drawn in the standing text's place again, the three sorts removed, the
 * statement's expiry dropped, a price printed beside a gift again, refusals
 * printed as raw codes again) and ran the suite: **50 pass, 0 fail.** Every
 * fix made that night lived in a browser script that nothing reaches, so the
 * evidence for all of them was that somebody had said so.
 *
 * What is here is what can be decided without a DOM: which lines a person may
 * still answer, which blocks govern a line and in what order, and what a
 * statement comes to. The drawing stays in `client/app.ts`; **the judgement
 * does not.**
 */

/** §10 step 3c. A candidate as the approval sends it, for the one question below. */
export type ApprovalLine = { id: string; valence: string };

/**
 * §10 step 3c, §11. The lines still this household's to answer, and the lines
 * something has already resolved.
 *
 * A physical box is collected line by line and the offer stays `presented`, so
 * an approval routinely carries both. A screen that asks for a choice on every
 * candidate posts a set naming a resolved one, which the engine refuses with
 * `409 already_decided`, and the household can never confirm the lines that
 * are still its own.
 */
export function decidable<T extends ApprovalLine>(candidates: readonly T[]): { open: T[]; resolved: T[] } {
  return {
    open: candidates.filter((c) => c.valence === "offered"),
    resolved: candidates.filter((c) => c.valence !== "offered"),
  };
}

export type Block = {
  merchant: string;
  product: string | null;
  items: { label: string; value: string }[];
  /**
   * Question 72, decided 2026-09-22. The merchant's own contact, absent
   * where it gave none. Rendered exactly as signed, beside this block's own
   * terms; `blocksFor` passes it through unread, the same as `items`.
   */
  contact?: { kind: "email" | "tel" | "url"; value: string };
};

/**
 * §10a.5. The blocks that govern one line, in the order they are drawn.
 *
 * **Both, and never one in the other's place.** A product block "carries only
 * the items that differ", so drawing it alone leaves the payment timing, the
 * delivery timing and the 返品特約 off the screen wherever a merchant has
 * registered one, and the person signs a line whose terms they were never
 * shown. The product block is first, because where a label appears in both it
 * is the one that governs this line; the two are shown as signed rather than
 * merged.
 *
 * An empty result means no block at all, which §10a.3 refuses long before a
 * screen is drawn, so it is a hub reading a response it should never receive.
 */
export function blocksFor(
  blocks: readonly Block[],
  which: { merchant: string; product: string | null }
): { block: Block; scope: "product" | "standing" }[] {
  const out: { block: Block; scope: "product" | "standing" }[] = [];
  const forProduct =
    which.product === null
      ? undefined
      : blocks.find((b) => b.merchant === which.merchant && b.product === which.product);
  const standing = blocks.find((b) => b.merchant === which.merchant && b.product === null);
  if (forProduct) out.push({ block: forProduct, scope: "product" });
  if (standing) out.push({ block: standing, scope: "standing" });
  return out;
}

export type StatementLine = { candidate: string; valence: string; amount: number };

/**
 * §6.5, §6.2. What the household will be charged for the goods.
 *
 * Undisputed lines at their own amount, which is `0` for a gift because the
 * engine's statement puts `0` there whatever the line's valence. **The two
 * arithmetics disagreeing is the worst defect this project has had**: the
 * engine billed a kept gift at its price while the document the household
 * signed read zero, so a screen showing ¥900 settled at ¥3,300.
 *
 * **The carriage is not in this figure** (§7.5b): the engine's `charged`
 * excludes it, and the screen says so beside the total rather than leaving a
 * person to guess whether ¥900 above a ¥500 carriage means ¥900 or ¥1,400.
 */
export function statementTotal(
  lines: readonly StatementLine[],
  disputed: ReadonlySet<string>
): number {
  return lines
    .filter((l) => !disputed.has(l.candidate))
    .reduce((sum, l) => sum + l.amount, 0);
}

/**
 * §6.5, §11.2. Only a line the collection wrote down may be disputed: one it
 * found used, or one it recorded missing (question 46). A statement carries
 * `lost` only for a missing record, since a candidate the deadline made `lost`
 * is not on it, so the valence alone is enough here. A kept line is one the
 * household signed itself.
 */
export const disputable = (line: { valence: string }): boolean =>
  line.valence === "consumed" || line.valence === "lost";

/**
 * §6.5. Whether disputing this line takes anything out of the charge. A
 * missing line is never charged, so disputing it records that the household
 * contests the loss and moves no money.
 */
export const disputeMovesMoney = (line: { valence: string }): boolean => line.valence === "consumed";

/**
 * §6.6, question 70. The household's receipt of what a merchant has appended
 * to a settlement it signed: the original as it was signed, each correction
 * in the order it arrived, and what remains. A correction only ever lowers
 * what was charged; the settlement itself is never rewritten.
 */
export type Correction = {
  id: string;
  offer: string;
  merchant: string;
  amount: number;
  kind: "refund" | "collection";
  note: string;
  corrected_at: number;
  signature: string;
};
export type Corrections = {
  offer: string;
  original: { charged: number; carriage: number | null };
  corrections: Correction[];
  net: number;
};

const CORRECTION_KEYS = ["id", "offer", "merchant", "amount", "kind", "note", "corrected_at", "signature"];

/**
 * §6.6. Checked the same way every other response from the engine is checked
 * here: exact keys, the arithmetic that binds them, and the offer this was
 * asked for. `null` is "nothing to show", never "the settlement failed" — a
 * caller that gets it back still has the settlement to show on its own.
 */
export function validateCorrections(body: unknown, offerId: string): Corrections | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  if (Object.keys(b).sort().join(",") !== "corrections,net,offer,original") return null;
  if (typeof b.offer !== "string" || b.offer !== offerId) return null;
  if (typeof b.original !== "object" || b.original === null) return null;
  const orig = b.original as Record<string, unknown>;
  if (Object.keys(orig).sort().join(",") !== "carriage,charged") return null;
  if (!Number.isInteger(orig.charged) || (orig.charged as number) < 0) return null;
  if (orig.carriage !== null && !Number.isInteger(orig.carriage)) return null;
  if ((orig.carriage as number | null) !== null && (orig.carriage as number) < 0) return null;
  if (!Array.isArray(b.corrections)) return null;
  const rows: Correction[] = [];
  let sum = 0;
  for (const row of b.corrections) {
    if (typeof row !== "object" || row === null) return null;
    const r = row as Record<string, unknown>;
    if (Object.keys(r).sort().join(",") !== [...CORRECTION_KEYS].sort().join(",")) return null;
    if (typeof r.id !== "string" || !r.id) return null;
    if (typeof r.offer !== "string" || r.offer !== offerId) return null;
    if (typeof r.merchant !== "string" || !r.merchant) return null;
    if (!Number.isInteger(r.amount) || (r.amount as number) < 1) return null;
    if (r.kind !== "refund" && r.kind !== "collection") return null;
    if (typeof r.note !== "string" || r.note.length > 500) return null;
    if (!Number.isInteger(r.corrected_at) || (r.corrected_at as number) < 0) return null;
    if (typeof r.signature !== "string" || !r.signature) return null;
    sum += r.amount as number;
    rows.push(r as unknown as Correction);
  }
  const base = (orig.charged as number) + ((orig.carriage as number | null) ?? 0);
  if (!Number.isInteger(b.net) || sum > base || base - sum !== b.net) return null;
  return { offer: b.offer, original: orig as Corrections["original"], corrections: rows, net: b.net as number };
}

/**
 * §3, question 48, decided 2026-09-15. What a `lost` line says, told apart by
 * what the collection named it. Not in the box is a record about the
 * household's home that it sees on its statement and may dispute; a line the
 * deadline made `lost` is on no statement. `undefined` is an engine from before
 * the field, where the two cannot be told apart and the sentence names both.
 * The iOS detail screen carries the same words.
 */
export function lostOutcome(collectedAs: string | null | undefined): string {
  if (collectedAs === "missing") {
    return "Not in the box: the collection did not find it. Never charged to you, and you can dispute it on the statement if it was there.";
  }
  if (collectedAs === null) return "Not collected by the deadline. Never charged to you.";
  return "Not returned: the collection did not find it in the box, or it was not collected by the deadline. Never charged to you.";
}
