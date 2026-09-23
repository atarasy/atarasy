import { goodsTitle } from "./format.js";

/**
 * How a member's own list is sorted into sections.
 *
 * This is a module of its own because the rule is the part that was wrong.
 * The screen used to ask the engine, once per historical offer, whether a
 * settlement statement was waiting, and file anything that did not answer
 * `200` under "Decided, and not yet settled". A split deployment refusing per
 * §13.1, a transient 502, a 404 from an engine that does not know the offer:
 * each of them drew a collected box as one that settles by itself, with a
 * Take-it-back button, while that presenter's next box was already stopped and
 * the household had nothing to sign. **The list the engine already returns
 * says all of it**, so the rule is arithmetic on data in hand rather than a
 * request that can fail.
 */
export type InboxOffer = {
  id: string;
  presenter: string;
  state: "drafted" | "presented" | "decided" | "expired" | "withdrawn" | "settled";
  binding: "digital" | "physical";
  presented_at: number | null;
  decided_at: number | null;
  expires_at: number;
  giver: string | null;
  /**
   * §9's `GET /offers` already answers with the engine's full candidate view
   * (`candidateView` in `valence/engine/src/http.ts`), the same one `.../approval`
   * carries: `product`, `merchant`, catalogue revision 3's optional `name` and
   * `variant` (D-1), and the rest. This type used to declare only `id`,
   * `valence` and `collected_as`, which is a subset a caller can always read
   * off a wider object, so nothing here was ever wrong to parse: the row this
   * hub drew from it just never asked for the fields that were already on the
   * wire, and asked a second question (`.../approval`) for what the list
   * answer had carried the whole time.
   */
  candidates: {
    id: string;
    valence: string;
    /** `collected_as` is question 48's; absent from an engine before the field. */
    collected_as?: string | null;
    product: string;
    merchant: string;
    /** D-1, catalogue revision 3. Absent from a candidate published before it. */
    name?: string | null;
    variant?: string | null;
  }[];
};

/**
 * §6.5. A physical box whose collection found goods used or recorded goods
 * missing, and which nothing has settled. A settled offer is in `settled`,
 * which is why the state carries the answer and no second call is needed to
 * ask whether money has moved.
 *
 * **A `lost` line counts only where the collection recorded it missing**
 * (question 48, decided 2026-09-15). A line the deadline made `lost` is on no
 * statement, and until the list carried `collected_as` the two looked the same
 * here, so every box with a `lost` line was filed as waiting and a box lost at
 * the deadline opened to a statement with nothing on it. An engine from before
 * the field sends no `collected_as`, and there the over-reach stays, because
 * leaving such a line out would keep a box whose only collection lines are
 * missing off this surface, which §6.5 requires the hub to show.
 */
export const awaitsStatement = (o: InboxOffer): boolean =>
  o.binding === "physical" &&
  (o.state === "decided" || o.state === "expired") &&
  o.candidates.some(
    (c) => c.valence === "consumed" || (c.valence === "lost" && (c.collected_as === "missing" || c.collected_as === undefined))
  );

/**
 * §6.5, question 46. Whether a waiting box holds this presenter's next one,
 * the same rule as the engine's `hasUnsignedStatement`: goods used hold it, and
 * so does a line the collection recorded missing beside a kept, defaulted or
 * consumed line, so a household cannot receive the next box by never signing.
 * A box whose only collection lines are missing owes nothing and holds nothing.
 * This said "only goods used" until a refutation pass on 2026-09-15 read it
 * against the engine: the list told a household its next box was not held
 * while the engine refused it with `statement_unsigned`.
 */
export const holdsNextBox = (o: InboxOffer): boolean =>
  o.candidates.some((c) => c.valence === "consumed") ||
  (o.candidates.some((c) => c.valence === "lost" && (c.collected_as === "missing" || c.collected_as === undefined)) &&
    o.candidates.some((c) => c.valence === "kept" || c.valence === "defaulted"));

/**
 * §10, §11. A line nobody has decided yet. A physical box is collected line by
 * line and the offer stays `presented`, so a box can be here with part of it
 * already resolved; the approval screen asks only about the rest.
 */
export const awaitsDecision = (o: InboxOffer): boolean =>
  o.state === "presented" && o.candidates.some((c) => c.valence === "offered");

/**
 * `04b` §1b.2. Arrival, newest first, and nothing ranked, scored or grouped by
 * merchant. The list used to be the operator's `VALENCE_PRESENTERS` in the
 * order it was typed, each engine's answer appended oldest first, so a member
 * read every offer of presenter A and then every offer of presenter B. An
 * operator who listed a presenter first had sold position in the currency
 * clause 14 forbids, and nothing in the code stopped a presenter paying for it.
 */
export const byArrival = (a: InboxOffer, b: InboxOffer): number =>
  (b.presented_at ?? b.expires_at) - (a.presented_at ?? a.expires_at);

/**
 * Vault `80` §6.2 I. The one status line a row carries, in the member's own
 * words rather than a protocol state. Four of the plan's six cases are ones
 * this list can answer on its own; the other two (a decided set's cooling
 * countdown and a result gone unknown) need the mandate and a saved
 * operation handle this module does not hold, and are drawn by the caller.
 *
 * A pure function so the case a row falls into is decided once, here, rather
 * than by an `if` chain repeated wherever a row is drawn.
 */
export type RowStatus =
  | { kind: "box-waiting"; nextSwap: number }
  | { kind: "box-statement-ready"; holdsNext: boolean }
  | { kind: "proposal-undecided"; closes: number }
  | { kind: "proposal-decided" };

export function rowStatus(o: InboxOffer): RowStatus {
  if (awaitsStatement(o)) return { kind: "box-statement-ready", holdsNext: holdsNextBox(o) };
  if (o.binding === "physical") return { kind: "box-waiting", nextSwap: o.expires_at };
  if (awaitsDecision(o)) return { kind: "proposal-undecided", closes: o.expires_at };
  return { kind: "proposal-decided" };
}

/**
 * D-1, vault `80` §6.2 I: "a row shows product name of the first line and
 * '+2 more'". `title` is `goodsTitle()` (`shared/format.ts`) of the first
 * candidate; `moreCount` is how many lines beyond it there are, which the
 * caller turns into the iOS app's own "%@ and %lld more" (D-5) or leaves
 * unsaid when it is zero. Kept as data rather than a formatted string here,
 * because this module carries no language and no copy table.
 */
export type RowGoods = { title: string; moreCount: number };

export function rowGoods(o: InboxOffer): RowGoods {
  const first = o.candidates[0];
  if (!first) return { title: "", moreCount: 0 };
  return { title: goodsTitle(first), moreCount: o.candidates.length - 1 };
}

/**
 * The merchants this row's lines are sold by, each once, in the order they
 * first appear. A box is one presenter's and several merchants' (clause 11:
 * the presenter is not the seller), so a row's "who sells this" is this list
 * rather than the presenter the old row showed.
 */
export function rowMerchants(o: InboxOffer): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const c of o.candidates) {
    if (!seen.has(c.merchant)) { seen.add(c.merchant); out.push(c.merchant); }
  }
  return out;
}
