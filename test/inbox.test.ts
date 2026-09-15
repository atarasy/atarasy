import { describe, expect, test } from "bun:test";
import { awaitsDecision, awaitsStatement, byArrival, holdsNextBox, type InboxOffer } from "../src/shared/inbox.js";

/**
 * The rule that sorts a member's own list.
 *
 * It is tested on its own because the version it replaced could not be: the
 * screen asked the engine once per historical offer whether a statement was
 * waiting, and treated every answer that was not `200` as "no statement". A
 * refutation pass over this hub on 2026-09-12 found what that draws. A
 * collected box whose statement could not be read was filed under "Decided,
 * and not yet settled", told the household it would settle by itself, and
 * offered a Take-it-back button, while §6.5 had already stopped that
 * presenter's next box and nothing on the screen said so.
 */
const offer = (over: Partial<InboxOffer> = {}): InboxOffer => ({
  id: "o-1",
  presenter: "presenter-a",
  state: "presented",
  binding: "digital",
  presented_at: 1_000,
  expires_at: 2_000,
  giver: null,
  candidates: [{ id: "c-1", valence: "offered" }],
  ...over,
});

describe("§6.5: a box waiting on a signature is one the list can see", () => {
  test("a collected physical box whose lines were used waits on a statement", () => {
    const box = offer({
      binding: "physical",
      state: "decided",
      candidates: [{ id: "c-1", valence: "consumed" }, { id: "c-2", valence: "returned" }],
    });
    expect(awaitsStatement(box)).toBe(true);
    expect(awaitsDecision(box)).toBe(false);
  });

  test("an expired box with goods used waits on one too", () => {
    // Nothing was decided, the window passed, and the route still found goods
    // used. The old screen showed this row nowhere at all.
    expect(awaitsStatement(offer({
      binding: "physical",
      state: "expired",
      candidates: [{ id: "c-1", valence: "consumed" }, { id: "c-2", valence: "defaulted" }],
    }))).toBe(true);
  });

  test("a box whose only collection line is missing waits on a statement and holds no next box", () => {
    // Question 46. The household is shown the missing record and may dispute
    // it, but nothing is owed on it, so the presenter's next box is not held.
    const box = offer({
      binding: "physical",
      state: "decided",
      candidates: [{ id: "c-1", valence: "lost" }, { id: "c-2", valence: "returned" }],
    });
    expect(awaitsStatement(box)).toBe(true);
    expect(holdsNextBox(box)).toBe(false);
    expect(holdsNextBox(offer({ candidates: [{ id: "c-1", valence: "consumed" }, { id: "c-2", valence: "lost" }] }))).toBe(true);
    // A missing line beside a kept one holds the next box, as the engine does; a deadline loss beside it does not.
    expect(holdsNextBox(offer({ candidates: [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "lost", collected_as: "missing" }] }))).toBe(true);
    expect(holdsNextBox(offer({ candidates: [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "lost", collected_as: null }] }))).toBe(false);
  });

  test("a box lost at the deadline waits on nothing once the list says what the collection named (question 48)", () => {
    const deadline = offer({ binding: "physical", state: "expired", candidates: [{ id: "c-1", valence: "lost", collected_as: null }] });
    expect(awaitsStatement(deadline)).toBe(false);
    const missing = offer({ binding: "physical", state: "decided", candidates: [{ id: "c-1", valence: "lost", collected_as: "missing" }] });
    expect(awaitsStatement(missing)).toBe(true);
    // An engine from before the field: the two cannot be told apart, so the box is shown.
    expect(awaitsStatement(offer({ binding: "physical", state: "expired", candidates: [{ id: "c-1", valence: "lost" }] }))).toBe(true);
  });

  test("a settled box waits on nothing, and needs no second call to say so", () => {
    expect(awaitsStatement(offer({
      binding: "physical",
      state: "settled",
      candidates: [{ id: "c-1", valence: "consumed" }],
    }))).toBe(false);
  });

  test("a box that came back with nothing used waits on nothing", () => {
    expect(awaitsStatement(offer({
      binding: "physical",
      state: "decided",
      candidates: [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "returned" }],
    }))).toBe(false);
  });

  test("a digital offer never waits on a statement, whatever its lines say", () => {
    expect(awaitsStatement(offer({
      binding: "digital",
      state: "decided",
      candidates: [{ id: "c-1", valence: "consumed" }],
    }))).toBe(false);
  });
});

describe("§10, §11: a box half collected is still the household's to decide", () => {
  test("a presented box with one line used and one untouched is asked about", () => {
    // §11 allows a partial collection and the offer stays `presented`. The
    // screen asks about the `offered` line and about nothing else; it used to
    // require a choice on every candidate and post the lot, which the engine
    // refused with `already_decided`.
    const box = offer({
      binding: "physical",
      candidates: [{ id: "c-1", valence: "consumed" }, { id: "c-2", valence: "offered" }],
    });
    expect(awaitsDecision(box)).toBe(true);
    expect(awaitsStatement(box)).toBe(false);
  });

  test("a presented box with nothing left undecided is not asked about", () => {
    expect(awaitsDecision(offer({
      candidates: [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "returned" }],
    }))).toBe(false);
  });

  test("a withdrawn or drafted offer is on no list", () => {
    for (const state of ["withdrawn", "drafted"] as const) {
      const o = offer({ state });
      expect(awaitsDecision(o)).toBe(false);
      expect(awaitsStatement(o)).toBe(false);
    }
  });
});

describe("`04b` §1b.2: arrival, newest first, and no presenter's block of rows", () => {
  test("the order is when each arrived and never which presenter sent it", () => {
    const rows: InboxOffer[] = [
      offer({ id: "a-old", presenter: "presenter-a", presented_at: 100 }),
      offer({ id: "a-new", presenter: "presenter-a", presented_at: 400 }),
      offer({ id: "b-mid", presenter: "presenter-b", presented_at: 300 }),
      offer({ id: "b-older", presenter: "presenter-b", presented_at: 200 }),
    ];
    expect([...rows].sort(byArrival).map((o) => o.id)).toEqual(["a-new", "b-mid", "b-older", "a-old"]);
  });

  test("an offer never presented falls back to its expiry rather than to the top", () => {
    const rows: InboxOffer[] = [
      offer({ id: "never", presented_at: null, expires_at: 50 }),
      offer({ id: "recent", presented_at: 900 }),
    ];
    expect([...rows].sort(byArrival).map((o) => o.id)).toEqual(["recent", "never"]);
  });
});
