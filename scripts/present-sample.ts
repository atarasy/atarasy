#!/usr/bin/env bun
/**
 * OPS-01. Puts one sample offer in front of a household on a local engine,
 * the way `test/hub.test.ts` seeds a presenter for the hub's own end-to-end
 * test: a signed catalogue, a signed disclosure, and an offer taken through
 * deliberation to `presented`.
 *
 * Run the engine and this hub first (see the README's "Running it locally
 * (OPS-01)"), then:
 *
 *   bun scripts/present-sample.ts <household-id-shown-on-the-page>
 *
 * The hub has to be started with `VALENCE_PRESENTERS=sample-presenter` (see
 * `PRESENTER` below) or an offer placed here never reaches its list. Open the
 * hub, decline the "not today" line, keep the other, and confirm with the
 * passkey.
 *
 * Every run publishes a fresh product, so the exploration floor (clause 26)
 * is always met for a household that has already seen an earlier run's
 * product: a presenter's novelty is counted over its whole catalogue, not
 * the offer at hand, and a household offered the same product twice has
 * nothing novel left in a one-product catalogue.
 *
 * The presenter and merchant keys are generated once and kept in
 * `.ops01/sample-presenter.json` (git-ignored) so a second run against the
 * same engine re-registers the identical key rather than a new one, which
 * the engine accepts; a different key for a name it already holds is
 * refused (`identity_exists`). Delete that file, or clear it along with the
 * rest of a reset (see the README), to start over with fresh keys.
 * `PRESENT_SAMPLE_KEY_FILE` overrides where they are kept, for a test.
 *
 * `VALENCE_ENGINE_URL` defaults to `http://localhost:8787`.
 */
