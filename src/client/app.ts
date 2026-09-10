/**
 * The screen. Clauses 32 to 36, 54, 58 and 59, and specification §10.
 *
 * It renders what `GET /offers/{id}/approval` returns and nothing the
 * presenter could have drawn: text from data fields, in the hub's own type,
 * in the order the engine gave. A candidate is kept or returned by the
 * person's own tap, the set is confirmed once, and the confirmation is the
 * passkey's assertion over the set (§10.5), made by the browser's own
 * authenticator. This page never sees a private key.
 */
import { challengeFor, type Decision } from "../shared/canonical.js";
import { fromBase64, spkiToPem, toBase64, toBase64Url } from "../shared/encoding.js";

type Member = { household: string; mandate: string; credential_id: string };

type Approval = {
  offer: string;
  presenter: string;
  expires_at: number;
  reminded: boolean;
  price_band: { min: number; max: number } | null;
  mandate: { kind: "standing" | "individual"; scope: string; lapses_at: number | null };
  candidates: {
    id: string;
    product: string;
    quantity: number;
    unit_price: number;
    merchant: string;
    ships: string;
    is_exploration: boolean;
    alternatives: string[];
    argument_against: string;
  }[];
  excluded: { product: string; reason: string }[];
};

type OfferSummary = { id: string; presenter: string; state: string; expires_at: number; giver: string | null };

/** Clause 36, §10 step 3. The published rules, in words a person reads. */
const RULES: Record<string, string> = {
  auto_renewal: "it carries an auto-renewing subscription",
  obstructed_cancellation: "cancelling it is harder than buying it",
  manufactured_scarcity: "the offer manufactures urgency or scarcity",
  late_price: "the price rises at checkout",
  outside_mandate: "it falls outside the mandate you gave",
  declined_before: "you returned this before",
};

const STORAGE = "atarasy.member";
const app = document.getElementById("app")!;

function load(): Member | null {
  try {
    const raw = localStorage.getItem(STORAGE);
    return raw ? (JSON.parse(raw) as Member) : null;
  } catch {
    return null;
  }
}

async function api<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
  const response = await fetch(`/api${path}`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, body: (text ? JSON.parse(text) : {}) as T };
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, string> = {}, ...children: (string | Node)[]) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  for (const c of children) node.append(c);
  return node;
}

function show(...nodes: (string | Node)[]) {
  app.replaceChildren(...nodes);
}

function failure(message: string) {
  return el("div", { class: "card error" }, el("p", {}, message));
}

const when = (ms: number) => new Date(ms).toLocaleString();
const yen = (n: number) => `¥${n.toLocaleString()}`;

// ---- setup: a passkey, registered as the mandate's key ----------------------

async function setup() {
  const input = el("input", { placeholder: "a name for this household", value: `household-${Math.random().toString(36).slice(2, 8)}` }) as HTMLInputElement;
  const button = el("button", { class: "primary" }, "Create a passkey") as HTMLButtonElement;
  const note = el("p", { class: "muted" }, "The passkey stays on this device. Its public half is registered as the key that confirms your decisions (clause 35).");
  const status = el("p", {});
  button.onclick = async () => {
    button.disabled = true;
    const household = input.value.trim();
    if (!household) { status.textContent = "The household needs a name."; button.disabled = false; return; }
    const mandate = `mandate-${household}`;
    try {
      const credential = (await navigator.credentials.create({
        publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)),
          rp: { name: "Atarasy", id: location.hostname },
          user: { id: new TextEncoder().encode(household), name: household, displayName: household },
          // ES256 first, because that is what most phones and laptops carry;
          // EdDSA and RS256 after it. The engine checks by the registered key's type.
          pubKeyCredParams: [
            { type: "public-key", alg: -7 },
            { type: "public-key", alg: -8 },
            { type: "public-key", alg: -257 },
          ],
          authenticatorSelection: { userVerification: "required", residentKey: "preferred" },
          attestation: "none",
        },
      })) as PublicKeyCredential | null;
      if (!credential) throw new Error("no credential was created");
      const response = credential.response as AuthenticatorAttestationResponse;
      const spki = response.getPublicKey();
      if (!spki) throw new Error("this browser does not hand out the public key of a new passkey");
      const registered = await api<{ error?: string; message?: string }>("POST", "/_identities", {
        key: mandate,
        public_key: spkiToPem(spki),
        attested: false,
      });
      if (registered.status !== 201) throw new Error(registered.body.message ?? `registration answered ${registered.status}`);
      const member: Member = { household, mandate, credential_id: toBase64Url(credential.rawId) };
      localStorage.setItem(STORAGE, JSON.stringify(member));
      await offers(member);
    } catch (e) {
      status.textContent = (e as Error).message;
      button.disabled = false;
    }
  };
  show(
    el("h1", {}, "Atarasy"),
    el("p", {}, "Nothing is offered to you until you have a key to answer with."),
    el("div", { class: "card" }, el("div", { class: "row" }, input, button), note, status)
  );
}

