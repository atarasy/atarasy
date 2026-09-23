import { describe, expect, test } from "bun:test";
import { blocksFor, blocksForLines, decidable, decisionGoodsTotal, decisionOutcome, disputable, disputeMovesMoney, statementTotal, undoDeadline, validateCorrections } from "../src/shared/screen.js";
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

  test("a block's own contact passes through untouched, and a block with none carries none", () => {
    // Question 72. `blocksFor` reads only `merchant` and `product`; contact
    // is neither, so this is a passthrough and not a lookup.
    const withContact = { ...forTea, contact: { kind: "email" as const, value: "returns@maker-a.example" } };
    const got = blocksFor([standing, withContact], { merchant: "maker-a", product: "tea-a" });
    expect(got[0]!.block.contact).toEqual({ kind: "email", value: "returns@maker-a.example" });
    expect(got[1]!.block.contact).toBeUndefined();
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

  test("only a line the collection wrote down may be disputed", () => {
    expect(disputable({ valence: "consumed" })).toBe(true);
    // Question 46. A line the collection recorded missing.
    expect(disputable({ valence: "lost" })).toBe(true);
    expect(disputable({ valence: "kept" })).toBe(false);
    expect(disputable({ valence: "defaulted" })).toBe(false);
  });

  test("a missing line is at zero, and disputing it moves no money", () => {
    const withMissing = [...lines, { candidate: "gone", valence: "lost", amount: 0 }];
    expect(statementTotal(withMissing, new Set())).toBe(2400);
    expect(statementTotal(withMissing, new Set(["gone"]))).toBe(2400);
    expect(disputeMovesMoney({ valence: "lost" })).toBe(false);
    expect(disputeMovesMoney({ valence: "consumed" })).toBe(true);
  });
});

describe("§6.6, question 70: the household's receipt of a settlement's corrections", () => {
  const body = () => ({
    offer: "offer-1",
    original: { charged: 1200, carriage: 0 },
    corrections: [
      { id: "correction-1", offer: "offer-1", merchant: "maker-a", amount: 400, kind: "refund", note: "One tin arrived damaged.", corrected_at: 2000, signature: "sig-1" },
    ],
    net: 800,
  });

  test("decodes the original, each correction and the net", () => {
    const got = validateCorrections(body(), "offer-1");
    expect(got).not.toBeNull();
    expect(got!.original).toEqual({ charged: 1200, carriage: 0 });
    expect(got!.net).toBe(800);
    expect(got!.corrections).toHaveLength(1);
    expect(got!.corrections[0]!.kind).toBe("refund");
    expect(got!.corrections[0]!.note).toBe("One tin arrived damaged.");
  });

  test("a null carriage is kept apart from a recorded zero", () => {
    const b = body(); b.original = { charged: 1200, carriage: null as unknown as number }; b.net = 800;
    const got = validateCorrections(b, "offer-1");
    expect(got!.original.carriage).toBeNull();
  });

  test("mismatched arithmetic is refused", () => {
    // 1200 + 0 − 400 = 800, not 799 and not 801.
    expect(validateCorrections({ ...body(), net: 799 }, "offer-1")).toBeNull();
    expect(validateCorrections({ ...body(), net: 801 }, "offer-1")).toBeNull();
  });

  test("a correction of 0, or the sum exceeding what was charged, is refused", () => {
    const zero = body(); zero.corrections = [{ ...zero.corrections[0]!, amount: 0 }]; zero.net = 1200;
    expect(validateCorrections(zero, "offer-1")).toBeNull();
    const over = body(); over.corrections = [{ ...over.corrections[0]!, amount: 2000 }]; over.net = -800;
    expect(validateCorrections(over, "offer-1")).toBeNull();
  });

  test("an extra field anywhere in the body is refused rather than silently kept", () => {
    expect(validateCorrections({ ...body(), paid: true }, "offer-1")).toBeNull();
    const extraRow = body(); extraRow.corrections = [{ ...extraRow.corrections[0]!, extra: "no" } as unknown as (typeof extraRow.corrections)[number]];
    expect(validateCorrections(extraRow, "offer-1")).toBeNull();
  });

  test("a body or a row naming another offer is refused", () => {
    expect(validateCorrections(body(), "another-offer")).toBeNull();
    const wrongRow = body(); wrongRow.corrections = [{ ...wrongRow.corrections[0]!, offer: "another-offer" }];
    expect(validateCorrections(wrongRow, "offer-1")).toBeNull();
  });

  test("a 404 (the offer has no settlement) or a malformed body reads as nothing to show, not as a failure", () => {
    // The caller (`showReceipt` in the client) only calls this on a `200`;
    // this is the shape check that stands in for that boundary here.
    expect(validateCorrections(null, "offer-1")).toBeNull();
    expect(validateCorrections("not an object", "offer-1")).toBeNull();
    expect(validateCorrections({}, "offer-1")).toBeNull();
  });

  test("the merchant's own note passes through as plain text, whatever it contains", () => {
    // Clause 54: shown as written, never as a link or markup. This is the
    // decode; `el()` in the client is what keeps it a text node.
    const withMarkup = body();
    withMarkup.corrections = [{ ...withMarkup.corrections[0]!, note: "<script>alert(1)</script> and 100% honest" }];
    const got = validateCorrections(withMarkup, "offer-1");
    expect(got!.corrections[0]!.note).toBe("<script>alert(1)</script> and 100% honest");
  });

  test("an empty corrections list still decodes, at the settlement's own net", () => {
    const none = { offer: "offer-1", original: { charged: 1200, carriage: 0 }, corrections: [] as unknown[], net: 1200 };
    const got = validateCorrections(none, "offer-1");
    expect(got!.corrections).toHaveLength(0);
    expect(got!.net).toBe(1200);
  });
});

