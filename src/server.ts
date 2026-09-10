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

export async function handle(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/" || url.pathname === "/index.html") {
    return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
  }
  if (url.pathname === "/app.js") {
    return new Response(script, { headers: { "content-type": "text/javascript; charset=utf-8" } });
  }
  if (url.pathname === "/config") {
    return json({ presenters });
  }
  if (url.pathname.startsWith("/api/")) {
    const target = `${engine}${url.pathname.slice(4)}${url.search}`;
    const headers: Record<string, string> = { "user-agent": "atarasy/0.0.0" };
    const contentType = request.headers.get("content-type");
    if (contentType) headers["content-type"] = contentType;
    const body = request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer();
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