// ---- the offers waiting on the person ---------------------------------------

async function offers(member: Member) {
  const config = await (await fetch("/config")).json() as { presenters: string[] };
  const waiting: OfferSummary[] = [];
  const problems: string[] = [];
  // Clause 8. Each presenter answers for its own offers to this household and
  // never for another's. The union is made here, on the person's side.
  for (const presenter of config.presenters) {
    const list = await api<{ offers?: OfferSummary[]; message?: string }>(
      "GET",
      `/offers?household=${encodeURIComponent(member.household)}&presenter=${encodeURIComponent(presenter)}`
    );
    if (list.status !== 200) { problems.push(`${presenter}: ${list.body.message ?? list.status}`); continue; }
    for (const o of list.body.offers ?? []) if (o.state === "presented") waiting.push(o);
  }
  const cards = waiting.map((o) => {
    const open = el("button", { class: "primary" }, "Open") as HTMLButtonElement;
    open.onclick = () => approval(member, o.id);
    return el("div", { class: "card" },
      el("div", { class: "row" },
        el("span", { class: "grow" }, o.giver ? `A gift from ${o.giver}, offered by ${o.presenter}` : `From ${o.presenter}`),
        open),
      el("p", { class: "muted" }, `Waiting until ${when(o.expires_at)}. Nothing is ordered if you do nothing.`)
    );
  });
  const forget = el("button", {}, "Forget this device") as HTMLButtonElement;
  forget.onclick = () => { localStorage.removeItem(STORAGE); setup(); };
  show(
    el("h1", {}, "Atarasy"),
    el("p", { class: "muted" }, `${member.household}. Decisions are confirmed with the passkey on this device.`),
    ...(cards.length ? cards : [el("p", {}, "Nothing is waiting for you.")]),
    ...problems.map((p) => failure(p)),
    el("p", {}, forget)
  );
}

// ---- the approval screen (§10 step 3 and 4) ---------------------------------

