/**
 * §16. A mandate is the person's standing protections, and §16.1 says who has
 * to sign a change to it: a tightening is theirs alone, a loosening needs
 * every co-signer the previous version named (clause 47).
 *
 * The canonical form is written here rather than imported from an engine, for
 * the reason the decided set's is: a hub that agreed with an engine by
 * importing its code would agree by accident, and a second implementation
 * would have nothing to check against. The order of the fields is the record's
 * own, and the three protections added on 2026-09-10 sit inside it rather than
 * at the end, so an older signature does not verify against a newer form.
 */
export type Mandate = {
  id: string;
  household: string;
  /** Clause 46. What one offer may cost at merchants the registry does not list. */
  ceiling_out_of_network: number;
  /** §16.3. What may settle for this household in one day, across every presenter. */
  ceiling_daily: number | null;
  /** §16.5. How long a decided set waits before it can settle, and can be taken back. */
  cooling_seconds: number | null;
  /** Clause 47. Keys named while the person had capacity. */
  co_signers: string[];
  /** Clause 58. A standing mandate lapses unless renewed. */
  lapses_at: number;
  version: number;
};

/** Absent is not zero: an empty line is no ceiling and no cooling. */
const optional = (v: number | null | undefined) => (v === null || v === undefined ? "" : String(v));

export function canonicalMandate(m: Mandate): string {
  return [
    m.id,
    m.household,
    String(m.ceiling_out_of_network),
    optional(m.ceiling_daily),
    optional(m.cooling_seconds),
    // Each item is escaped before the join (§16.1). A plain comma join is
    // malleable: `["a","b"]` and `["a,b"]` are the same bytes, so whoever
    // relays a change can fuse two co-signers into a name nobody holds, after
    // which no loosening can ever be signed, and the signature still verifies.
    [...m.co_signers].sort().map(encodeURIComponent).join(","),
    String(m.lapses_at),
    String(m.version),
  ].join("\n");
}

/**
 * §16.1. Whether a change is a loosening, which is the question that decides
 * whose signatures it needs. A tightening is the person's alone.
 *
 * Every protection has a direction: a lower ceiling is tighter, a longer
 * cooling window is tighter, another co-signer is tighter, and a later lapse
 * is looser. Removing a protection is the loosest
 * move there is, which is why absent counts as the weakest value here rather
 * than as zero.
 */
export function loosens(before: Mandate, after: Mandate): boolean {
  const weaker = (b: number | null, a: number | null) =>
    b !== null && (a === null || a > b);
  if (weaker(before.ceiling_daily, after.ceiling_daily)) return true;
  if (weaker(before.cooling_seconds === null ? null : -before.cooling_seconds,
             after.cooling_seconds === null ? null : -after.cooling_seconds)) return true;
  if (after.ceiling_out_of_network > before.ceiling_out_of_network) return true;
  if (after.lapses_at > before.lapses_at) return true;
  for (const k of before.co_signers) {
    if (!after.co_signers.includes(k)) return true;
  }
  return false;
}
