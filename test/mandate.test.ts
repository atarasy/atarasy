import { describe, expect, test } from "bun:test";
import { canonicalMandate, loosens, type Mandate } from "../src/shared/mandate.js";

const base: Mandate = {
  id: "mandate-x",
  household: "household-x",
  ceiling_out_of_network: 100000,
  ceiling_daily: null,
  co_sign_categories: [],
  cooling_seconds: null,
  co_signers: ["key-a"],
  lapses_at: 1_800_000_000_000,
  version: 1,
};

describe("§16.1: the bytes a mandate version is signed over", () => {
  test("the record's own order, with the three protections inside it", () => {
    expect(canonicalMandate(base)).toBe(
      ["mandate-x", "household-x", "100000", "", "", "", "key-a", "1800000000000", "1"].join("\n")
    );
  });

  test("absent is an empty line and not a zero", () => {
    // A daily ceiling of 0 would refuse everything; no daily ceiling refuses
    // nothing. The signed bytes have to tell them apart.
    const none = canonicalMandate({ ...base, ceiling_daily: null });
    const zero = canonicalMandate({ ...base, ceiling_daily: 0 });
    expect(none).not.toBe(zero);
    expect(zero.split("\n")[3]).toBe("0");
    expect(none.split("\n")[3]).toBe("");
  });

  test("an item that contains a comma cannot pass for two (§16.1)", () => {
    // Found by an adversarial pass on 2026-09-11: with a plain join the
    // person could sign two categories and a relay post one, under the same
    // signature, and the protection the second category carried was gone.
    const two = canonicalMandate({ ...base, co_sign_categories: ["coffee", "tea"] });
    const one = canonicalMandate({ ...base, co_sign_categories: ["coffee,tea"] });
    expect(two).not.toBe(one);
  });

  test("the lists are sorted, so the same mandate signs the same bytes", () => {
    const one = canonicalMandate({ ...base, co_signers: ["b", "a"], co_sign_categories: ["tea", "coffee"] });
    const other = canonicalMandate({ ...base, co_signers: ["a", "b"], co_sign_categories: ["coffee", "tea"] });
    expect(one).toBe(other);
  });
});

describe("§16.1, clause 47: a tightening is the person's alone", () => {
  const tighter: [string, Partial<Mandate>][] = [
    ["a daily ceiling where there was none", { ceiling_daily: 5000 }],
    ["a lower daily ceiling", { ceiling_daily: 5000 }],
    ["a cooling window where there was none", { cooling_seconds: 3600 }],
    ["a lower out-of-network ceiling", { ceiling_out_of_network: 1000 }],
    ["an earlier lapse", { lapses_at: base.lapses_at - 1 }],
    ["a category that needs a second signature", { co_sign_categories: ["tea"] }],
    ["another co-signer", { co_signers: ["key-a", "key-b"] }],
  ];
  for (const [what, over] of tighter) {
    test(`${what} is a tightening`, () => {
      expect(loosens(base, { ...base, ...over, version: base.version + 1 })).toBe(false);
    });
  }

  const looser: [string, Mandate, Partial<Mandate>][] = [
    ["removing a daily ceiling", { ...base, ceiling_daily: 5000 }, { ceiling_daily: null }],
    ["raising a daily ceiling", { ...base, ceiling_daily: 5000 }, { ceiling_daily: 6000 }],
    ["removing a cooling window", { ...base, cooling_seconds: 3600 }, { cooling_seconds: null }],
    ["shortening a cooling window", { ...base, cooling_seconds: 3600 }, { cooling_seconds: 60 }],
    ["raising the out-of-network ceiling", base, { ceiling_out_of_network: 200000 }],
    ["a later lapse", base, { lapses_at: base.lapses_at + 1 }],
    ["dropping a category", { ...base, co_sign_categories: ["tea"] }, { co_sign_categories: [] }],
    ["dropping a co-signer", base, { co_signers: [] }],
  ];
  for (const [what, from, over] of looser) {
    test(`${what} is a loosening`, () => {
      expect(loosens(from, { ...from, ...over, version: from.version + 1 })).toBe(true);
    });
  }

  test("no change is not a loosening", () => {
    expect(loosens(base, { ...base, version: 2 })).toBe(false);
  });
});