import { createPrivateKey, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const ENGINE = process.env.VALENCE_ENGINE_URL ?? "http://localhost:8787";
const PRESENTER = "sample-presenter";
const MERCHANT = "sample-merchant";
// Overridable so a test can point this at a scratch file instead of the
// working tree's own `.ops01/`.
const KEY_FILE = process.env.PRESENT_SAMPLE_KEY_FILE ?? join(import.meta.dir, "..", ".ops01", "sample-presenter.json");

const household = process.argv[2];
if (!household) {
  console.error("usage: bun scripts/present-sample.ts <household-id-shown-on-the-page>");
  process.exit(1);
}
if (!household.startsWith("key:")) {
  console.error(`warning: "${household}" does not look like the household id the hub shows (it starts "key:"). Continuing anyway.`);
}

/**
 * §5.4. The bytes a catalogue is signed over, as `valence/engine/src/shared/catalogue.ts`
 * signs them. Written out here rather than imported, for the reason the hub's
 * own test writes it out: a caller that agreed with the engine by importing
 * its code would agree by accident, and this script talks to the engine over
 * plain HTTP the way any other presenter does.
 */
type Eligibility = { ambient: boolean; keeps_for_days: number; fits_ten_per_container: boolean; regulated: boolean };
type CatalogueConfig = {
  version: string;
  presenter: string;
  products: Record<string, { merchant: string; maker: string; ships: string; price: number; category?: string; physical?: Eligibility }>;
};
function canonicalConfig(c: CatalogueConfig): Buffer {
  const rows = Object.keys(c.products).sort().map((ref) => {
    const e = c.products[ref]!;
    const p = e.physical;
    return [ref, e.merchant, e.maker, e.ships, e.price, e.category ?? null,
      p ? [p.ambient, p.keeps_for_days, p.fits_ten_per_container, p.regulated] : null];
  });
  return Buffer.from(JSON.stringify(["valence.catalogue.2", c.version, c.presenter, rows]), "utf8");
}

/** §10a. The bytes a merchant signs over its disclosure block, as `shared/disclosure.ts` signs them. */
function canonicalDisclosure(d: { merchant: string; product: string | null; version: string; items: { label: string; value: string }[] }): Buffer {
  const parts = [
    encodeURIComponent(d.merchant),
    encodeURIComponent(d.version),
    encodeURIComponent(d.product ?? ""),
    ...d.items.map((i) => `${encodeURIComponent(i.label)}=${encodeURIComponent(i.value)}`),
  ];
  return Buffer.from(parts.join("\n"), "utf8");
}

type StoredKeyPair = { privateKeyPem: string; publicKeyPem: string };
type Store = { presenter: StoredKeyPair; merchant: StoredKeyPair };

function makeKeyPair(): StoredKeyPair {
  const pair = generateKeyPairSync("ed25519");
  return {
    privateKeyPem: pair.privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    publicKeyPem: pair.publicKey.export({ type: "spki", format: "pem" }).toString(),
  };
}

function loadOrCreateKeys(): Store {
  if (existsSync(KEY_FILE)) {
    return JSON.parse(readFileSync(KEY_FILE, "utf8")) as Store;
  }
  const store: Store = { presenter: makeKeyPair(), merchant: makeKeyPair() };
  mkdirSync(dirname(KEY_FILE), { recursive: true });
  writeFileSync(KEY_FILE, JSON.stringify(store, null, 2) + "\n", { mode: 0o600 });
  return store;
}

async function post(path: string, body: unknown): Promise<{ status: number; body: Record<string, unknown> }> {
  let r: Response;
  try {
    r = await fetch(`${ENGINE}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
  } catch (err) {
    throw new Error(`could not reach the engine at ${ENGINE}${path}: ${(err as Error).message}. Is it running?`);
  }
  const text = await r.text();
  return { status: r.status, body: (text ? JSON.parse(text) : {}) as Record<string, unknown> };
}

async function main() {
  const keys = loadOrCreateKeys();
  const presenterKey = createPrivateKey(keys.presenter.privateKeyPem);
  const merchantKey = createPrivateKey(keys.merchant.privateKeyPem);

  const registered = await post("/_identities", { key: PRESENTER, public_key: keys.presenter.publicKeyPem, attested: true });
  if (registered.status !== 201) throw new Error(`could not register the presenter identity: ${JSON.stringify(registered.body)}`);
  const registeredMerchant = await post("/_identities", { key: MERCHANT, public_key: keys.merchant.publicKeyPem, attested: false });
  if (registeredMerchant.status !== 201) throw new Error(`could not register the merchant identity: ${JSON.stringify(registeredMerchant.body)}`);

  // A fresh product each run: the exploration floor is met by novelty, and a
  // one-product catalogue this household has already seen has nothing left.
  const product = `sample-tea-${randomUUID().slice(0, 8)}`;
  const config: CatalogueConfig = {
    version: `cfg-sample-${Date.now()}`,
    presenter: PRESENTER,
    products: { [product]: { merchant: MERCHANT, maker: "Sample Tea Co.", ships: "sample-carrier", price: 900 } },
  };
  const configPosted = await post("/_presenter/configs", {
    ...config,
    signature: sign(null, canonicalConfig(config), presenterKey).toString("base64"),
  });
  if (configPosted.status !== 201) throw new Error(`could not publish the catalogue: ${JSON.stringify(configPosted.body)}`);

  const disclosure = {
    merchant: MERCHANT,
    product: null as string | null,
    version: `d-sample-${Date.now()}`,
    items: [
      { label: "payment", value: "charged when you confirm" },
      { label: "delivery", value: "already placed" },
      { label: "returns", value: "return what you decline; nothing to pay for it" },
    ],
  };
  const disclosed = await post("/_disclosures", {
    ...disclosure,
    signature: sign(null, canonicalDisclosure(disclosure), merchantKey).toString("base64"),
  });
  if (disclosed.status !== 201) throw new Error(`could not publish the disclosure: ${JSON.stringify(disclosed.body)}`);

  const created = await post("/offers", {
    binding: "digital",
    household,
    purpose: "trial",
    config_version: config.version,
    expires_at: Date.now() + 3_600_000,
    // Only a reference on this offer; nothing is recorded against it with
    // `/_node/mandates`, so no cooling window or ceiling applies. It does not
    // need to match the mandate reference the hub derives and shows the
    // household: that only matters for a mandate the household has actually
    // set a protection under.
    mandate: `${household}.sample`,
    price_band: null,
    giver: null,
    candidates: [{ product, quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null }],
  });
  if (created.status !== 201) throw new Error(`could not create the offer: ${JSON.stringify(created.body)}`);
  const offer = created.body as { id: string; candidates: { id: string }[] };
  const candidateId = offer.candidates[0]!.id;

  const deliberated = await post(`/offers/${offer.id}/deliberation`, {
    per_candidate: {
      [candidateId]: { alternatives: ["a smaller tin"], argument_against: "this is only here so you can see how a decline works" },
    },
    excluded: [],
    mandate: { kind: "individual", scope: "this offer", lapses_at: null },
  });
  if (deliberated.status !== 201) throw new Error(`could not record the deliberation: ${JSON.stringify(deliberated.body)}`);

  const presented = await post(`/offers/${offer.id}/present`, {});
  if (presented.status !== 200) throw new Error(`could not present the offer: ${JSON.stringify(presented.body)}`);

  console.log(`Presented offer ${offer.id} (product ${product}, ¥${config.products[product]!.price}) to ${household}.`);
  console.log(`It will appear on the hub once the hub is started with VALENCE_PRESENTERS=${PRESENTER}.`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
