import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { canonicalDecisions, challengeFor } from "../src/shared/canonical.js";

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
