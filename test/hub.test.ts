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
function canonicalConfig(c: { version: string; presenter: string; products: Record<string, { merchant: string; ships: string; price: number; category?: string }> }) {
  return Buffer.from(
    [c.version, c.presenter, ...Object.keys(c.products).sort().map((ref) => {
      const e = c.products[ref]!;
      return [ref, e.merchant, e.ships, String(e.price), e.category ?? ""].join(":");
    })].join("\n"),
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
async function placed(): Promise<{ id: string; candidates: { id: string }[] }> {
  const created = await post(ENGINE, "/offers", {
    binding: "digital",
    household: HOUSEHOLD,
    purpose: "replenish",
    config_version: "cfg-hub-test",
    expires_at: Date.now() + 3_600_000,
    mandate: MANDATE,
    price_band: null,
    giver: null,
    candidates: [{ product: "tea-b", quantity: 1, predicted_conversion: 0.5, is_exploration: true, given_by: null }],
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
  const config = {
    version: "cfg-hub-test",
    presenter: PRESENTER,
    products: {
      "tea-a": { merchant: "maker-a", ships: "carrier-a", price: 1200 },
      "tea-b": { merchant: "maker-a", ships: "carrier-a", price: 900 },
      "coffee-a": { merchant: "maker-a", ships: "carrier-a", price: 1500 },
    },
  };
  expect((await post(ENGINE, "/_presenter/configs", {
    ...config,
    signature: sign(null, canonicalConfig(config), presenterKey.privateKey).toString("base64"),
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

    const list = (await (await fetch(`${HUB}/api/offers?household=${HOUSEHOLD}&presenter=${PRESENTER}`)).json()) as { offers: { id: string; state: string }[] };
    expect(list.offers.map((o) => [o.id, o.state])).toEqual([[offerId, "presented"]]);
  });

  test("the approval the screen renders carries what clause 59 and clause 36 require", async () => {
    const approval = (await (await fetch(`${HUB}/api/offers/${offerId}/approval`)).json()) as {
      candidates: { alternatives: string[]; argument_against: string; merchant: string; ships: string }[];
      excluded: { product: string; reason: string }[];
      reminded: boolean;
    };
    expect(approval.candidates).toHaveLength(2);
    for (const c of approval.candidates) {
      expect(c.alternatives.length).toBeGreaterThan(0);
      expect(c.argument_against).not.toBe("");
      expect(c.merchant).toBe("maker-a");
      expect(c.ships).toBe("carrier-a");
    }
    expect(approval.excluded).toEqual([{ product: "tea-b", reason: "declined_before" }]);
    expect(approval.reminded).toBe(false);
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
      ["POST", `/api/offers/${offerId}/settle`],
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
      products: { "tea-a": { merchant: "maker-a", ships: "carrier-a", price: 1200 } },
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
      co_sign_categories: [] as string[],
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

let memberKey: KeyPairKeyObjectResult | undefined;
