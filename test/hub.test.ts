/**
 * The hub against a running engine, end to end but for the browser.
 *
 * The engine is the reference at VALENCE_ENGINE_DIR (default: the valence
 * checkout beside this repository). The test seeds it the way a deployment
 * would, starts the hub against it, and then does what the screen does: lists
 * the offers waiting, reads the approval, registers a P-256 key and confirms
 * a decided set with an assertion built the way an authenticator builds one.
 * What it cannot do is press the button; everything after the button is here.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash, generateKeyPairSync, sign, type KeyPairKeyObjectResult } from "node:crypto";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { canonicalDecisions, challengeFor, type Decision } from "../src/shared/canonical.js";
import { canonicalMandate } from "../src/shared/mandate.js";
import { spkiToPem, toBase64 } from "../src/shared/encoding.js";

const ENGINE_DIR = resolve(process.env.VALENCE_ENGINE_DIR ?? join(import.meta.dir, "..", "..", "valence", "engine"));
const ENGINE_PORT = Number(process.env.ENGINE_PORT ?? 9700);
const HUB_PORT = Number(process.env.HUB_PORT ?? 9701);
const ENGINE = `http://localhost:${ENGINE_PORT}`;
const HUB = `http://localhost:${HUB_PORT}`;
const RP = "localhost";
const PRESENTER = "reference-merchant";
/**
 * The two names the screen derives from a credential id, in the shape the hub
 * requires. A guessable one is a name somebody else can register first, and
 * the household's own name is the one that signs its protections (§16.1).
 */
const CREDENTIAL = Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64url");
const HOUSEHOLD = `household-${CREDENTIAL}`;
const MANDATE = `mandate-${CREDENTIAL}`;

/**
 * A child process inherits PATH and what this test sets, and nothing of the
 * operator's shell: a stray VALENCE_ROLES, VALENCE_DB or METER_BASE_URL would
 * quietly change what is being measured.
 */
function childEnv(extra: Record<string, string>): Record<string, string> {
  const base: Record<string, string> = {};
  for (const key of ["PATH", "HOME", "TMPDIR", "LANG"]) {
    const value = process.env[key];
    if (value) base[key] = value;
  }
  return { ...base, ...extra };
}

if (!existsSync(join(ENGINE_DIR, "src", "server.ts"))) {
  throw new Error(`no engine at ${ENGINE_DIR}. Set VALENCE_ENGINE_DIR to a checkout of atarasy/valence's engine/.`);
}

let engineProc: ReturnType<typeof Bun.spawn> | undefined;
let hubProc: ReturnType<typeof Bun.spawn> | undefined;

async function until(url: string) {
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(url);
      if (r.status < 500) return;
    } catch {}
    await Bun.sleep(100);
  }
  throw new Error(`${url} never answered`);
}

async function post(base: string, path: string, body: unknown) {
  const r = await fetch(`${base}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "user-agent": "atarasy-test/0.0.0" },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  return { status: r.status, body: (text ? JSON.parse(text) : {}) as Record<string, unknown> };
}

/** §5.4. The bytes a catalogue is signed over; deployment plumbing, not the hub's. */
/**
 * The catalogue's canonical form, as the engine signs it.
 *
 * **Written out here rather than imported**, for the reason every shared form
 * in this repository is: a hub that agreed with the engine by importing its
 * code would agree by accident. Two things changed on 2026-09-12 and this file
 * followed neither until the same evening, so every test here had been red
 * since: the `maker` joined the signed bytes (question 32), and each part is
 * percent-encoded before the join, because a merchant named "a:b" with a maker
 * "c" produced the same bytes as a merchant "a" with a maker "b:c".
 */
/**
 * §5.4, catalogue signature revision 2 (`valence.catalogue.2`), which binds
 * the physical eligibility into the signed bytes. The engine refuses the
 * earlier line form with `422`, which left every case in this file red.
 */
type Eligibility = { ambient: boolean; keeps_for_days: number; fits_ten_per_container: boolean; regulated: boolean };
function canonicalConfig(c: { version: string; presenter: string; products: Record<string, { merchant: string; maker: string; ships: string; price: number; category?: string; physical?: Eligibility }> }) {
  const rows = Object.keys(c.products).sort().map((ref) => {
    const e = c.products[ref]!;
    const p = e.physical;
    return [ref, e.merchant, e.maker, e.ships, e.price, e.category ?? null,
      p ? [p.ambient, p.keeps_for_days, p.fits_ten_per_container, p.regulated] : null];
  });
  return Buffer.from(JSON.stringify(["valence.catalogue.2", c.version, c.presenter, rows]), "utf8");
}

/**
 * §10a. The bytes a merchant signs over its block, as the engine signs them.
 * Written out here for the same reason the catalogue's form is: a hub that
 * agreed with the engine by importing its code would agree by accident. The
 * product is the third part, empty for the merchant's standing text, so a
 * block signed for one product cannot be re-filed under another.
 */
function canonicalDisclosure(d: { merchant: string; product: string | null; version: string; items: { label: string; value: string }[] }) {
  return Buffer.from(
    [
      encodeURIComponent(d.merchant),
      encodeURIComponent(d.version),
      encodeURIComponent(d.product ?? ""),
      ...d.items.map((i) => `${encodeURIComponent(i.label)}=${encodeURIComponent(i.value)}`),
    ].join("\n"),
    "utf8"
  );
}

let offerId = "";
let candidateIds: string[] = [];

/**
 * What the browser's authenticator produces, in the shape §10.5 and §16.1 both
 * take: it signs its own data and the SHA-256 of the client's, and the client
 * data carries the challenge, which is the canonical bytes' hash.
 */
function assertOver(canonical: string) {
  const challenge = createHash("sha256").update(canonical, "utf8").digest("base64url");
  const authenticatorData = Buffer.concat([
    createHash("sha256").update(RP).digest(),
    Buffer.from([0x05]),
    Buffer.from([0, 0, 0, 1]),
  ]);
  const clientDataJson = Buffer.from(
    JSON.stringify({ type: "webauthn.get", challenge, origin: `http://${RP}:${HUB_PORT}` }),
    "utf8"
  );
  const signed = Buffer.concat([authenticatorData, createHash("sha256").update(clientDataJson).digest()]);
  return {
    authenticator_data: toBase64(authenticatorData),
    client_data_json: toBase64(clientDataJson),
    signature: toBase64(sign("sha256", signed, memberKey!.privateKey)),
  };
}