async function approval(member: Member, offerId: string) {
  const got = await api<Approval & { error?: string; message?: string }>("GET", `/offers/${encodeURIComponent(offerId)}/approval`);
  if (got.status !== 200) {
    show(el("h1", {}, "Atarasy"), failure(got.body.message ?? `the approval answered ${got.status}`), back(member));
    return;
  }
  const a = got.body;
  const choices = new Map<string, "kept" | "returned">();
  const confirm = el("button", { class: "primary" }, "Confirm with your passkey") as HTMLButtonElement;
  confirm.disabled = true;
  const status = el("p", {});
  const refresh = () => { confirm.disabled = choices.size !== a.candidates.length; };

  const cards = a.candidates.map((c) => {
    const keep = el("button", {}, "Keep") as HTMLButtonElement;
    const ret = el("button", {}, "Return") as HTMLButtonElement;
    const pick = (v: "kept" | "returned") => {
      choices.set(c.id, v);
      keep.className = v === "kept" ? "chosen" : "";
      ret.className = v === "returned" ? "chosen" : "";
      refresh();
    };
    keep.onclick = () => pick("kept");
    ret.onclick = () => pick("returned");
    return el("div", { class: "card" },
      el("div", { class: "row" },
        el("strong", { class: "grow" }, `${c.product} × ${c.quantity}`),
        el("span", {}, yen(c.unit_price * c.quantity))),
      // Clauses 11 and 12. The maker and the carrier are on the screen the
      // person signs from.
      el("p", { class: "muted" }, `Made by ${c.merchant}. Carried by ${c.ships}.`),
      ...(c.is_exploration ? [el("p", { class: "exploration" }, "Something you have not been offered before (§5).")] : []),
      el("p", {}, el("span", { class: "muted" }, "Against taking it: "), c.argument_against),
      el("p", { class: "muted" }, "Also considered:"),
      el("ul", {}, ...c.alternatives.map((alt) => el("li", {}, alt))),
      el("div", { class: "row" }, keep, ret)
    );
  });

  const excluded = a.excluded.length
    ? [el("h2", {}, "Left out, and why (clause 36)"),
       el("ul", {}, ...a.excluded.map((x) => el("li", {}, `${x.product}: ${RULES[x.reason] ?? x.reason}`)))]
    : [];

  confirm.onclick = async () => {
    confirm.disabled = true;
    status.textContent = "";
    const decisions: Decision[] = a.candidates.map((c) => {
      const valence = choices.get(c.id)!;
      return valence === "kept" ? { candidate: c.id, valence, kept_as: "self" } : { candidate: c.id, valence };
    });
    try {
      // §10.5. The set is the challenge, so what the device signs is what the
      // person saw, in the canonical shape the engine compares.
      const challenge = await challengeFor(a.offer, decisions);
      const credential = (await navigator.credentials.get({
        publicKey: {
          challenge,
          rpId: location.hostname,
          allowCredentials: [{ type: "public-key", id: fromBase64(member.credential_id) }],
          userVerification: "required",
        },
      })) as PublicKeyCredential | null;
      if (!credential) throw new Error("no assertion was made");
      const r = credential.response as AuthenticatorAssertionResponse;
      const decided = await api<{ state?: string; error?: string; message?: string }>("POST", `/offers/${encodeURIComponent(a.offer)}/decisions`, {
        decisions,
        assertion: {
          authenticator_data: toBase64(r.authenticatorData),
          client_data_json: toBase64(r.clientDataJSON),
          signature: toBase64(r.signature),
        },
      });
      if (decided.status !== 200) throw new Error(`${decided.body.error ?? decided.status}: ${decided.body.message ?? ""}`);
      show(
        el("h1", {}, "Atarasy"),
        el("div", { class: "card" },
          el("p", {}, `Decided. ${decisions.filter((d) => d.valence === "kept").length} kept, ${decisions.filter((d) => d.valence === "returned").length} returned.`),
          el("p", { class: "muted" }, "What you returned is recorded as a decision of yours, not as nothing (clause 8).")),
        back(member)
      );
    } catch (e) {
      status.textContent = (e as Error).message;
      confirm.disabled = false;
    }
  };

  show(
    el("h1", {}, "Atarasy"),
    el("p", {}, `Offered by ${a.presenter}. Open until ${when(a.expires_at)}.`),
    el("p", { class: "muted" },
      a.mandate.kind === "standing"
        ? `Under a standing mandate: ${a.mandate.scope}, lapsing ${a.mandate.lapses_at ? when(a.mandate.lapses_at) : "never"} (clause 58).`
        : `Under an individual mandate: ${a.mandate.scope}.`),
    ...(a.price_band ? [el("p", { class: "muted" }, `The giver chose a band of ${yen(a.price_band.min)} to ${yen(a.price_band.max)} (clause 23).`)] : []),
    // Clause 33. Whether the one reminder has gone, never how many remain.
    ...(a.reminded ? [el("p", { class: "muted" }, "You were reminded once. There will be no second reminder.")] : []),
    ...cards,
    ...excluded,
    el("div", { class: "row" }, confirm, back(member)),
    status
  );
}

function back(member: Member) {
  const b = el("button", {}, "Back") as HTMLButtonElement;
  b.onclick = () => offers(member);
  return b;
}

const member = load();
if (member) offers(member); else setup();
