import { describe, expect, test } from "bun:test";
import { blocksFor, decidable, disputable, statementTotal } from "../src/shared/screen.js";
import { REFUSALS, refusal } from "../src/shared/refusals.js";

/**
 * The judgements the screens make.
 *
 * **This file exists because of a measurement, not a policy.** On 2026-09-12 a
 * sufficiency pass took a copy of this hub, reverted five screen fixes at once
 * and ran the suite: 50 pass, 0 fail. Every fix made that night lived in a
 * browser script nothing reaches, so the evidence for all of them was that
 * somebody had said so. The project's oldest recurring failure is a surface
 * without a probe, and the whole hub side of one night's work was it.
 */

describe("§10 step 3c: which lines are still the household's to answer", () => {
  const box = [
    { id: "c-1", valence: "consumed" },
    { id: "c-2", valence: "offered" },
    { id: "c-3", valence: "returned" },
  ];

  test("a half-collected box offers a choice on the undecided line and no other", () => {
    const { open, resolved } = decidable(box);
    expect(open.map((c) => c.id)).toEqual(["c-2"]);
    expect(resolved.map((c) => c.id)).toEqual(["c-1", "c-3"]);
  });

  test("a box with nothing left open offers no choice at all", () => {
    // The confirm button is drawn from `open.length`, so this is what stops a
    // screen offering a button the engine would refuse with `already_decided`.
    const { open } = decidable(box.filter((c) => c.valence !== "offered"));
    expect(open).toHaveLength(0);
  });

  test("a fresh offer is open end to end", () => {
    const { open, resolved } = decidable([{ id: "a", valence: "offered" }, { id: "b", valence: "offered" }]);
    expect(open).toHaveLength(2);
    expect(resolved).toHaveLength(0);
  });
});

describe("§10a.5: a product block sits beside the standing text and never in its place", () => {
  const standing = { merchant: "maker-a", product: null, items: [{ label: "payment", value: "on confirmation" }, { label: "returns", value: "as published" }] };
  const forTea = { merchant: "maker-a", product: "tea-a", items: [{ label: "returns", value: "eight days for this product" }] };
  const other = { merchant: "maker-b", product: null, items: [{ label: "payment", value: "on despatch" }] };

  test("a line governed by a product block is drawn with both, product first", () => {
    // Drawing the product block alone was the defect: it carries only the
    // items that differ, so the payment timing, the delivery timing and the
    // 返品特約 left the screen wherever a merchant had registered one.
    const got = blocksFor([standing, forTea, other], { merchant: "maker-a", product: "tea-a" });
    expect(got.map((g) => g.scope)).toEqual(["product", "standing"]);
    expect(got[0]!.block).toBe(forTea);
    expect(got[1]!.block).toBe(standing);
  });

  test("a line governed by the standing text is drawn with it alone", () => {
    const got = blocksFor([standing, forTea], { merchant: "maker-a", product: null });
    expect(got.map((g) => g.scope)).toEqual(["standing"]);
    expect(got[0]!.block).toBe(standing);
  });

  test("no merchant's block reaches another merchant's line", () => {
    expect(blocksFor([standing, forTea, other], { merchant: "maker-b", product: null }).map((g) => g.block)).toEqual([other]);
    expect(blocksFor([other], { merchant: "maker-a", product: "tea-a" })).toHaveLength(0);
  });

  test("the items are handed over as composed, in the merchant's own order", () => {
    // §10a.2. No shortening, translating, reordering or folding.
    const got = blocksFor([standing], { merchant: "maker-a", product: null });
    expect(got[0]!.block.items).toEqual(standing.items);
  });
});

