/**
 * Specification §10.5. The decided set in the shape that is signed, and the
 * challenge a passkey signs for it.
 *
 * This file is shared by the screen and the tests and imports nothing from
 * any implementation: a hub that agreed with the engine by importing it would
 * agree by accident. The shape is the specification's:
 *
 *   <offer id>
 *   <candidate>:<valence>:<kept_as or empty>:<lineage or empty>
 *
 * one line per decision in ascending candidate id, UTF-8, "\n" between lines.
 */
export type Decision = {
  candidate: string;
  valence: "kept" | "returned";
  kept_as?: "self" | "gift" | "order";
  lineage?: string;
};

export function canonicalDecisions(offerId: string, decisions: Decision[]): string {
  const lines = [...decisions]
    .sort((a, b) => (a.candidate < b.candidate ? -1 : a.candidate > b.candidate ? 1 : 0))
    .map((d) => `${d.candidate}:${d.valence}:${d.kept_as ?? ""}:${d.lineage ?? ""}`);
  return [offerId, ...lines].join("\n");
}

/**
 * §10.5. A passkey cannot sign bytes a caller hands it. It signs its own data
 * and the hash of the client's, and the client data carries a challenge, so
 * the decided set travels as the challenge: the SHA-256 of its canonical
 * form. The browser writes those bytes into `clientDataJSON` as unpadded
 * base64url, which is the form the engine compares against.
 */
export async function challengeFor(offerId: string, decisions: Decision[]): Promise<Uint8Array<ArrayBuffer>> {
  const bytes = new TextEncoder().encode(canonicalDecisions(offerId, decisions));
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/** §16.5. A withdrawal is bound to the exact decision generation it removes. */
export function canonicalWithdrawal(offerId: string, decidedAt: number): string {
  return ["valence.withdraw.1", offerId, String(decidedAt)].join("\n");
}

/**
 * §14.3. What a household signs to leave a host: its own identifier and the
 * host it is leaving, which is the relying party the engine behind it
 * asserts for. `hub/leave.ts` builds the same bytes from a JSON array rather
 * than the four-field shape above, and this file matches it rather than
 * importing it, for the reason every canonical form here does.
 */
export const LEAVE_DOMAIN = "valence.leave.1";

export function canonicalLeave(household: string, host: string, at: number): string {
  return JSON.stringify([LEAVE_DOMAIN, household, host, at]);
}

/** Clause 43. What a household signs to read its own export through this hub; the moment keeps a seen signature from being used later. */
export const EXPORT_DOMAIN = "valence.export.1";

export function canonicalExport(household: string, host: string, at: number): string {
  return JSON.stringify([EXPORT_DOMAIN, household, host, at]);
}

/**
 * Specification §6.5. The settlement statement a household signs before a
 * physical box with goods used is charged, in the shape that is signed:
 *
 *   valence.statement.1
 *   <offer id>
 *   <carriage>
 *   <candidate>:<valence>:<amount>:<"disputed" or empty>
 *
 * one line per kept, defaulted or consumed candidate, and per candidate the
 * collection recorded missing, in ascending candidate id, UTF-8, "\n" between
 * lines.
 *
 * **A missing line is signed as `<candidate>:lost:0:`** (question 46, decided
 * 2026-09-14), or with `disputed` where the household says the item was in
 * the box. It is never charged, and it is on the statement because it is a
 * merchant's record about the household's home that the household must be
 * able to see and contest. A candidate the deadline made `lost` is not on it.
 *
 * **The first line is a domain tag and it is not decoration.** A decided set
 * is signed over the same prefix in the same four-field shape, and the two are
 * told apart today only by the type of the third field: a future valence, or a
 * numeric `kept_as`, would make one signature verify as the other. This file
 * writes the tag because the engine does, and a hub that left it out would
 * produce signatures nothing accepts.
 */
export type StatementLine = {
  candidate: string;
  valence: "kept" | "defaulted" | "consumed" | "lost";
  amount: number;
  disputed: boolean;
};

export const STATEMENT_DOMAIN = "valence.statement.1";

export function canonicalStatement(
  offerId: string,
  /**
   * §6.5, question 40, decided 2026-09-13. The carriage the screen showed,
   * inside the bytes the passkey signs. A whole number and never null: the
   * engine refuses a statement settlement with no delivery recorded, so a
   * screen that has a statement has a figure.
   */
  carriage: number,
  lines: StatementLine[]
): string {
  const body = [...lines]
    .sort((a, b) => (a.candidate < b.candidate ? -1 : a.candidate > b.candidate ? 1 : 0))
    .map((l) => `${l.candidate}:${l.valence}:${l.amount}:${l.disputed ? "disputed" : ""}`);
  return [STATEMENT_DOMAIN, offerId, String(carriage), ...body].join("\n");
}

/** §6.5, §10.5. The challenge a passkey signs for a statement. */
export async function challengeForStatement(offerId: string, carriage: number, lines: StatementLine[]): Promise<Uint8Array<ArrayBuffer>> {
  const bytes = new TextEncoder().encode(canonicalStatement(offerId, carriage, lines));
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}
