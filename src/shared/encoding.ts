/** Base64 as the engine reads it, and the PEM a registered key is sent as. */

export function toBase64(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const b of view) binary += String.fromCharCode(b);
  return btoa(binary);
}

export function fromBase64(text: string): Uint8Array<ArrayBuffer> {
  const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** Unpadded base64url, which is how a credential id is kept and compared. */
export function toBase64Url(bytes: ArrayBuffer | Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * `/_identities` takes a public key as a PEM in SubjectPublicKeyInfo form,
 * which is what `PublicKeyCredential.response.getPublicKey()` returns as DER.
 * Sixty-four characters a line is what every reader of PEM expects.
 */
export function spkiToPem(der: ArrayBuffer | Uint8Array): string {
  const body = toBase64(der).match(/.{1,64}/g)?.join("\n") ?? "";
  return `-----BEGIN PUBLIC KEY-----\n${body}\n-----END PUBLIC KEY-----\n`;
}