describe("§6.5: what the statement says will be charged", () => {
  const lines = [
    { candidate: "paid", valence: "consumed", amount: 900 },
    { candidate: "gift", valence: "consumed", amount: 0 },
    { candidate: "kept", valence: "kept", amount: 1500 },
  ];

  test("a gift adds nothing, whatever became of it", () => {
    // The worst defect this project has had: the engine billed a kept gift at
    // its price while the document the household signed read zero, so a screen
    // showing ¥900 settled at ¥3,300.
    expect(statementTotal(lines, new Set())).toBe(2400);
    expect(statementTotal([lines[1]!], new Set())).toBe(0);
  });

  test("a disputed line leaves the total", () => {
    expect(statementTotal(lines, new Set(["paid"]))).toBe(1500);
    expect(statementTotal(lines, new Set(["paid", "kept"]))).toBe(0);
  });

  test("only a line the collection found used may be disputed", () => {
    expect(disputable({ valence: "consumed" })).toBe(true);
    expect(disputable({ valence: "kept" })).toBe(false);
    expect(disputable({ valence: "defaulted" })).toBe(false);
  });
});

describe("a refusal says what happened and what the member can do", () => {
  test("every code the screen can provoke has a sentence", () => {
    for (const code of [
      "mandate_cooling", "mandate_ceiling_daily", "statement_unsigned",
      "already_settled", "already_decided", "bad_signature", "delivery_missing",
      "not_disputable", "not_withdrawable", "bad_state", "config_missing", "no_cooling", "cooling_over",
      "confirmation_reused", "engine_unreachable",
    ]) {
      expect(typeof REFUSALS[code]).toBe("string");
      expect(REFUSALS[code]!.length).toBeGreaterThan(20);
    }
  });

  test("an unknown code falls through to the engine's words rather than to silence", () => {
    expect(refusal({ error: "something_new", message: "the engine's own sentence" }, 422)).toBe("the engine's own sentence");
    expect(refusal({}, 500)).toBe("this answered 500");
  });

  test("nothing answering is not the same as nothing having happened", () => {
    // A `POST` may have reached the engine and been applied before the
    // connection failed. The sentence promised otherwise on exactly the screen
    // where the charge happens.
    expect(refusal({}, 0)).toBe(REFUSALS.engine_unreachable!);
    expect(REFUSALS.engine_unreachable!).not.toContain("Nothing was sent and nothing was decided");
  });

  test("no sentence promises that something settles on its own", () => {
    // §16.5, §6.5. The engine has no scheduler: `sweep` applies expiry and
    // nothing else, and the only settle is the route. On a statement the
    // household is the party that settles, so a cooling window means it must
    // come back and sign again. The sentence used to say the opposite.
    expect(REFUSALS.mandate_cooling!).toContain("sign again");
    for (const [code, sentence] of Object.entries(REFUSALS)) {
      expect([code, /settles by itself|settle by itself|on its own once/.test(sentence)]).toEqual([code, false]);
    }
  });

  test("the daily ceiling does not promise a tomorrow that question 39 says may never come", () => {
    // The sentence may say what was counted today; what it may not do is
    // frame the refusal as a wait. Where the box's own total is above the
    // ceiling it can never be signed at that ceiling, and the cure is a
    // loosening, which needs the people the person named (clause 47).
    expect(REFUSALS.mandate_ceiling_daily!).not.toMatch(/cannot (go through|settle) today|not today|try again tomorrow/);
    expect(REFUSALS.mandate_ceiling_daily!).toContain("while that limit stands");
  });

  test("a refused state does not call every offer a box, nor every refusal a settlement", () => {
    // `bad_state` is thrown by settle, by a decision on an offer that closed
    // while the screen was open, and by a take-back on one that moved on.
    expect(REFUSALS.bad_state!).not.toContain("box");
    expect(REFUSALS.bad_state!).not.toContain("settle.");
  });

  test("a settlement that already stands does not claim the household's own signature was discarded", () => {
    // It is also what a household sees when its signature went through and the
    // answer was lost.
    expect(REFUSALS.already_settled!).toContain("that signature is what settled it");
  });
});
