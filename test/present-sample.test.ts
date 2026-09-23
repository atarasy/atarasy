/**
 * `scripts/present-sample.ts` against a running engine: it registers a
 * presenter and a merchant, publishes a one-product catalogue, and presents
 * an offer that shows up on the engine's own list for the household and
 * presenter it used. This does not start the hub; that half is what OPS-01
 * itself measures by hand, because a passkey needs a person at the device.
 */
import { afterAll, beforeAll, expect, test } from "bun:test";
import { createHash, generateKeyPairSync } from "node:crypto";
import { existsSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { spkiToPem } from "../src/shared/encoding.js";

const ENGINE_DIR = resolve(process.env.VALENCE_ENGINE_DIR ?? join(import.meta.dir, "..", "..", "valence", "engine"));
const ENGINE_PORT = Number(process.env.ENGINE_PORT ?? 9702);
const ENGINE = `http://localhost:${ENGINE_PORT}`;
const KEY_FILE = join(import.meta.dir, "..", ".ops01", `test-present-sample-${ENGINE_PORT}.json`);

if (!existsSync(join(ENGINE_DIR, "src", "server.ts"))) {
  throw new Error(`no engine at ${ENGINE_DIR}. Set VALENCE_ENGINE_DIR to a checkout of atarasy/valence's engine/.`);
}

function childEnv(extra: Record<string, string>): Record<string, string> {
  const base: Record<string, string> = {};
  for (const key of ["PATH", "HOME", "TMPDIR", "LANG"]) {
    const value = process.env[key];
    if (value) base[key] = value;
  }
  return { ...base, ...extra };
}

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

let engineProc: ReturnType<typeof Bun.spawn> | undefined;

beforeAll(async () => {
  rmSync(KEY_FILE, { force: true });
  engineProc = Bun.spawn(["bun", "src/server.ts"], {
    cwd: ENGINE_DIR,
    env: childEnv({ PORT: String(ENGINE_PORT), VALENCE_EXPLORATION_RATE: "0.2", VALENCE_RECOVERY_GRACE_DAYS: "0", VALENCE_RP_ID: "localhost" }),
    stdout: "ignore",
    stderr: "inherit",
  });
  await until(`${ENGINE}/offers?household=probe&presenter=probe`);
});

afterAll(() => {
  engineProc?.kill();
  rmSync(KEY_FILE, { force: true });
});

test("puts an offer where the household and presenter it used can see it", async () => {
  const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const der = pair.publicKey.export({ type: "spki", format: "der" });
  const household = "key:" + createHash("sha256").update(der).digest("base64url");
  expect((await fetch(`${ENGINE}/_identities`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ key: household, public_key: spkiToPem(der), attested: false }),
  })).status).toBe(201);

  const run = Bun.spawnSync(["bun", "scripts/present-sample.ts", household], {
    cwd: join(import.meta.dir, ".."),
    env: childEnv({ VALENCE_ENGINE_URL: ENGINE, PRESENT_SAMPLE_KEY_FILE: KEY_FILE }),
  });
  expect(run.exitCode).toBe(0);
  expect(run.stdout.toString()).toContain(`to ${household}`);

  const list = (await (await fetch(`${ENGINE}/offers?household=${encodeURIComponent(household)}&presenter=sample-presenter`)).json()) as {
    offers: { state: string; binding: string; candidates: { valence: string }[] }[];
  };
  expect(list.offers.length).toBe(1);
  expect(list.offers[0]!.state).toBe("presented");
  expect(list.offers[0]!.binding).toBe("digital");
  expect(list.offers[0]!.candidates.map((c) => c.valence)).toEqual(["offered"]);

  // A second run for the same household publishes a fresh product, so the
  // exploration floor (a one-product catalogue this household has already
  // seen has nothing novel left) does not refuse it.
  const again = Bun.spawnSync(["bun", "scripts/present-sample.ts", household], {
    cwd: join(import.meta.dir, ".."),
    env: childEnv({ VALENCE_ENGINE_URL: ENGINE, PRESENT_SAMPLE_KEY_FILE: KEY_FILE }),
  });
  expect(again.exitCode).toBe(0);
  const listAgain = (await (await fetch(`${ENGINE}/offers?household=${encodeURIComponent(household)}&presenter=sample-presenter`)).json()) as {
    offers: unknown[];
  };
  expect(listAgain.offers.length).toBe(2);
});