/** An offer this household can decide on: created, deliberated, presented. */
async function placed(product = "tea-b"): Promise<{ id: string; candidates: { id: string }[] }> {
  const created = await post(ENGINE, "/offers", {
    binding: "digital",
    household: HOUSEHOLD,
    purpose: "replenish",
    config_version: "cfg-hub-test",
    expires_at: Date.now() + 3_600_000,
    mandate: MANDATE,
    price_band: null,
    giver: null,
    candidates: [{ product, quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null }],
  });
  expect(created.status).toBe(201);
  const offer = created.body as unknown as { id: string; candidates: { id: string }[] };
  const per: Record<string, unknown> = {};
  for (const c of offer.candidates) per[c.id] = { alternatives: ["a smaller tin"], argument_against: "you have some already" };
  expect((await post(ENGINE, `/offers/${offer.id}/deliberation`, {
    per_candidate: per,
    excluded: [],
    mandate: { kind: "standing", scope: "tea", lapses_at: Date.now() + 90 * 86_400_000 },
  })).status).toBe(201);
  expect((await post(ENGINE, `/offers/${offer.id}/present`, {})).status).toBe(200);
  return offer;
}

beforeAll(async () => {
  engineProc = Bun.spawn(["bun", "src/server.ts"], {
    cwd: ENGINE_DIR,
    env: childEnv({ PORT: String(ENGINE_PORT), VALENCE_EXPLORATION_RATE: "0.2", VALENCE_RECOVERY_GRACE_DAYS: "0", VALENCE_RP_ID: RP }),
    stdout: "ignore",
    stderr: "inherit",
  });
  await until(`${ENGINE}/offers?household=probe&presenter=probe`);

  // A presenter with a signed catalogue, as a deployment seeds one.
  const presenterKey = generateKeyPairSync("ed25519");
  expect((await post(ENGINE, "/_identities", {
    key: PRESENTER,
    public_key: presenterKey.publicKey.export({ type: "spki", format: "pem" }).toString(),
    attested: true,
  })).status).toBe(201);
  // §11.1. Ambient, long-keeping, ten to a container, unregulated: the band
  // the physical binding can carry. It is not in the catalogue's signed bytes,
  // so it travels beside them.
  const PHYSICAL = { ambient: true, keeps_for_days: 365, fits_ten_per_container: true, regulated: false };
  const config = {
    version: "cfg-hub-test",
    presenter: PRESENTER,
    products: {
      "tea-a": { merchant: "maker-a", maker: "made-by-tea", ships: "carrier-a", price: 1200 , physical: PHYSICAL },
      "tea-b": { merchant: "maker-a", maker: "made-by-tea", ships: "carrier-a", price: 900 , physical: PHYSICAL },
      // A third product so that a test needing an offer of its own has one the
      // exploration floor will accept: a candidate counts as exploration
      // because this household has never been offered it.
      "tea-c": { merchant: "maker-a", maker: "made-by-tea", ships: "carrier-a", price: 700 , physical: PHYSICAL },
      "coffee-a": { merchant: "maker-a", maker: "made-by-coffee", ships: "carrier-a", price: 1500 , physical: PHYSICAL },
    },
  };
  expect((await post(ENGINE, "/_presenter/configs", {
    ...config,
    signature: sign(null, canonicalConfig(config), presenterKey.privateKey).toString("base64"),
  })).status).toBe(201);

  // §10a. Every merchant named on a candidate has a block it composed and
  // signed, and since 2026-09-12 an offer without one is refused at `present`
  // rather than at the decision. **Nothing here is a statute's list**: the
  // engine reads no item, and a fixture that pretended otherwise would assert
  // something no code can check.
  const merchantKey = generateKeyPairSync("ed25519");
  expect((await post(ENGINE, "/_identities", {
    key: "maker-a",
    public_key: merchantKey.publicKey.export({ type: "spki", format: "pem" }).toString(),
    attested: false,
  })).status).toBe(201);
  const block = {
    merchant: "maker-a",
    product: null as string | null,
    version: "d-hub-1",
    items: [
      { label: "payment", value: "charged when you confirm" },
      { label: "delivery", value: "already placed" },
      { label: "returns", value: "as this merchant published" },
    ],
  };
  expect((await post(ENGINE, "/_disclosures", {
    ...block,
    signature: sign(null, canonicalDisclosure(block), merchantKey.privateKey).toString("base64"),
  })).status).toBe(201);

  hubProc = Bun.spawn(["bun", "src/server.ts"], {
    cwd: join(import.meta.dir, ".."),
    env: childEnv({ PORT: String(HUB_PORT), VALENCE_ENGINE_URL: ENGINE, VALENCE_PRESENTERS: PRESENTER }),
    stdout: "ignore",
    stderr: "inherit",
  });
  await until(`${HUB}/config`);
});

