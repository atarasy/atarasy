import { describe, expect, test } from "bun:test";
import { formatDay, formatDayTime, formatMoney, goodsTitle } from "../src/shared/format.js";

/**
 * Vault `80` D-1 and §6.3: what a member reads for the goods, the money and
 * the date, never a raw integer, a product reference nobody chose, or an
 * epoch. Mirrors `ios/AtarasyPrototype/MemberFormat.swift`, which this
 * module is written to agree with.
 */
describe("goodsTitle: catalogue revision 3's name and variant, or the reference before it", () => {
  test("name and variant together", () => {
    expect(goodsTitle({ name: "Oat milk", variant: "1L", product: "ref-42" })).toBe("Oat milk 1L");
  });
  test("name alone, no variant", () => {
    expect(goodsTitle({ name: "Oat milk", variant: null, product: "ref-42" })).toBe("Oat milk");
    expect(goodsTitle({ name: "Oat milk", product: "ref-42" })).toBe("Oat milk");
  });
  test("no name falls back to the merchant's own product reference", () => {
    expect(goodsTitle({ name: null, variant: "1L", product: "ref-42" })).toBe("ref-42");
    expect(goodsTitle({ product: "ref-42" })).toBe("ref-42");
  });
  test("an empty name is not a name", () => {
    expect(goodsTitle({ name: "", variant: "1L", product: "ref-42" })).toBe("ref-42");
  });
});

describe("formatMoney: grouped, no decimal places, the host's currency", () => {
  test("JPY groups thousands and carries the yen sign, with no decimal places", () => {
    expect(formatMoney(1500, "JPY", "en-US")).toBe("¥1,500");
    expect(formatMoney(0, "JPY", "en-US")).toBe("¥0");
    expect(formatMoney(1_000_000, "JPY", "en-US")).toBe("¥1,000,000");
  });
  test("the currency defaults to JPY when none is given", () => {
    expect(formatMoney(1500, undefined, "en-US")).toBe("¥1,500");
  });
  test("a different configured currency is honoured", () => {
    expect(formatMoney(1500, "USD", "en-US")).toBe("$1,500");
  });
});

describe("formatDay and formatDayTime: a day a member can read, never an epoch", () => {
  // 2026-10-02T00:00:00Z is a Friday; fixed to one locale so the assertion
  // does not depend on the machine running the suite.
  const fri = Date.UTC(2026, 9, 2, 0, 0, 0);
  test("formatDay names the weekday, the day and the month", () => {
    const s = formatDay(fri, "en-US");
    expect(s).toContain("Oct");
    expect(s).toContain("2");
  });
  test("formatDayTime adds a clock time beside the same day", () => {
    const day = formatDay(fri, "en-US");
    const dayTime = formatDayTime(fri, "en-US");
    expect(dayTime.startsWith(day.split(",")[0]!)).toBe(true);
    expect(dayTime).not.toBe(day);
  });
});
