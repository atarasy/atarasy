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
import { spkiToPem, toBase64 } from "../src/shared/encoding.js";

const ENGINE_DIR = resolve(process.env.VALENCE_ENGINE_DIR ?? join(import.meta.dir, "..", "..", "valence", "engine"));
const ENGINE_PORT = Number(process.env.ENGINE_PORT ?? 9700);
const HUB_PORT = Number(process.env.HUB_PORT ?? 9701);
const ENGINE = `http://localhost:${ENGINE_PORT}`;
const HUB = `http://localhost:${HUB_PORT}`;
const RP = "localhost";
const PRESENTER = "reference-merchant";
const HOUSEHOLD = `household-${Math.random().toString(36).slice(2, 8)}`;

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

beforeAll(async () => {
  engineProc = Bun.spawn(["bun", "src/server.ts"], {
    cwd: ENGINE_DIR,
    env: { ...process.env, PORT: String(ENGINE_PORT), VALENCE_EXPLORATION_RATE: "0.2", VALENCE_RECOVERY_GRACE_DAYS: "0", VALENCE_RP_ID: RP },
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
    env: { ...process.env, PORT: String(HUB_PORT), VALENCE_ENGINE_URL: ENGINE, VALENCE_PRESENTERS: PRESENTER },
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
    const registered = await post(HUB, "/api/_identities", { key: `mandate-${HOUSEHOLD}`, public_key: spkiToPem(der), attested: false });
    expect(registered.status).toBe(201);
    memberKey = pair;
  });

  test("an offer presented by the engine is waiting on the hub", async () => {
    const created = await post(ENGINE, "/offers", {
      binding: "digital",
      household: HOUSEHOLD,
      purpose: "replenish",
      config_version: "cfg-hub-test",
      expires_at: Date.now() + 3_600_000,
      mandate: `mandate-${HOUSEHOLD}`,
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

  test("an unreachable engine is reported as such, not as an empty answer", async () => {
    const dead = Bun.spawn(["bun", "src/server.ts"], {
      cwd: join(import.meta.dir, ".."),
      env: { ...process.env, PORT: String(HUB_PORT + 1), VALENCE_ENGINE_URL: "http://localhost:1", VALENCE_PRESENTERS: PRESENTER },
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