afterAll(() => {
  hubProc?.kill();
  engineProc?.kill();
});

describe("the hub in front of an engine", () => {
  test("it says which presenters it asks, and serves the screen", async () => {
    const config = (await (await fetch(`${HUB}/config`)).json()) as { presenters: string[] };
    expect(config.presenters).toEqual([PRESENTER]);
    const page = await fetch(`${HUB}/`);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('<script type="module" src="/app.js">');
    const script = await fetch(`${HUB}/app.js`);
    expect(script.status).toBe(200);
    expect(await script.text()).toContain("navigator.credentials");
  });

  test("a member's key goes through the hub to /_identities", async () => {
    // What the browser does after `navigator.credentials.create`: the public
    // key arrives as SPKI DER, and it is registered under the mandate's name.
    const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const der = pair.publicKey.export({ type: "spki", format: "der" });
    for (const key of [MANDATE, HOUSEHOLD]) {
      const registered = await post(HUB, "/api/_identities", { key, public_key: spkiToPem(der) });
      expect([key, registered.status]).toEqual([key, 201]);
    }
    memberKey = pair;
  });

  test("an offer presented by the engine is waiting on the hub", async () => {
    const created = await post(ENGINE, "/offers", {
      binding: "digital",
      household: HOUSEHOLD,
      purpose: "replenish",
      config_version: "cfg-hub-test",
      expires_at: Date.now() + 3_600_000,
      mandate: MANDATE,
      price_band: null,
      giver: null,
      candidates: [
        { product: "tea-a", quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null },
        { product: "coffee-a", quantity: 2, predicted_conversion: 0.5, is_exploration: true, given_by: null },
      ],
    });
    expect(created.status).toBe(201);
    offerId = created.body.id as string;
    candidateIds = (created.body.candidates as { id: string }[]).map((c) => c.id);
    const perCandidate: Record<string, unknown> = {};
    for (const id of candidateIds) perCandidate[id] = { alternatives: ["the same in a smaller tin"], argument_against: "you have two of these already" };
    expect((await post(ENGINE, `/offers/${offerId}/deliberation`, {
      per_candidate: perCandidate,
      excluded: [{ product: "tea-b", reason: "declined_before" }],
      mandate: { kind: "individual", scope: "this offer", lapses_at: null },
    })).status).toBe(201);
    expect((await post(ENGINE, `/offers/${offerId}/present`, {})).status).toBe(200);

    const list = (await (await fetch(`${HUB}/api/offers?household=${HOUSEHOLD}&presenter=${PRESENTER}`)).json()) as {
      offers: { id: string; state: string; binding: string; presented_at: number | null; candidates: { valence: string }[] }[];
    };
    expect(list.offers.map((o) => [o.id, o.state])).toEqual([[offerId, "presented"]]);

    // **The screen classifies this list without asking a second question**, so
    // every field the rule reads has to be on it. It used to ask the engine,
    // once per historical offer, whether a settlement statement was waiting,
    // and file anything that did not answer 200 as a box that settles by
    // itself. Reading the row instead means a transport failure can no longer
    // be read as an answer; that only holds while the row carries this.
    const row = list.offers[0]!;
    expect(row.binding).toBe("digital");
    expect(typeof row.presented_at).toBe("number");
    expect(row.candidates.map((c) => c.valence)).toEqual(["offered", "offered"]);
  });

  test("the approval the screen renders carries what clause 59 and clause 36 require", async () => {
    const approval = (await (await fetch(`${HUB}/api/offers/${offerId}/approval`)).json()) as {
      candidates: { product: string; alternatives: string[]; argument_against: string; merchant: string; maker: string; ships: string; given_by: string | null; valence: string }[];
      excluded: { product: string; reason: string }[];
      reminded: boolean;
    };
    expect(approval.candidates).toHaveLength(2);
    for (const c of approval.candidates) {
      expect(c.alternatives.length).toBeGreaterThan(0);
      expect(c.argument_against).not.toBe("");
      expect(c.merchant).toBe("maker-a");
      expect(c.ships).toBe("carrier-a");
      // Clause 12, clause 10, §10 step 3c. **Three fields the screen draws and
      // could not read.** It printed "Made by ${c.merchant}", so it named the
      // seller as the maker while the statement screen beside it named the
      // real one; it printed a price beside a gift with no giver; and with no
      // valence it asked for a choice on lines a collection had already
      // resolved. Each was on the engine and missing from the hub's own type.
      // The fixture gives each product a maker that is not its merchant, and
      // the two candidates have different ones, so a screen printing either
      // the seller or a constant fails here.
      expect(c.maker).toBe(({ "tea-a": "made-by-tea", "coffee-a": "made-by-coffee" } as Record<string, string>)[c.product]!);
      expect(c.given_by).toBeNull();
      expect(c.valence).toBe("offered");
    }
    expect(approval.excluded).toEqual([{ product: "tea-b", reason: "declined_before" }]);
    expect(approval.reminded).toBe(false);

    // Clauses 54 and 59. **The deliberation is the presenter's words and the
    // screen attributes them.** A person who reads "you have two of these
    // already" as their own agent's finding cannot weigh who said it, and the
    // surface a party to no transaction draws is exactly where that confusion
    // lives. The script is checked rather than the DOM, because this suite
    // runs no browser; what it proves is that the attribution is in the code
    // the hub serves and not only in a comment.
    const built = await (await fetch(`${HUB}/app.js`)).text();
    expect(built).toContain("argues against taking it");
    expect(built).toContain("says it also considered");
  });

  test("a decided set confirmed by a P-256 assertion through the hub is decided", async () => {
    const decisions: Decision[] = [
      { candidate: candidateIds[0]!, valence: "kept", kept_as: "self" },
      { candidate: candidateIds[1]!, valence: "returned" },
    ];
    // What the authenticator does after the button: sign its own data, whose
    // first 32 bytes name the relying party and whose flags say the person
    // was present and verified, and the hash of the client data whose
    // challenge is the set.
    const challenge = await challengeFor(offerId, decisions);
    expect(Buffer.from(challenge).toString("base64url")).toBe(createHash("sha256").update(canonicalDecisions(offerId, decisions)).digest("base64url"));
    const authenticatorData = Buffer.concat([createHash("sha256").update(RP).digest(), Buffer.from([0x05]), Buffer.from([0, 0, 0, 1])]);
    const clientDataJson = Buffer.from(JSON.stringify({ type: "webauthn.get", challenge: Buffer.from(challenge).toString("base64url"), origin: `http://${RP}:${HUB_PORT}` }), "utf8");
    const signed = Buffer.concat([authenticatorData, createHash("sha256").update(clientDataJson).digest()]);
    const decided = await post(HUB, `/api/offers/${offerId}/decisions`, {
      decisions,
      assertion: {
        authenticator_data: toBase64(authenticatorData),
        client_data_json: toBase64(clientDataJson),
        signature: toBase64(sign("sha256", signed, memberKey!.privateKey)),
      },
    });
    expect(decided.status).toBe(200);
    expect(decided.body.state).toBe("decided");
    const kept = (decided.body.candidates as { id: string; valence: string }[]).find((c) => c.id === candidateIds[0]);
    expect(kept?.valence).toBe("kept");
  });

  test("it carries the screen's calls and refuses the rest of the engine", async () => {
    // A hub that forwarded whatever it was handed would put the engine's whole
    // surface behind a page anyone can open. The reference engine
    // authenticates nobody by design, so the narrowing is the hub's.
    const refused: [string, string][] = [
      ["GET", `/api/households/${HOUSEHOLD}/export`],
      ["POST", "/api/_presenter/configs"],
      ["POST", "/api/offers"],
      ["GET", `/api/offers/${offerId}`],
      ["GET", "/api/registry"],
    ];
    for (const [method, path] of refused) {
      const r = await fetch(`${HUB}${path}`, { method, headers: { "content-type": "application/json" }, body: method === "GET" ? undefined : "{}" });
      expect([method, path, r.status]).toEqual([method, path, 404]);
      expect([method, path, ((await r.json()) as { error: string }).error]).toEqual([method, path, "not_carried"]);
    }
  });

  test("a key can only be registered under a mandate name this hub issues", async () => {
    // Clause 2. `attested` is an identity root speaking, not a browser, and a
    // presenter's name is not a member's to take. Both were reachable from any
    // browser until 2026-09-11.
    const pair = generateKeyPairSync("ed25519");
    const pem = pair.publicKey.export({ type: "spki", format: "pem" }).toString();
    for (const key of ["some-other-presenter", "household-short", "mandate-short"]) {
      const squat = await post(HUB, "/api/_identities", { key, public_key: pem });
      expect([key, squat.status]).toEqual([key, 400]);
      expect([key, squat.body.error]).toEqual([key, "not_this_name"]);
    }
    // Registered all the same, and never as endorsed: the hub drops the flag.
    // What makes that observable is §5.2, where an offer says whether an
    // identity root endorsed the key of the presenter it names. So the key is
    // asked to be a presenter, and the offer answers.
    const name = `mandate-${Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64url")}`;
    expect((await post(HUB, "/api/_identities", { key: name, public_key: pem, attested: true })).status).toBe(201);
    const config = {
      version: `cfg-${name}`,
      presenter: name,
      products: { "tea-a": { merchant: "maker-a", maker: "made-by-tea", ships: "carrier-a", price: 1200 } },
    };
    expect((await post(ENGINE, "/_presenter/configs", {
      ...config,
      signature: sign(null, canonicalConfig(config), pair.privateKey).toString("base64"),
    })).status).toBe(201);
    const offer = await post(ENGINE, "/offers", {
      binding: "digital",
      household: `${HOUSEHOLD}-attested`,
      purpose: "replenish",
      config_version: config.version,
      expires_at: Date.now() + 3_600_000,
      mandate: name,
      price_band: null,
      giver: null,
      candidates: [{ product: "tea-a", quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null }],
    });
    expect(offer.status).toBe(201);
    expect(offer.body.presenter_attested).toBe(false);
  });

  test("a passkey records a cooling window, and takes a decided set back (§16)", async () => {
    // What the screen does, in the order it does it. The protections are the
    // half of §16 a member of this hub could not reach at all until the
    // specification took an assertion for a mandate change: an authenticator
    // signs its own data and the hash of the client's, never bytes a caller
    // hands it, so a person holding a passkey could record no cooling window
    // and therefore had nothing to take a decided set back into.
    const mandate = {
      id: MANDATE,
      household: HOUSEHOLD,
      ceiling_out_of_network: 100000,
      ceiling_daily: null,
      cooling_seconds: 3600,
      co_signers: [] as string[],
      lapses_at: Date.now() + 365 * 86_400_000,
      version: 1,
    };
    const recorded = await post(HUB, "/api/_node/mandates", {
      ...mandate,
      assertions: { [HOUSEHOLD]: assertOver(canonicalMandate(mandate)) },
    });
    expect(recorded.status).toBe(201);
    const read = await (await fetch(`${HUB}/api/_node/mandates/${encodeURIComponent(MANDATE)}`)).json();
    expect((read as { cooling_seconds: number }).cooling_seconds).toBe(3600);

    const offer = await placed();
    const decisions = offer.candidates.map((c) => ({ candidate: c.id, valence: "kept" as const, kept_as: "self" as const }));
    const decided = await post(HUB, `/api/offers/${offer.id}/decisions`, {
      decisions,
      assertion: assertOver(canonicalDecisions(offer.id, decisions)),
    });
    expect(decided.status).toBe(200);

    // §16.5. It waits, and while it waits the person can take it back.
    const early = await post(ENGINE, `/offers/${offer.id}/settle`, {});
    expect([early.status, early.body.error]).toEqual([422, "mandate_cooling"]);
    const taken = await fetch(`${HUB}/api/offers/${offer.id}/decisions`, { method: "DELETE" });
    expect(taken.status).toBe(200);
    const back = (await (await fetch(`${ENGINE}/offers/${offer.id}`)).json()) as { state: string; candidates: { valence: string }[] };
    expect(back.state).toBe("presented");
    expect(back.candidates.every((c) => c.valence === "offered")).toBe(true);
  });

  test("a passkey records a daily ceiling, and a settlement above it is refused (§16.3)", async () => {
    // The second protection this screen can set. It is written the way the
    // screen writes it: a whole version of the record, signed by the
    // household's own passkey, because a change to one protection is a
    // signature over all of them.
    const base = {
      id: MANDATE,
      household: HOUSEHOLD,
      ceiling_out_of_network: 100000,
      cooling_seconds: null as number | null,
      co_signers: [] as string[],
      lapses_at: Date.now() + 365 * 86_400_000,
    };
    // The offer is placed before the ceiling is set. A ceiling of one yen
    // refuses the offer at creation as well as the settlement, so setting it
    // first would have proved that an offer can be refused and nothing about
    // §16.3. Found by writing the test in the other order and reading the 422.
    //
    // It is placed with this household, which has been offered tea-b already
    // by the tests above: the exploration floor asks for a candidate this
    // household has never been offered, and a fourth offer of the same
    // product is not one. The second 422 this test produced was that floor,
    // not the ceiling, which is why the offer names a product of its own.
    const offer = await placed("tea-c");

    const read0 = await (await fetch(`${HUB}/api/_node/mandates/${encodeURIComponent(MANDATE)}`)).json();
    const version = ((read0 as { version?: number }).version ?? 0) + 1;
    const mandate = { ...base, ceiling_daily: 1, version };
    const recorded = await post(HUB, "/api/_node/mandates", {
      ...mandate,
      assertions: { [HOUSEHOLD]: assertOver(canonicalMandate(mandate)) },
    });
    expect(recorded.status).toBe(201);
    const decisions = offer.candidates.map((c) => ({ candidate: c.id, valence: "kept" as const, kept_as: "self" as const }));
    const decided = await post(HUB, `/api/offers/${offer.id}/decisions`, {
      decisions,
      assertion: assertOver(canonicalDecisions(offer.id, decisions)),
    });
    expect(decided.status).toBe(200);
    const settled = await post(ENGINE, `/offers/${offer.id}/settle`, {});
    expect([settled.status, settled.body.error]).toEqual([422, "mandate_ceiling_daily"]);
  });

  test("an unreachable engine is reported as such, not as an empty answer", async () => {
    const dead = Bun.spawn(["bun", "src/server.ts"], {
      cwd: join(import.meta.dir, ".."),
      env: childEnv({ PORT: String(HUB_PORT + 1), VALENCE_ENGINE_URL: "http://localhost:1", VALENCE_PRESENTERS: PRESENTER }),
      stdout: "ignore",
      stderr: "inherit",
    });
    try {
      await until(`http://localhost:${HUB_PORT + 1}/config`);
      const r = await fetch(`http://localhost:${HUB_PORT + 1}/api/offers?household=x&presenter=y`);
      expect(r.status).toBe(502);
      expect(((await r.json()) as { error: string }).error).toBe("engine_unreachable");
    } finally {
      dead.kill();
    }
  });
});

