/**
 * The reference hub. What a member opens.
 *
 * Three things and nothing else: it serves the screen, it builds the screen's
 * script, and it carries the screen's calls to the engine under `/api`. The
 * screen is a browser page because the member's key is a passkey, and a
 * passkey lives in the browser's authenticator; the hub holds no key of the
 * member's and signs nothing on their behalf (clause 35).
 *
 * The calls are proxied rather than made across origins because the engine
 * sets no CORS headers, and should not: which origins may call an engine is
 * a deployment's decision and not the specification's.
 *
 * **The proxy carries the four calls the screen makes and refuses everything
 * else.** A hub that forwarded whatever it was handed would put the engine's
 * whole surface behind a page anyone can open: the catalogue routes, another
 * household's export (clauses 43, 49), a settlement, a withdrawal of somebody
 * else's decided set. The reference engine authenticates nobody by design, so
 * the narrowing has to be here. Found by an adversarial pass on the day this
 * was written, before it was pointed at anything but a scratch engine.
 */
import { join } from "node:path";

const engine = process.env.VALENCE_ENGINE_URL?.replace(/\/+$/, "");
if (!engine) {
  console.error("VALENCE_ENGINE_URL must be set to the engine this hub asks for offers.");
  process.exit(1);
}

/**
 * Clause 8. An engine lists offers per presenter and never a household's
 * union, so a hub asks each presenter it knows and unions the answers on the
 * person's side. In a deployment the presenters come from the registry (§17);
 * the reference is told them, because its registry entries point nowhere.
 */
const presenters = (process.env.VALENCE_PRESENTERS ?? "")
  .split(",")
  .map((p) => p.trim())
  .filter(Boolean);
if (presenters.length === 0) {
  console.error("VALENCE_PRESENTERS must name at least one presenter to ask for offers, comma separated.");
  process.exit(1);
}

const here = import.meta.dir;
const built = await Bun.build({
  entrypoints: [join(here, "client", "app.ts")],
  target: "browser",
  minify: false,
});
if (!built.success) {
  for (const log of built.logs) console.error(log);
  process.exit(1);
}
const script = await built.outputs[0]!.text();
const page = await Bun.file(join(here, "client", "index.html")).text();

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/**
 * §10.5. The name a member's key is registered under. It is derived from the
 * credential id, so it is unguessable: the engine keeps the first key
 * registered for a name and refuses a later, different one (clause 22), so a
 * guessable name is a name somebody else can take first, and the person whose
 * offers it confirms could then never register their own. Measured as a real
 * path on 2026-09-11, when the name was `mandate-<household>`.
 */
const MANDATE_NAME = /^mandate-[A-Za-z0-9_-]{16,}$/;

/** The calls the screen makes. Anything else is not this hub's to carry. */
function carries(method: string, path: string): boolean {
  const parts = path.split("/").filter(Boolean);
  if (method === "POST" && parts.length === 1 && parts[0] === "_identities") return true;
  if (method === "GET" && parts.length === 1 && parts[0] === "offers") return true;
  if (method === "GET" && parts.length === 3 && parts[0] === "offers" && parts[2] === "approval") return true;
  if (method === "POST" && parts.length === 3 && parts[0] === "offers" && parts[2] === "decisions") return true;
  return false;
}

export async function handle(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/" || url.pathname === "/index.html") {
    return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
  }
  if (url.pathname === "/app.js") {
    return new Response(script, { headers: { "content-type": "text/javascript; charset=utf-8" } });
  }
  if (url.pathname === "/favicon.ico") {
    return new Response(null, { status: 204 });
  }
  if (url.pathname === "/config") {
    return json({ presenters });
  }
  if (url.pathname.startsWith("/api/")) {
    const path = url.pathname.slice(4);
    if (!carries(request.method, path)) {
      return json({ error: "not_carried", message: "this hub carries the screen's own calls and no others" }, 404);
    }
    let body: ArrayBuffer | string | undefined;
    if (request.method !== "GET" && request.method !== "HEAD") {
      body = await request.arrayBuffer();
    }
    // A key is registered under a name this hub issues, and never as one an
    // identity root endorsed: `attested` is clause 2's root speaking, not a
    // browser's. Without this the page could take a presenter's name.
    if (path === "/_identities") {
      let raw: { key?: unknown; public_key?: unknown };
      try {
        raw = JSON.parse(new TextDecoder().decode(body as ArrayBuffer)) as typeof raw;
      } catch {
        return json({ error: "malformed", message: "an identity is a JSON object" }, 400);
      }
      if (typeof raw.key !== "string" || !MANDATE_NAME.test(raw.key)) {
        return json({ error: "not_this_name", message: "this hub registers a key under a mandate name it issued" }, 400);
      }
      if (typeof raw.public_key !== "string") {
        return json({ error: "malformed", message: "public_key must be a PEM" }, 400);
      }
      body = JSON.stringify({ key: raw.key, public_key: raw.public_key, attested: false });
    }
    const target = `${engine}${path}${url.search}`;
    const headers: Record<string, string> = { "user-agent": "atarasy/0.0.0" };
    const contentType = request.headers.get("content-type");
    if (contentType) headers["content-type"] = contentType;
    if (typeof body === "string") headers["content-type"] = "application/json";
    let upstream: Response;
    try {
      upstream = await fetch(target, { method: request.method, headers, body });
    } catch {
      return json({ error: "engine_unreachable", message: `the engine at ${engine} did not answer` }, 502);
    }
    return new Response(await upstream.arrayBuffer(), {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  }
  return json({ error: "not_found", message: "no such page" }, 404);
}

const port = Number(process.env.PORT ?? 8790);
Bun.serve({ port, fetch: handle });
console.log(`atarasy listening on http://localhost:${port}, asking ${engine} for ${presenters.join(", ")}`);
