import { describe, expect, test } from "bun:test";
import { COPY_KEYS, pickLanguage, t } from "../src/client/copy.js";

/**
 * Vault `80` D-5: the language is picked from `navigator.language`, and every
 * screen element with an iOS counterpart carries that app's own English and
 * Japanese, copied verbatim rather than re-translated. This suite is the
 * completeness check that comment asks for: every key resolves in both
 * languages, and no entry is empty in the one that matters most for a
 * lookup table like this, the translation.
 */
describe("pickLanguage: navigator.language decides, nothing else does", () => {
  test("a ja* tag is Japanese, whatever region it carries", () => {
    expect(pickLanguage("ja")).toBe("ja");
    expect(pickLanguage("ja-JP")).toBe("ja");
    expect(pickLanguage("JA-jp")).toBe("ja");
  });
  test("anything else, including a language this dictionary has no rows for, is English", () => {
    expect(pickLanguage("en")).toBe("en");
    expect(pickLanguage("en-US")).toBe("en");
    expect(pickLanguage("fr")).toBe("en");
    expect(pickLanguage("")).toBe("en");
  });
});

describe("t: looks up a key, substitutes its placeholders, and never throws on an unknown one", () => {
  test("English is the key itself when unfilled", () => {
    expect(t("en", "Inbox")).toBe("Inbox");
  });
  test("Japanese resolves to the iOS app's own translation", () => {
    expect(t("ja", "Inbox")).toBe("届いたもの");
    expect(t("ja", "Keep")).toBe("受け取る");
    expect(t("ja", "Decline")).toBe("見送る");
  });
  test("a key with no Japanese row falls back to the English key rather than throwing", () => {
    expect(t("ja", "A sentence nobody has translated")).toBe("A sentence nobody has translated");
  });
  test("%@ is substituted left to right, in both languages", () => {
    expect(t("en", "Sold by %@", "Meiji")).toBe("Sold by Meiji");
    expect(t("ja", "Sold by %@", "Meiji")).toBe("販売: Meiji");
  });
  test("an indexed placeholder (%2$lld, %1$lld) is filled by its own index, not by arrival order", () => {
    expect(t("ja", "Choose Keep or Decline for each item (%lld of %lld).", 1, 3)).toBe(
      "品目ごとに「受け取る」か「見送る」を選んでください（3 点中 1 点）。"
    );
  });
});

describe("completeness: every key in the table resolves to a non-empty string in both languages", () => {
  test("no key is missing its Japanese, and none is empty", () => {
    // "Atarasy" is the brand name and is the same string in both languages;
    // every other key is expected to differ from its own English spelling.
    const sameInBothLanguages = new Set(["Atarasy"]);
    const missing: string[] = [];
    for (const key of COPY_KEYS) {
      const ja = t("ja", key);
      if (!ja || (ja === key && !sameInBothLanguages.has(key))) missing.push(key);
    }
    expect(missing).toEqual([]);
  });
  test("the table carries every string this redesign leans on", () => {
    for (const key of [
      "Inbox", "Limits", "Account", "At home", "Proposals", "Keep", "Decline",
      "Sign with passkey", "Review and sign", "Check result", "Sold by %@", "Made by %@",
      "Gift from %@", "Free", "Not charged", "Delete account", "About this account",
    ]) {
      expect(COPY_KEYS).toContain(key);
    }
  });
});