describe("the statement a household signs (§6.5)", () => {
  /**
   * Question 36. The collection's record is a proposal and the household's
   * signature over the statement is the application, so the screen has to be
   * able to read the statement and post the signature. Both routes are on the
   * hub's list since 2026-09-12, and this is what they carry.
   *
   * **The canonical form is written out in `src/shared/canonical.ts` and again
   * here**, and the point of the test is that the engine accepts what the
   * screen would produce. A hub that agreed with the engine by importing its
   * code would agree by accident.
   */
  const STATEMENT_DOMAIN = "valence.statement.1";
  const canonicalStatement = (
    offer: string,
    // §6.5, question 40, 2026-09-13. The carriage the screen showed is inside
    // the bytes, between the offer id and the lines.
    carriage: number,
    lines: { candidate: string; valence: string; amount: number; disputed: boolean }[]
  ) =>
    [
      STATEMENT_DOMAIN,
      offer,
      String(carriage),
      ...[...lines]
        .sort((a, b) => (a.candidate < b.candidate ? -1 : a.candidate > b.candidate ? 1 : 0))
        .map((l) => `${l.candidate}:${l.valence}:${l.amount}:${l.disputed ? "disputed" : ""}`),
    ].join("\n");

  /**
   * A physical box, delivered, collected with one line used.
   *
   * **A household of its own each time.** Exploration is what a household has
   * never been offered by this presenter (§5.1), so the household the rest of
   * this file uses has seen every product in the fixture and no candidate of
   * its could be marked. The mandate stays the same one, because a statement
   * is verified against the key registered for the offer's mandate.
   */
  /**
   * A mandate of this group's own, carrying the member's key.
   *
   * **The shared mandate has a daily ceiling on it** by the time these run,
   * written by the §16.3 test, and a settlement of 1,500 is above it. An
   * engine leaves a mandate it has no record of alone (§16.2), so a second
   * name registered with the same key gives these tests a settlement path
   * without unpicking what another test proved.
   */
  let mandate = "";
  async function underOwnMandate() {
    if (mandate) return mandate;
    mandate = `mandate-statement-${Math.random().toString(36).slice(2, 12)}`;
    expect((await post(ENGINE, "/_identities", {
      key: mandate,
      public_key: memberKey!.publicKey.export({ type: "spki", format: "pem" }).toString(),
      attested: false,
    })).status).toBe(201);
    return mandate;
  }

  async function collected(product: string) {
    const household = `${HOUSEHOLD}-statement-${Math.random().toString(36).slice(2, 10)}`;
    const own = await underOwnMandate();
    const created = await post(ENGINE, "/offers", {
      binding: "physical",
      household,
      purpose: "replenish",
      config_version: "cfg-hub-test",
      expires_at: Date.now() + 3_600_000,
      mandate: own,
      price_band: null,
      giver: null,
      candidates: [{ product, quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null }],
    });
    expect(created.status).toBe(201);
    const offer = created.body as unknown as { id: string; candidates: { id: string }[] };
    const per: Record<string, unknown> = {};
    for (const c of offer.candidates) per[c.id] = { alternatives: ["a smaller tin"], argument_against: "you have some already" };
    expect((await post(ENGINE, `/offers/${offer.id}/deliberation`, {
      per_candidate: per,
      excluded: [],
      mandate: { kind: "standing", scope: "tea", lapses_at: Date.now() + 90 * 86_400_000 },
    })).status).toBe(201);
    expect((await post(ENGINE, `/offers/${offer.id}/present`, {})).status).toBe(200);
    // §6.5, 法11条1号. The box was delivered, so there is a delivery to record
    // and the statement renders the carriage from it.
    expect((await post(ENGINE, `/offers/${offer.id}/delivery`, {
      carriage: 0,
      code: `dc-hub-${offer.id.slice(0, 6)}`,
      status: "delivered",
    })).status).toBe(201);
    expect((await post(ENGINE, `/offers/${offer.id}/recovery`, {
      returned: [],
      consumed: offer.candidates.map((c) => c.id),
    })).status).toBe(200);
    return offer;
  }

  test("the hub carries the statement, and the screen's signature settles it", async () => {
    const offer = await collected("coffee-a");
    const read = await fetch(`${HUB}/api/offers/${offer.id}/statement`);
    expect(read.status).toBe(200);
    const st = (await read.json()) as {
      offer: string;
      expires_at: number;
      carriage: number | null;
      lines: { candidate: string; valence: string; amount: number; merchant: string; disclosure: { merchant: string; product: string | null } }[];
      disclosures: { merchant: string; product: string | null; items: { label: string; value: string }[] }[];
    };
    // What the screen draws: a line at its price, the carriage recorded as
    // zero rather than absent, and the block that governs each line.
    expect(st.lines.length).toBe(1);
    expect(st.lines[0]!.valence).toBe("consumed");
    expect(st.lines[0]!.amount).toBe(1500);
    expect(st.carriage).toBe(0);
    expect(typeof st.expires_at).toBe("number");
    const which = st.lines[0]!.disclosure;
    expect(which.merchant).toBe(st.lines[0]!.merchant);
    expect(st.disclosures.some((d) => d.merchant === which.merchant && d.product === which.product)).toBe(true);

    const lines = st.lines.map((l) => ({ candidate: l.candidate, valence: l.valence, amount: l.amount, disputed: false }));
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ assertion: assertOver(canonicalStatement(offer.id, 0, lines)), disputed: [] }),
    });
    expect(settled.status).toBe(200);
    const receipt = (await settled.json()) as { charged: number; disputed_amount: number; confirmation: string | null };
    expect(receipt.charged).toBe(1500);
    expect(receipt.disputed_amount).toBe(0);
    expect(typeof receipt.confirmation).toBe("string");
  });

  test("a disputed line is signed for and not charged, and the engine says so", async () => {
    // §6.5. A disputed line leaves the rail: not charged here, and what is
    // owed for it is between the household and the seller. The screen says so
    // in words, and this is the half the engine answers for.
    const offer = await collected("tea-a");
    const read = await fetch(`${HUB}/api/offers/${offer.id}/statement`);
    const st = (await read.json()) as { lines: { candidate: string; valence: string; amount: number }[] };
    const lines = st.lines.map((l) => ({ candidate: l.candidate, valence: l.valence, amount: l.amount, disputed: true }));
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        assertion: assertOver(canonicalStatement(offer.id, 0, lines)),
        disputed: st.lines.map((l) => l.candidate),
      }),
    });
    expect(settled.status).toBe(200);
    const receipt = (await settled.json()) as { charged: number; disputed_amount: number };
    expect(receipt.charged).toBe(0);
    expect(receipt.disputed_amount).toBe(1200);
  });

  test("the member can read what a settlement came to, and it adds no exposure", async () => {
    // §6.5. A household signs, the engine settles, the answer is lost. Signing
    // again answers `already_settled`, the row is `settled` so it is on no
    // list, and until 2026-09-12 no screen anywhere could say what had been
    // charged. **Carrying the read costs nothing**, which is the half that had
    // to be checked rather than assumed: `POST .../settle` with an empty body
    // is already carried and already returns the same record to whoever holds
    // the id, so this is the same bytes through a verb that does not write.
    const offer = await collected("tea-b");
    const read = await fetch(`${HUB}/api/offers/${offer.id}/settlement`);
    expect(read.status).toBe(404);

    const st = (await (await fetch(`${HUB}/api/offers/${offer.id}/statement`)).json()) as {
      lines: { candidate: string; valence: string; amount: number }[];
    };
    const lines = st.lines.map((l) => ({ candidate: l.candidate, valence: l.valence, amount: l.amount, disputed: false }));
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ assertion: assertOver(canonicalStatement(offer.id, 0, lines)), disputed: [] }),
    });
    expect(settled.status).toBe(200);
    const charged = ((await settled.json()) as { charged: number }).charged;

    // The second tab, or the same member after a lost answer.
    const again = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ assertion: assertOver(canonicalStatement(offer.id, 0, lines)), disputed: [] }),
    });
    expect(again.status).toBe(409);
    expect(((await again.json()) as { error: string }).error).toBe("already_settled");

    const stood = await fetch(`${HUB}/api/offers/${offer.id}/settlement`);
    expect(stood.status).toBe(200);
    expect(((await stood.json()) as { charged: number }).charged).toBe(charged);
  });

  /**
   * Question 46. A box whose collection names each product's verdict, with a
   * note for every missing one.
   */
  async function collectedWith(verdicts: Record<string, "consumed" | "missing">) {
    const household = `${HOUSEHOLD}-missing-${Math.random().toString(36).slice(2, 10)}`;
    const own = await underOwnMandate();
    const products = Object.keys(verdicts);
    const created = await post(ENGINE, "/offers", {
      binding: "physical",
      household,
      purpose: "replenish",
      config_version: "cfg-hub-test",
      expires_at: Date.now() + 3_600_000,
      mandate: own,
      price_band: null,
      giver: null,
      candidates: products.map((product) => ({ product, quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null })),
    });
    expect(created.status).toBe(201);
    const offer = created.body as unknown as { id: string; candidates: { id: string; product: string }[] };
    const per: Record<string, unknown> = {};
    for (const c of offer.candidates) per[c.id] = { alternatives: ["a smaller tin"], argument_against: "you have some already" };
    expect((await post(ENGINE, `/offers/${offer.id}/deliberation`, {
      per_candidate: per,
      excluded: [],
      mandate: { kind: "standing", scope: "tea", lapses_at: Date.now() + 90 * 86_400_000 },
    })).status).toBe(201);
    expect((await post(ENGINE, `/offers/${offer.id}/present`, {})).status).toBe(200);
    expect((await post(ENGINE, `/offers/${offer.id}/delivery`, {
      carriage: 0,
      code: `dc-hub-${offer.id.slice(0, 6)}`,
      status: "delivered",
    })).status).toBe(201);
    const idsFor = (v: string) => offer.candidates.filter((c) => verdicts[c.product] === v).map((c) => c.id);
    const missing = idsFor("missing");
    const collection = await post(ENGINE, `/offers/${offer.id}/recovery`, {
      returned: [],
      consumed: idsFor("consumed"),
      missing,
      missing_notes: Object.fromEntries(missing.map((id) => [id, "not in the tray at collection"])),
    });
    expect(collection.status).toBe(200);
    return { offer, missing };
  }

  type Line = { candidate: string; valence: string; amount: number };

  test("a missing line comes through the hub at zero and settles on the screen's signature", async () => {
    const { offer, missing } = await collectedWith({ "coffee-a": "consumed", "tea-a": "missing" });
    const st = (await (await fetch(`${HUB}/api/offers/${offer.id}/statement`)).json()) as { lines: Line[] };
    const lost = st.lines.find((l) => l.candidate === missing[0])!;
    expect(lost.valence).toBe("lost");
    expect(lost.amount).toBe(0);
    const lines = st.lines.map((l) => ({ ...l, disputed: false }));
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ assertion: assertOver(canonicalStatement(offer.id, 0, lines)), disputed: [] }),
    });
    expect(settled.status).toBe(200);
    const receipt = (await settled.json()) as { charged: number; disputed_amount: number };
    expect(receipt.charged).toBe(1500);
    expect(receipt.disputed_amount).toBe(0);
  });

  test("a disputed missing line is signed as disputed and moves no money", async () => {
    const { offer, missing } = await collectedWith({ "coffee-a": "consumed", "tea-b": "missing" });
    const st = (await (await fetch(`${HUB}/api/offers/${offer.id}/statement`)).json()) as { lines: Line[] };
    const lines = st.lines.map((l) => ({ ...l, disputed: missing.includes(l.candidate) }));
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ assertion: assertOver(canonicalStatement(offer.id, 0, lines)), disputed: missing }),
    });
    expect(settled.status).toBe(200);
    const receipt = (await settled.json()) as { charged: number; disputed_amount: number; lines: { candidate: string; disputed: boolean }[] };
    expect(receipt.charged).toBe(1500);
    expect(receipt.disputed_amount).toBe(0);
    expect(receipt.lines.find((l) => l.candidate === missing[0])!.disputed).toBe(true);
  });

  test("a box whose only collection line is missing needs the statement signed", async () => {
    const { offer } = await collectedWith({ "tea-c": "missing" });
    const unsigned = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(unsigned.status).toBe(422);
    expect(((await unsigned.json()) as { error: string }).error).toBe("statement_unsigned");
    const st = (await (await fetch(`${HUB}/api/offers/${offer.id}/statement`)).json()) as { lines: Line[] };
    expect(st.lines.map((l) => `${l.valence}:${l.amount}`)).toEqual(["lost:0"]);
    const lines = st.lines.map((l) => ({ ...l, disputed: false }));
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ assertion: assertOver(canonicalStatement(offer.id, 0, lines)), disputed: [] }),
    });
    expect(settled.status).toBe(200);
    expect(((await settled.json()) as { charged: number }).charged).toBe(0);
  });

  test("an unsigned statement is refused, so the screen cannot settle by asking", async () => {
    const offer = await collected("tea-c");
    const settled = await fetch(`${HUB}/api/offers/${offer.id}/settle`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(settled.status).toBe(422);
    expect(((await settled.json()) as { error: string }).error).toBe("statement_unsigned");
  });
});

let memberKey: KeyPairKeyObjectResult | undefined;
