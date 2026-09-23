import { describe, expect, test } from "bun:test";
import { awaitsDecision, awaitsStatement, byArrival, holdsNextBox, rowGoods, rowMerchants, rowStatus, type InboxOffer } from "../src/shared/inbox.js";

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
/**
 * §9's `GET /offers` sends the engine's full candidate view, `product` and
 * `merchant` included (`shared/inbox.ts`'s own comment on `InboxOffer`), so a
 * fixture that omits them is not a candidate the engine would actually send.
 * Defaulted here rather than repeated at every call site, since the tests in
 * this file are about `valence` and `collected_as`, not about the goods.
 */
const cand = (over: Partial<InboxOffer["candidates"][number]> = {}): InboxOffer["candidates"][number] => ({
  id: "c-1",
  valence: "offered",
  product: "product-a",
  merchant: "merchant-a",
  ...over,
});

const offer = (over: Partial<InboxOffer> = {}): InboxOffer => ({
  id: "o-1",
  presenter: "presenter-a",
  state: "presented",
  binding: "digital",
  presented_at: 1_000,
  decided_at: null,
  expires_at: 2_000,
  giver: null,
  candidates: [cand()],
  ...over,
});

describe("§6.5: a box waiting on a signature is one the list can see", () => {
  test("a collected physical box whose lines were used waits on a statement", () => {
    const box = offer({
      binding: "physical",
      state: "decided",
      candidates: [cand({ id: "c-1", valence: "consumed" }), cand({ id: "c-2", valence: "returned" })],
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
      candidates: [cand({ id: "c-1", valence: "consumed" }), cand({ id: "c-2", valence: "defaulted" })],
    }))).toBe(true);
  });

  test("a box whose only collection line is missing waits on a statement and holds no next box", () => {
    // Question 46. The household is shown the missing record and may dispute
    // it, but nothing is owed on it, so the presenter's next box is not held.
    const box = offer({
      binding: "physical",
      state: "decided",
      candidates: [cand({ id: "c-1", valence: "lost" }), cand({ id: "c-2", valence: "returned" })],
    });
    expect(awaitsStatement(box)).toBe(true);
    expect(holdsNextBox(box)).toBe(false);
    expect(holdsNextBox(offer({ candidates: [cand({ id: "c-1", valence: "consumed" }), cand({ id: "c-2", valence: "lost" })] }))).toBe(true);
    // A missing line beside a kept one holds the next box, as the engine does; a deadline loss beside it does not.
    expect(holdsNextBox(offer({ candidates: [cand({ id: "c-1", valence: "kept" }), cand({ id: "c-2", valence: "lost", collected_as: "missing" })] }))).toBe(true);
    expect(holdsNextBox(offer({ candidates: [cand({ id: "c-1", valence: "kept" }), cand({ id: "c-2", valence: "lost", collected_as: null })] }))).toBe(false);
  });

  test("a box lost at the deadline waits on nothing once the list says what the collection named (question 48)", () => {
    const deadline = offer({ binding: "physical", state: "expired", candidates: [cand({ id: "c-1", valence: "lost", collected_as: null })] });
    expect(awaitsStatement(deadline)).toBe(false);
    const missing = offer({ binding: "physical", state: "decided", candidates: [cand({ id: "c-1", valence: "lost", collected_as: "missing" })] });
    expect(awaitsStatement(missing)).toBe(true);
    // An engine from before the field: the two cannot be told apart, so the box is shown.
    expect(awaitsStatement(offer({ binding: "physical", state: "expired", candidates: [cand({ id: "c-1", valence: "lost" })] }))).toBe(true);
  });

  test("a settled box waits on nothing, and needs no second call to say so", () => {
    expect(awaitsStatement(offer({
      binding: "physical",
      state: "settled",
      candidates: [cand({ id: "c-1", valence: "consumed" })],
    }))).toBe(false);
  });

  test("a box that came back with nothing used waits on nothing", () => {
    expect(awaitsStatement(offer({
      binding: "physical",
      state: "decided",
      candidates: [cand({ id: "c-1", valence: "kept" }), cand({ id: "c-2", valence: "returned" })],
    }))).toBe(false);
  });

  test("a digital offer never waits on a statement, whatever its lines say", () => {
    expect(awaitsStatement(offer({
      binding: "digital",
      state: "decided",
      candidates: [cand({ id: "c-1", valence: "consumed" })],
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
      candidates: [cand({ id: "c-1", valence: "consumed" }), cand({ id: "c-2", valence: "offered" })],
    });
    expect(awaitsDecision(box)).toBe(true);
    expect(awaitsStatement(box)).toBe(false);
  });

  test("a presented box with nothing left undecided is not asked about", () => {
    expect(awaitsDecision(offer({
      candidates: [cand({ id: "c-1", valence: "kept" }), cand({ id: "c-2", valence: "returned" })],
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

  // `04b` §1b.2, question raised again 2026-09-23: a second refutation pass
  // on this hub's own worktree found that `GET /offers` (the same route this
  // suite exercises via `InboxOffer`) already sends every candidate's
  // `product`, `merchant` and, since catalogue revision 3, `name`/`variant`
  // (`valence/engine/src/http.ts`'s `candidateView`), and the hub's own type
  // had simply never asked for them. `byArrival` orders two presenters'
  // offers correctly regardless, which the test above already proved; this
  // one is arrival unaffected by whether a row happens to have one line or
  // several.
  test("the arrival order does not depend on how many lines a row carries", () => {
    const rows: InboxOffer[] = [
      offer({ id: "one-line", presented_at: 100, candidates: [cand()] }),
      offer({ id: "three-lines", presented_at: 200, candidates: [cand({ id: "c-1" }), cand({ id: "c-2" }), cand({ id: "c-3" })] }),
    ];
    expect([...rows].sort(byArrival).map((o) => o.id)).toEqual(["three-lines", "one-line"]);
  });
});

describe("rowGoods and rowMerchants: a row's title and seller, off the list answer alone", () => {
  test("one line is its own title, with nothing more to count", () => {
    const o = offer({ candidates: [cand({ product: "loose-leaf-tea", merchant: "shop-x" })] });
    expect(rowGoods(o)).toEqual({ title: "loose-leaf-tea", moreCount: 0 });
    expect(rowMerchants(o)).toEqual(["shop-x"]);
  });

  test("catalogue revision 3's name and variant win over the bare product reference", () => {
    const o = offer({ candidates: [cand({ product: "ref-42", name: "Oat milk", variant: "1L" })] });
    expect(rowGoods(o).title).toBe("Oat milk 1L");
  });

  test("a second line is counted, not printed, and the caller turns it into '%@ and %lld more'", () => {
    const o = offer({
      candidates: [
        cand({ id: "c-1", product: "tea-a", merchant: "shop-x" }),
        cand({ id: "c-2", product: "miso-a", merchant: "shop-x" }),
        cand({ id: "c-3", product: "rice-a", merchant: "shop-y" }),
      ],
    });
    expect(rowGoods(o)).toEqual({ title: "tea-a", moreCount: 2 });
  });

  test("a row with no candidates at all has an empty title and no merchants, rather than throwing", () => {
    const o = offer({ candidates: [] });
    expect(rowGoods(o)).toEqual({ title: "", moreCount: 0 });
    expect(rowMerchants(o)).toEqual([]);
  });

  test("merchants are listed once each, in the order they first appear, never per line", () => {
    const o = offer({
      candidates: [
        cand({ id: "c-1", merchant: "shop-x" }),
        cand({ id: "c-2", merchant: "shop-y" }),
        cand({ id: "c-3", merchant: "shop-x" }),
      ],
    });
    expect(rowMerchants(o)).toEqual(["shop-x", "shop-y"]);
  });
});

describe("rowStatus: the one line a row carries", () => {
  test("a box whose lines are still to decide names the next swap", () => {
    const o = offer({ binding: "physical", state: "presented", expires_at: 5_000, candidates: [cand({ valence: "offered" })] });
    expect(rowStatus(o)).toEqual({ kind: "box-waiting", nextSwap: 5_000 });
  });

  test("a box whose statement is ready names whether it holds the next one", () => {
    const holding = offer({ binding: "physical", state: "decided", candidates: [cand({ valence: "consumed" })] });
    expect(rowStatus(holding)).toEqual({ kind: "box-statement-ready", holdsNext: true });
    const notHolding = offer({ binding: "physical", state: "decided", candidates: [cand({ valence: "lost" })] });
    expect(rowStatus(notHolding)).toEqual({ kind: "box-statement-ready", holdsNext: false });
  });

  test("an undecided digital proposal names its close", () => {
    const o = offer({ binding: "digital", state: "presented", expires_at: 9_000, candidates: [cand({ valence: "offered" })] });
    expect(rowStatus(o)).toEqual({ kind: "proposal-undecided", closes: 9_000 });
  });

  test("a decided digital proposal is the one case left over", () => {
    const o = offer({ binding: "digital", state: "decided", candidates: [cand({ valence: "kept" })] });
    expect(rowStatus(o)).toEqual({ kind: "proposal-decided" });
  });
});
