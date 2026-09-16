import { describe, expect, test } from "bun:test";
import { createHash, createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { fromBase64, memberKeyFromHandle, newMemberKey, spkiToPem, toBase64, toBase64Url } from "../src/shared/encoding.js";

describe("what the screen sends is what the engine reads", () => {
  test("a public key in DER becomes the PEM /_identities takes", () => {
    const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const der = pair.publicKey.export({ type: "spki", format: "der" });
    const pem = spkiToPem(der);
    // Round trip through the same parser the engine uses.
    const parsed = createPublicKey(pem);
    expect(parsed.asymmetricKeyType).toBe("ec");
    expect(parsed.export({ type: "spki", format: "pem" }).toString()).toBe(pem);
  });

  test("base64 round-trips bytes, and base64url is unpadded", () => {
    const bytes = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255]);
    expect(Buffer.from(fromBase64(toBase64(bytes))).equals(Buffer.from(bytes))).toBe(true);
    expect(toBase64Url(bytes)).toBe(Buffer.from(bytes).toString("base64url"));
    expect(Buffer.from(fromBase64(toBase64Url(bytes))).equals(Buffer.from(bytes))).toBe(true);
  });

  /**
   * §13.2, question 55. The household is the name of its key, and the key is
   * in the passkey's user handle. These are the smallest cases of the two
   * things the screen does with it: make one, and get the same one back.
   */
  test("a member key names itself, and comes back from its handle", async () => {
    const made = await newMemberKey();
    expect(made.handle.length).toBe(64);
    expect(made.household).toMatch(/^key:[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/);
    expect(made.mandate.startsWith(`${made.household}.`)).toBe(true);
    // The name is the key: the same digest the engine takes of the same DER.
    expect(made.household).toBe(
      "key:" + createHash("sha256").update(createPublicKey(made.pem).export({ type: "spki", format: "der" })).digest("base64url")
    );
    const again = await memberKeyFromHandle(made.handle);
    expect([again.household, again.mandate, again.pem]).toEqual([made.household, made.mandate, made.pem]);
    // What it signs verifies against the key its name is of.
    const bytes = new TextEncoder().encode("what the person saw");
    const signature = await crypto.subtle.sign({ name: "Ed25519" }, again.key, bytes);
    expect(verify(null, Buffer.from(bytes), createPublicKey(made.pem), Buffer.from(signature))).toBe(true);
  });

  test("a handle this hub did not make is refused", async () => {
    // A length that is not 64, and two halves that do not belong together.
    // WebCrypto imports the second without complaint and it signs what its own
    // name cannot verify, so it would be a household nothing could ever use.
    const a = await newMemberKey(), b = await newMemberKey();
    const mixed = new Uint8Array(new ArrayBuffer(64));
    mixed.set(a.handle.slice(0, 32), 0);
    mixed.set(b.handle.slice(32), 32);
    await expect(memberKeyFromHandle(new Uint8Array(32))).rejects.toThrow();
    await expect(memberKeyFromHandle(mixed)).rejects.toThrow();
  });
});