describe("SPEC §6.6a: a returned refund, and the shop's own repayment", () => {
  const base = () => ({
    offer: "offer-1",
    original: { charged: 1200, carriage: 0 },
    corrections: [
      { id: "correction-1", offer: "offer-1", merchant: "maker-a", amount: 400, kind: "refund", note: "One tin arrived damaged.", corrected_at: 2000, signature: "sig-1" },
    ],
    net: 800,
  });
  const returned = () => ({ correction: "correction-1", offer: "offer-1", merchant: "maker-a", state: "returned" as const, note: "The issuer bounced it.", at: 3000, signature: "sig-r1" });

  test("both keys are absent where nothing was returned", () => {
    const got = validateCorrections(base(), "offer-1");
    expect(got!.returns).toBeUndefined();
    expect(got!.owed).toBeUndefined();
  });

  test("a returned refund decodes, and owed sums it", () => {
    const got = validateCorrections({ ...base(), returns: [returned()], owed: 400 }, "offer-1");
    expect(got).not.toBeNull();
    expect(got!.returns).toHaveLength(1);
    expect(got!.returns![0]!.state).toBe("returned");
    expect(got!.owed).toBe(400);
  });

  test("a repaid return leaves nothing owed", () => {
    const repaid = { ...returned(), state: "repaid" as const, at: 4000, note: "Sent by bank transfer.", signature: "sig-r2" };
    const got = validateCorrections({ ...base(), returns: [returned(), repaid], owed: 0 }, "offer-1");
    expect(got!.returns).toHaveLength(2);
    expect(got!.owed).toBe(0);
  });

  test("owed that does not match the sum of unpaid returns is refused", () => {
    expect(validateCorrections({ ...base(), returns: [returned()], owed: 0 }, "offer-1")).toBeNull();
    expect(validateCorrections({ ...base(), returns: [returned()], owed: 401 }, "offer-1")).toBeNull();
  });

  test("returns present without owed, or owed without returns, is refused", () => {
    expect(validateCorrections({ ...base(), returns: [returned()] }, "offer-1")).toBeNull();
    expect(validateCorrections({ ...base(), owed: 400 }, "offer-1")).toBeNull();
  });

  test("an empty returns array is refused rather than read as none", () => {
    expect(validateCorrections({ ...base(), returns: [], owed: 0 }, "offer-1")).toBeNull();
  });

  test("a return naming a correction outside this receipt is refused", () => {
    const stray = { ...returned(), correction: "correction-2" };
    expect(validateCorrections({ ...base(), returns: [stray], owed: 0 }, "offer-1")).toBeNull();
  });

  test("a return on a collection (not a refund) correction is refused", () => {
    const b = base();
    b.corrections = [{ ...b.corrections[0]!, kind: "collection" }];
    expect(validateCorrections({ ...b, returns: [returned()], owed: 400 }, "offer-1")).toBeNull();
  });

  test("a return whose merchant differs from the correction's is refused", () => {
    const wrongMerchant = { ...returned(), merchant: "maker-b" };
    expect(validateCorrections({ ...base(), returns: [wrongMerchant], owed: 400 }, "offer-1")).toBeNull();
  });

  test("more than one returned, or a repaid with no returned, is refused", () => {
    const twice = [returned(), { ...returned(), at: 3500, signature: "sig-r2" }];
    expect(validateCorrections({ ...base(), returns: twice, owed: 400 }, "offer-1")).toBeNull();
    const repaidAlone = [{ ...returned(), state: "repaid" as const }];
    expect(validateCorrections({ ...base(), returns: repaidAlone, owed: 0 }, "offer-1")).toBeNull();
  });

  test("a repaid before its own returned, or a return before the correction, is refused", () => {
    const repaidEarly = [returned(), { ...returned(), state: "repaid" as const, at: 2500, signature: "sig-r2" }];
    expect(validateCorrections({ ...base(), returns: repaidEarly, owed: 0 }, "offer-1")).toBeNull();
    const beforeCorrection = { ...returned(), at: 1000 };
    expect(validateCorrections({ ...base(), returns: [beforeCorrection], owed: 400 }, "offer-1")).toBeNull();
  });

  test("an extra field on a return row is refused", () => {
    const extra = { ...returned(), paid: true } as unknown as ReturnType<typeof returned>;
    expect(validateCorrections({ ...base(), returns: [extra], owed: 400 }, "offer-1")).toBeNull();
  });

  test("the shop's own words on a return pass through as plain text", () => {
    const withMarkup = { ...returned(), note: "<b>sorry</b>, the bank bounced it" };
    const got = validateCorrections({ ...base(), returns: [withMarkup], owed: 400 }, "offer-1");
    expect(got!.returns![0]!.note).toBe("<b>sorry</b>, the bank bounced it");
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

  test("the daily ceiling names the cure that exists for the member reading it", () => {
    // **Two earlier versions of this sentence were wrong in the same
    // direction**, telling a member a door was shut that is open. It may say
    // what was counted today; it may not frame the refusal as a wait, and it
    // may not say there is no way to raise the limit. Measured 2026-09-13: a
    // household with no co-signers raises and removes its own ceiling, signing
    // alone, and the engine accepts it. Clause 47 was amended to say so.
    expect(REFUSALS.mandate_ceiling_daily!).not.toMatch(/cannot (go through|settle) today|not today|try again tomorrow/);
    expect(REFUSALS.mandate_ceiling_daily!).toContain("while that limit stands");
    expect(REFUSALS.mandate_ceiling_daily!).not.toMatch(/no way to raise/);
    expect(REFUSALS.mandate_ceiling_daily!).toContain("you can raise it yourself");
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

/**
 * §16.5, item 4 (vault `80` §6.2 I, "proposal, decided and in cooling").
 * Whether a row can say the actual moment a decided set stops being
 * undoable, which needs the decision's own recorded moment and the
 * mandate's cooling window both in hand.
 */
describe("undoDeadline: when a decided set stops being undoable, if both facts are in hand", () => {
  test("decided_at plus the cooling window, in milliseconds", () => {
    expect(undoDeadline(1_000_000, 3_600)).toBe(1_000_000 + 3_600_000);
    expect(undoDeadline(0, 0)).toBe(0);
  });

  test("no recorded decision moment is nothing to compute, whatever the mandate says", () => {
    expect(undoDeadline(null, 3_600)).toBeNull();
    expect(undoDeadline(null, null)).toBeNull();
    expect(undoDeadline(null, undefined)).toBeNull();
  });

  test("a mandate not yet read (undefined) is told apart from one read with no cooling window (null), and both are nothing to compute", () => {
    expect(undoDeadline(1_000_000, undefined)).toBeNull();
    expect(undoDeadline(1_000_000, null)).toBeNull();
  });
});

/**
 * Item 2 (vault `80` acceptance, IOS-10, COPY-04). A decision's own `POST`
 * answer can be lost; this is what the re-read afterwards has to tell apart:
 * recorded (and what it came to), or still not decided, which is never
 * signed over a second time.
 */
describe("decisionOutcome: what a re-read says about a decision that never answered", () => {
  test("every tried candidate resolved: counted by what it resolved to", () => {
    const outcome = decisionOutcome(
      [{ candidate: "c-1", valence: "kept" }, { candidate: "c-2", valence: "returned" }],
      [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "returned" }]
    );
    expect(outcome).toEqual({ resolved: true, kept: 1, returned: 1 });
  });

  test("a candidate still `offered` means the set has not resolved, whatever the others read", () => {
    const outcome = decisionOutcome(
      [{ candidate: "c-1", valence: "kept" }, { candidate: "c-2", valence: "returned" }],
      [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "offered" }]
    );
    expect(outcome.resolved).toBe(false);
  });

  test("a candidate missing from the fresh read (offer id wrong, or read truncated) counts as unresolved, never as decided", () => {
    const outcome = decisionOutcome([{ candidate: "c-1", valence: "kept" }], []);
    expect(outcome).toEqual({ resolved: false, kept: 0, returned: 0 });
  });

  test("a candidate this set never tried to decide is not counted either way", () => {
    const outcome = decisionOutcome(
      [{ candidate: "c-1", valence: "kept" }],
      [{ id: "c-1", valence: "kept" }, { id: "c-2", valence: "consumed" }]
    );
    expect(outcome).toEqual({ resolved: true, kept: 1, returned: 0 });
  });

  test("no decisions at all is trivially resolved, with nothing kept or returned", () => {
    expect(decisionOutcome([], [{ id: "c-1", valence: "kept" }])).toEqual({ resolved: true, kept: 0, returned: 0 });
  });
});

/** D-6, D-7. The review screen's own total, before anything is signed. */
describe("decisionGoodsTotal: what signing will buy, gifts excluded, carriage apart", () => {
  const c = (over: Record<string, unknown> = {}) => ({ id: "c-1", unit_price: 1000, quantity: 1, given_by: null, ...over });

  test("a kept line's price × quantity", () => {
    expect(decisionGoodsTotal([c({ quantity: 2 })], [{ candidate: "c-1", valence: "kept" }])).toBe(2000);
  });

  test("a declined line is not counted", () => {
    expect(decisionGoodsTotal([c()], [{ candidate: "c-1", valence: "returned" }])).toBe(0);
  });

  test("a kept gift is never billed, whatever its price", () => {
    expect(decisionGoodsTotal([c({ given_by: "maker-a", unit_price: 5000 })], [{ candidate: "c-1", valence: "kept" }])).toBe(0);
  });

  test("several lines sum, and a line not in the decided set is not counted", () => {
    const candidates = [c({ id: "c-1", unit_price: 1000 }), c({ id: "c-2", unit_price: 500 }), c({ id: "c-3", unit_price: 900 })];
    const decisions: { candidate: string; valence: "kept" | "returned" }[] = [
      { candidate: "c-1", valence: "kept" },
      { candidate: "c-2", valence: "returned" },
    ];
    expect(decisionGoodsTotal(candidates, decisions)).toBe(1000);
  });
});

describe("blocksForLines", () => {
  const standing = { merchant: "maker-a", product: null, items: [{ label: "returns", value: "7 days" }] };
  const forTea = { merchant: "maker-a", product: "tea-a", items: [{ label: "returns", value: "none" }] };
  const other = { merchant: "maker-b", product: null, items: [{ label: "returns", value: "14 days" }] };
  test("a shop's standing terms appear once however many of its lines are reviewed", () => {
    const got = blocksForLines([standing, forTea, other], [
      { merchant: "maker-a", product: null },
      { merchant: "maker-a", product: "tea-a" },
      { merchant: "maker-a", product: null },
      { merchant: "maker-b", product: null },
    ]);
    expect(got.map((g) => g.block)).toEqual([standing, forTea, other]);
    expect(got.map((g) => g.scope)).toEqual(["standing", "product", "standing"]);
  });
  test("no line, no block", () => {
    expect(blocksForLines([standing], [])).toEqual([]);
  });
});
