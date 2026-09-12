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
 * **The proxy carries the calls the screen makes and refuses everything
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
 * §10.5, §16. The two names a member's key is registered under, both derived
 * from the credential id and so unguessable.
 *
 * The engine keeps the first key registered for a name and refuses a later,
 * different one (clause 22), so a guessable name is a name somebody else can
 * take first. The mandate reference was `mandate-<household>` for part of
 * 2026-09-11, which let a stranger hold the key that confirms a named
 * household's offers.
 *
 * **The household's own name has to be derived too, and that took a second
 * adversarial round to see.** A mandate record is signed by the key registered
 * under the household's name (§16.1), not under the mandate's, so a hub that
 * derived only the mandate reference left its members unable to record any
 * protection at all: no ceiling, no co-signer, no cooling window and therefore
 * no way to take a decided set back. And whoever registered the household's
 * plain name first owned those protections instead. So what the person types
 * is a label this browser keeps, and the identifier a shop is given is the
 * credential's.
 */
const MEMBER_NAME = /^(mandate|household)-[A-Za-z0-9_-]{16,}$/;

/**
 * The calls the screen makes. Anything else is not this hub's to carry.
 *
 * **Every line here is a route any browser that can open the page can reach on
 * the engine**, which authenticates nobody by design, so this list is the whole
 * of the boundary. Two are worth naming for what they give away. `GET /offers`
 * answers for whatever household is asked for, and the household is unguessable
 * only because this hub derives it from a credential. `DELETE .../decisions`
 * takes a decided set back, and the engine asks for no signature to do it
 * (§16.5): un-deciding removes a commitment rather than making one, which is
 * why the specification treats it as the person's alone, and nothing checks
 * that it is the person.
 *
 * **`POST .../settle` joined the list on 2026-09-12.** §6.5 makes the
 * household's signature over the settlement statement the application for a
 * physical box's consumed lines, and the signature has to reach the engine
 * somehow, so the screen posts it here. The cost is that whoever knows an
 * offer id can ask this engine to settle it: for a physical box with goods
 * used that is refused without a signature this hub cannot forge, and **for a
 * digital offer it is not**, since a digital settlement takes an empty body
 * and commits the ledger for what the person already signed at the decision.
 * What that costs is the timing rather than the amount, because the charge is
 * the decided set either way.
 *
 * **It is not the widest thing on this list, and a version of this comment
 * said it was.** The widest are the reads, and they were never named. `GET
 * .../statement` and `GET .../approval` hand any holder of an offer id the
 * household's identifier, every product, the giver's name and the carriage;
 * `GET /_node/mandates/{id}` hands the household's ceilings, cooling window
 * and co-signers to any holder of a mandate reference, which the screen tells
 * the member to give to every shop. `POST .../settle` on an offer that has
 * already settled **still answers an unsigned body with the whole settlement**,
 * which is the route's own idempotency for a presenter and is the same read
 * through a route that is carried; what the engine refuses since 2026-09-12 is
 * a signed body, which is a different problem. An earlier version of this
 * comment said the read had been corrected, which it had not. Reading a
 * statement is likewise a giver's channel into whether a recipient kept a
 * gift (clause 16, §7.2). **The narrowing
 * that removes all of it is one narrowing**, an engine that authenticates a
 * caller, which the reference does not do (`08` §3 of the concept documents
 * records this as the open half of clause 53). Naming only the write was the
 * comfortable half of the accounting.
 */
function carries(method: string, path: string): boolean {
  const parts = path.split("/").filter(Boolean);
  if (method === "POST" && parts.length === 1 && parts[0] === "_identities") return true;
  if (method === "GET" && parts.length === 1 && parts[0] === "offers") return true;
  if (method === "GET" && parts.length === 3 && parts[0] === "offers" && parts[2] === "approval") return true;
  if (method === "POST" && parts.length === 3 && parts[0] === "offers" && parts[2] === "decisions") return true;
  // §16.5. Taking a decided set back inside its cooling window.
  if (method === "DELETE" && parts.length === 3 && parts[0] === "offers" && parts[2] === "decisions") return true;
  // §6.5. The settlement statement a household signs before a physical box
  // with goods used is charged, and the settle that carries the signature.
  // Both are the person's own act on their own device, which is what makes
  // the consumed lines an application rather than a third party's record.
  if (method === "GET" && parts.length === 3 && parts[0] === "offers" && parts[2] === "statement") return true;
  if (method === "POST" && parts.length === 3 && parts[0] === "offers" && parts[2] === "settle") return true;
  // §16. The protections a person sets for themselves, and reads back.
  if (method === "POST" && parts.length === 2 && parts[0] === "_node" && parts[1] === "mandates") return true;
  if (method === "GET" && parts.length === 3 && parts[0] === "_node" && parts[1] === "mandates") return true;
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
      if (typeof raw.key !== "string" || !MEMBER_NAME.test(raw.key)) {
        return json({ error: "not_this_name", message: "this hub registers a key under a name it issued" }, 400);
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
      // The member is told that nothing answered, and not where. The internal
      // address of an engine is an operator's fact, and printing it into a
      // failure card put it on a screen anybody who can open the page reads.
      return json({ error: "engine_unreachable", message: "the engine did not answer" }, 502);
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
