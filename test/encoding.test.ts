import { describe, expect, test } from "bun:test";
import { createPublicKey, generateKeyPairSync } from "node:crypto";
import { fromBase64, spkiToPem, toBase64, toBase64Url } from "../src/shared/encoding.js";

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
});
