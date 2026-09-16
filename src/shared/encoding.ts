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

/**
 * §13.2, question 55, decided 2026-09-16. A household's identifier is `key:`
 * and the base64url SHA-256 of its public key in SubjectPublicKeyInfo DER.
 */
export async function householdName(spki: ArrayBuffer | Uint8Array): Promise<string> {
  const der = spki instanceof Uint8Array ? spki : new Uint8Array(spki);
  return "key:" + toBase64Url(await crypto.subtle.digest("SHA-256", der as unknown as BufferSource));
}

/**
 * §13.2, §16.1. The key a household signs with, carried inside the passkey.
 *
 * **The name is the key, so the name cannot come from the credential id any
 * more.** It used to: both names were the id's, which made them unguessable
 * and nothing more, and a stranger who learnt one from an offer could take it
 * at the next host. A `get` hands back the credential id and never the public
 * key, so a member arriving on a second device has to find the key some other
 * way, and the way is the passkey's own user handle: 32 bytes of private
 * scalar and 32 of public, set when the credential was made and returned by
 * every later assertion.
 *
 * **What it costs is that the signing key is no longer the authenticator's.**
 * The authenticator holds the handle and releases it only after the person
 * verifies, so the gesture before every signature is the one it always was,
 * and the reference discards the key as soon as it has signed. A page that
 * did not discard it could sign again later without asking, which an
 * assertion never allowed. Chosen on 2026-09-16 over a hub that remembers its
 * members and over a person who carries 47 characters.
 */
export type MemberKey = { handle: Uint8Array<ArrayBuffer>; key: CryptoKey; pem: string; household: string; mandate: string };

const ED = { name: "Ed25519" };

async function fromParts(d: string, x: string): Promise<MemberKey> {
  const key = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", d, x, key_ops: ["sign"], ext: false }, ED, false, ["sign"]);
  const pub = await crypto.subtle.importKey("jwk", { kty: "OKP", crv: "Ed25519", x, key_ops: ["verify"], ext: true }, ED, true, ["verify"]);
  const spki = await crypto.subtle.exportKey("spki", pub);
  const handle = new Uint8Array(new ArrayBuffer(64));
  handle.set(fromBase64(d), 0);
  handle.set(fromBase64(x), 32);
  // **The two halves of a handle are not checked against each other by
  // WebCrypto.** Measured on 2026-09-16: a private scalar and an unrelated
  // public key import without complaint and sign what that public key cannot
  // verify. The household is the name of `x` and the signature is made by
  // `d`, so a handle whose halves do not belong together is a household
  // nothing can ever sign for. One signature and one verification say so
  // here, where it costs a member nothing and saves them a household that
  // does not work.
  const probe = new Uint8Array([0]);
  if (!(await crypto.subtle.verify(ED, pub, await crypto.subtle.sign(ED, key, probe as unknown as BufferSource), probe as unknown as BufferSource))) {
    throw new Error("this passkey carries a household nothing can sign for");
  }
  const household = await householdName(spki);
  // §13.2, question 55. A mandate identifier is still a bearer reference for
  // reading `GET /_node/mandates/{id}` until question 41's authenticated read
  // exists, and that section asks a hub to choose a label with as much entropy
  // as the identifier it hangs from. A label of `.1` would hand a household's
  // ceilings and co-signers to anyone who learnt its household's name, so the
  // label is derived from the public half instead. **What that defends against
  // is a party that knows the name and nothing else.** Every host that verifies
  // this household holds the public key (§13.2), and the whole mandate
  // identifier is on every offer `valence-merchant/1` hands a merchant, so it
  // defends against neither of those. Said plainly after a review pass read the
  // first version of this comment as claiming more.
  const label = toBase64Url(await crypto.subtle.digest("SHA-256", fromBase64(x) as unknown as BufferSource)).slice(0, 32);
  return { handle, key, pem: spkiToPem(spki), household, mandate: `${household}.${label}` };
}

/** A new household: a key, and the 64-byte handle the passkey will carry for it. */
export async function newMemberKey(): Promise<MemberKey> {
  // Ed25519 reached WebCrypto in Safari 17, Chrome 137 and Firefox 130. A
  // browser without it throws a `NotSupportedError` whose message says
  // nothing a member can act on, so it says it here instead. There is no
  // fallback: the key has to be one the engine verifies and one this browser
  // can rebuild from the handle, and a curve the authenticator chose is not
  // the second.
  let pair: CryptoKeyPair;
  try {
    pair = (await crypto.subtle.generateKey(ED, true, ["sign", "verify"])) as CryptoKeyPair;
  } catch {
    throw new Error("This browser cannot make the kind of key a household is named by. Recent Safari, Chrome and Firefox can; open this page in one of them.");
  }
  const jwk = (await crypto.subtle.exportKey("jwk", pair.privateKey)) as { d?: string; x?: string };
  if (!jwk.d || !jwk.x) throw new Error("this browser does not hand out the parts of a new key");
  return fromParts(jwk.d, jwk.x);
}

/** The same household again, from the handle an assertion returned. */
export async function memberKeyFromHandle(handle: ArrayBuffer | Uint8Array): Promise<MemberKey> {
  const bytes = handle instanceof Uint8Array ? handle : new Uint8Array(handle);
  if (bytes.length !== 64) throw new Error("this passkey was not made by this hub");
  return fromParts(toBase64Url(bytes.slice(0, 32)), toBase64Url(bytes.slice(32)));
}
