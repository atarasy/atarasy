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
