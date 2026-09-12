import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { canonicalDecisions, canonicalStatement, challengeFor, challengeForStatement, STATEMENT_DOMAIN } from "../src/shared/canonical.js";

describe("§10.5: the canonical form of a decided set", () => {
  test("is the offer id, then one line per decision in ascending candidate id", () => {
    const text = canonicalDecisions("offer-1", [
      { candidate: "c-2", valence: "returned" },
      { candidate: "c-1", valence: "kept", kept_as: "self" },
    ]);
    expect(text).toBe("offer-1\nc-1:kept:self:\nc-2:returned::");
  });

  test("an absent kept_as and lineage are empty fields, not missing ones", () => {
    expect(canonicalDecisions("o", [{ candidate: "a", valence: "returned" }])).toBe("o\na:returned::");
    expect(canonicalDecisions("o", [{ candidate: "a", valence: "kept", kept_as: "gift", lineage: "e-1" }])).toBe("o\na:kept:gift:e-1");
  });

  test("the challenge is the SHA-256 of that form, and nothing random", async () => {
    const decisions = [{ candidate: "c-1", valence: "kept" as const, kept_as: "self" as const }];
    const challenge = await challengeFor("offer-1", decisions);
    const expected = createHash("sha256").update(canonicalDecisions("offer-1", decisions), "utf8").digest();
    expect(Buffer.from(challenge).equals(expected)).toBe(true);
    // A browser writes the challenge into clientDataJSON as unpadded base64url,
    // which is the string the engine compares against.
    expect(Buffer.from(challenge).toString("base64url")).toBe(expected.toString("base64url"));
  });
});

/**
 * §6.5. The same rule, for the form a household signs a physical settlement
 * in. `CLAUDE.md` says this file pins the shape and it pinned only the decided
 * set: the statement's form was written on 2026-09-12 and nothing here asked
 * about it for a day, so a drift in the hub's copy would have produced
 * signatures the engine rejects with nothing saying which side had moved.
 * Found by a refutation pass over this hub.
 */
describe("§6.5: the canonical form of a settlement statement", () => {
  test("is the domain tag, the offer id, then one line per line in ascending candidate id", () => {
    const text = canonicalStatement("offer-1", 500, [
      { candidate: "c-2", valence: "consumed", amount: 900, disputed: true },
      { candidate: "c-1", valence: "kept", amount: 0, disputed: false },
    ]);
    expect(text).toBe("valence.statement.1\noffer-1\n500\nc-1:kept:0:\nc-2:consumed:900:disputed");
  });

  test("the domain tag is the first line and is what keeps it from verifying as a decided set", () => {
    // A decided set is `<offer id>` then `<candidate>:<valence>:<kept_as>:<lineage>`,
    // the same prefix and the same four fields. The tag costs one line and
    // cannot be added once signatures are in the wild.
    expect(STATEMENT_DOMAIN).toBe("valence.statement.1");
    expect(canonicalStatement("o", 0, []).split("\n")[0]).toBe(STATEMENT_DOMAIN);
    expect(canonicalDecisions("o", [{ candidate: "a", valence: "returned" }]).startsWith(STATEMENT_DOMAIN)).toBe(false);
  });

  test("a gift is zero and an undisputed line's fourth field is empty, not missing", () => {
    // §6.5, question 40. The carriage is a whole number and never null here,
    // because the engine refuses a statement settlement with no delivery
    // recorded, and a price that includes carriage records zero.
    expect(canonicalStatement("o", 0, [{ candidate: "a", valence: "kept", amount: 0, disputed: false }]))
      .toBe("valence.statement.1\no\n0\na:kept:0:");
  });

  test("the challenge is the SHA-256 of that form, and nothing random", async () => {
    const lines = [{ candidate: "c-1", valence: "consumed" as const, amount: 1500, disputed: false }];
    const challenge = await challengeForStatement("offer-1", 500, lines);
    const expected = createHash("sha256").update(canonicalStatement("offer-1", 500, lines), "utf8").digest();
    expect(Buffer.from(challenge).equals(expected)).toBe(true);
    expect(Buffer.from(challenge).toString("base64url")).toBe(expected.toString("base64url"));
  });
});
