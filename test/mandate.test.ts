import { describe, expect, test } from "bun:test";
import { canonicalMandate, loosens, type Mandate } from "../src/shared/mandate.js";

const base: Mandate = {
  // §13.2, question 55. A household is the name of its key, a mandate that with a label.
  id: "key:L7zIqTWzxcxLB9T_L9Z--Rewkt-8DAkgRYtgcIIsC-E.x",
  household: "key:L7zIqTWzxcxLB9T_L9Z--Rewkt-8DAkgRYtgcIIsC-E",
  ceiling_out_of_network: 100000,
  ceiling_daily: null,
  cooling_seconds: null,
  co_signers: ["key-a"],
  lapses_at: 1_800_000_000_000,
  version: 1,
};

describe("§16.1: the bytes a mandate version is signed over", () => {
  test("the record's own order, with the two protections inside it", () => {
    // Seven lines since 2026-09-12, when §16.4 was withdrawn and the category
    // list left the form. There were eight. Question 58 put the form's name
    // and the host in front of them on 2026-09-19.
    expect(canonicalMandate(base, "hub.example")).toBe(
      ["valence.mandate.2", "hub.example", "key:L7zIqTWzxcxLB9T_L9Z--Rewkt-8DAkgRYtgcIIsC-E.x", "key:L7zIqTWzxcxLB9T_L9Z--Rewkt-8DAkgRYtgcIIsC-E", "100000", "", "", "key-a", "1800000000000", "1"].join("\n")
    );
  });

  test("absent is an empty line and not a zero", () => {
    // A daily ceiling of 0 would refuse everything; no daily ceiling refuses
    // nothing. The signed bytes have to tell them apart.
    const none = canonicalMandate({ ...base, ceiling_daily: null }, "hub.example");
    const zero = canonicalMandate({ ...base, ceiling_daily: 0 }, "hub.example");
    expect(none).not.toBe(zero);
    expect(zero.split("\n")[5]).toBe("0");
    expect(none.split("\n")[5]).toBe("");
  });

  test("an item that contains a comma cannot pass for two (§16.1)", () => {
    // Found by an adversarial pass on 2026-09-11: with a plain join the
    // person could sign two co-signers and a relay post one, under the same
    // signature, after which no loosening could ever be signed. It read the
    // category list until §16.4 was withdrawn; the defect was on both.
    const two = canonicalMandate({ ...base, co_signers: ["key-a", "key-b"] }, "hub.example");
    const one = canonicalMandate({ ...base, co_signers: ["key-a,key-b"] }, "hub.example");
    expect(two).not.toBe(one);
  });

  test("the list is sorted, so the same mandate signs the same bytes", () => {
    const one = canonicalMandate({ ...base, co_signers: ["b", "a"] }, "hub.example");
    const other = canonicalMandate({ ...base, co_signers: ["a", "b"] }, "hub.example");
    expect(one).toBe(other);
  });

  test("the host is inside the bytes, so a version signed for one host is not one signed for another (question 58)", () => {
    expect(canonicalMandate(base, "hub.example")).not.toBe(canonicalMandate(base, "other.example"));
  });
});

describe("§16.1, clause 47: a tightening is the person's alone", () => {
  const tighter: [string, Partial<Mandate>][] = [
    ["a daily ceiling where there was none", { ceiling_daily: 5000 }],
    ["a lower daily ceiling", { ceiling_daily: 5000 }],
    ["a cooling window where there was none", { cooling_seconds: 3600 }],
    ["a lower out-of-network ceiling", { ceiling_out_of_network: 1000 }],
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
    ["dropping a co-signer", base, { co_signers: [] }],
    // Question 68: an earlier lapse removes the co-signers' protection sooner.
    ["an earlier lapse where a co-signer is named", base, { lapses_at: base.lapses_at - 1 }],
  ];
  for (const [what, from, over] of looser) {
    test(`${what} is a loosening`, () => {
      expect(loosens(from, { ...from, ...over, version: from.version + 1 })).toBe(true);
    });
  }

  test("an earlier lapse is a tightening where nobody is named (question 68)", () => {
    const alone = { ...base, co_signers: [] };
    expect(loosens(alone, { ...alone, lapses_at: alone.lapses_at - 1, version: 2 })).toBe(false);
  });

  test("no change is not a loosening", () => {
    expect(loosens(base, { ...base, version: 2 })).toBe(false);
  });
});
