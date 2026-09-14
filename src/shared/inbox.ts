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
  expires_at: number;
  giver: string | null;
  candidates: { id: string; valence: string }[];
};

/**
 * §6.5. A physical box whose collection found goods used or recorded goods
 * missing, and which nothing has settled. A settled offer is in `settled`,
 * which is why the state carries the answer and no second call is needed to
 * ask whether money has moved.
 *
 * **A `lost` line counts, and that over-reaches on purpose** (question 46).
 * The list carries a valence and not the collection, so a candidate the
 * collection recorded missing and one the deadline made `lost` look the same
 * here. Leaving `lost` out would keep a box whose only collection lines are
 * missing off this surface, which §6.5 requires the hub to show; counting it
 * files a box lost at the deadline here too, where its statement comes back
 * with no line to sign and the screen says so.
 */
export const awaitsStatement = (o: InboxOffer): boolean =>
  o.binding === "physical" &&
  (o.state === "decided" || o.state === "expired") &&
  o.candidates.some((c) => c.valence === "consumed" || c.valence === "lost");

/**
 * §6.5. Whether a waiting box holds this presenter's next one: only goods used
 * do, because a box whose collection recorded only missing lines owes nothing.
 */
export const holdsNextBox = (o: InboxOffer): boolean => o.candidates.some((c) => c.valence === "consumed");

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
