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
