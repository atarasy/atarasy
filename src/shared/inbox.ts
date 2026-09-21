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
  /** `collected_as` is question 48's; absent from an engine before the field. */
  candidates: { id: string; valence: string; collected_as?: string | null }[];
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
