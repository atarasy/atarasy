/**
 * The screen. Clauses 33, 35, 36, 54, 58 and 59, and specification §10.
 *
 * It renders what `GET /offers/{id}/approval` returns, and the presenter and
 * giver of each waiting offer from `GET /offers`, and nothing the presenter
 * could have drawn: text from data fields, in the hub's own type. The order
 * of the candidates, of the alternatives and of the exclusions is the order
 * the presenter's agent sent, which is the one thing on this screen a
 * presenter chooses; it is a list of text either way. A candidate is kept or
 * returned by the person's own tap, the set is confirmed once, and the
 * confirmation is the passkey's assertion over the set (§10.5), made by the
 * browser's own authenticator. This page never sees a private key.
 */
import { challengeFor, type Decision } from "../shared/canonical.js";
import { canonicalMandate, type Mandate } from "../shared/mandate.js";
import { fromBase64, spkiToPem, toBase64, toBase64Url } from "../shared/encoding.js";

type Member = {
  /** What the person typed. This browser's own label, and nobody else's business. */
  label: string;
  /**
   * §16.1. The identifier a shop is given, derived from the credential like
   * the mandate reference and for the same reason: a mandate record is signed
   * by the key registered under the household's name, so a guessable name is
   * a name a stranger can register first, and the household's protections
   * would then be theirs to write.
   */
  household: string;
  mandate: string;
  credential_id: string;
};

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
  // Not "stays on this device": a platform authenticator may sync the key
  // through the person's own account (iCloud Keychain, Google Password
  // Manager), and telling them otherwise on the screen would be false.
  const note = el("p", { class: "muted" }, "The passkey is held by this browser's authenticator and never leaves it for us. Its public half is registered as the key that confirms your decisions (clause 35).");
  const status = el("p", {});
  button.onclick = async () => {
    button.disabled = true;
    const label = input.value.trim();
    if (!label) { status.textContent = "The household needs a name."; button.disabled = false; return; }
    try {
      const credential = (await navigator.credentials.create({
        publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)),
          rp: { name: "Atarasy", id: location.hostname },
          user: { id: new TextEncoder().encode(label), name: label, displayName: label },
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
      const credentialId = toBase64Url(credential.rawId);
      // Both names are the credential's, so that nobody can register a key
      // under either first. The engine keeps the first key registered for a
      // name and refuses a later, different one (clause 22), which turns a
      // guessable name into a name somebody else can take: the mandate
      // reference confirms this household's decisions (§10.5) and the
      // household's own name signs its protections (§16.1).
      const mandate = `mandate-${credentialId}`;
      const household = `household-${credentialId}`;
      const pem = spkiToPem(spki);
      for (const key of [mandate, household]) {
        const registered = await api<{ error?: string; message?: string }>("POST", "/_identities", { key, public_key: pem });
        if (registered.status !== 201) throw new Error(registered.body.message ?? `registering ${key} answered ${registered.status}`);
      }
      const member: Member = { label, household, mandate, credential_id: credentialId };
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
  const decided: OfferSummary[] = [];
  const problems: string[] = [];
  // Clause 8. Each presenter answers for its own offers to this household and
  // never for another's. The union is made here, on the person's side.
  for (const presenter of config.presenters) {
    const list = await api<{ offers?: OfferSummary[]; message?: string }>(
      "GET",
      `/offers?household=${encodeURIComponent(member.household)}&presenter=${encodeURIComponent(presenter)}`
    );
    if (list.status !== 200) { problems.push(`${presenter}: ${list.body.message ?? list.status}`); continue; }
    for (const o of list.body.offers ?? []) {
      if (o.state === "presented") waiting.push(o);
      if (o.state === "decided") decided.push(o);
    }
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

  // §16.5. A decided set waits out its cooling window before it can settle,
  // and the person can take it back while it does. Without a cooling window
  // there is no window to take it back into, which is what the protections
  // screen is for.
  const decidedCards = decided.map((o) => {
    const undo = el("button", {}, "Take it back") as HTMLButtonElement;
    const said = el("p", { class: "muted" }, "Decided. It settles when its window closes.");
    undo.onclick = async () => {
      undo.disabled = true;
      const taken = await api<{ error?: string; message?: string }>("DELETE", `/offers/${encodeURIComponent(o.id)}/decisions`);
      if (taken.status === 200) { await offers(member); return; }
      said.textContent =
        taken.body.error === "no_cooling"
          ? "You have set no cooling window, so a decision is final as soon as it is signed."
          : taken.body.error === "cooling_over"
            ? "The window has closed and the decision is final."
            : taken.body.message ?? `taking it back answered ${taken.status}`;
      undo.disabled = false;
    };
    return el("div", { class: "card" },
      el("div", { class: "row" }, el("span", { class: "grow" }, `From ${o.presenter}`), undo),
      said);
  });
  const settings = el("button", {}, "What you have set") as HTMLButtonElement;
  settings.onclick = () => protections(member);
  const forget = el("button", {}, "Forget this device") as HTMLButtonElement;
  forget.onclick = () => { localStorage.removeItem(STORAGE); setup(); };
  show(
    el("h1", {}, "Atarasy"),
    el("p", { class: "muted" }, `${member.label}. Decisions are confirmed with this browser's passkey.`),
    // An offer names the household it is placed with and the mandate it is
    // made under, and how a presenter comes to know either is between the
    // household and the presenter. So the person is shown both rather than
    // left to find them. Neither is a secret and neither is guessable.
    el("p", { class: "muted" }, "What a shop needs before it can offer you anything."),
    el("ul", {},
      el("li", {}, "household ", el("code", {}, member.household)),
      el("li", {}, "mandate ", el("code", {}, member.mandate))),
    ...(cards.length ? cards : [el("p", {}, "Nothing is waiting for you.")]),
    ...(decidedCards.length ? [el("h2", {}, "Decided, and not yet settled"), ...decidedCards] : []),
    ...problems.map((p) => failure(p)),
    el("div", { class: "row" }, settings, forget)
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
      // Clause 12. The maker and the carrier are on the screen the person
      // signs from.
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

/**
 * §10.5, §16.1. What the device sends where the specification asks the person
 * to sign: an assertion whose challenge is the canonical bytes. A passkey
 * cannot sign bytes a caller hands it, so this is the only shape a member of
 * this hub can produce, and it is the one shape both routes take.
 */
async function assertOver(member: Member, bytes: Uint8Array<ArrayBuffer>) {
  const challenge = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
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
  return {
    authenticator_data: toBase64(r.authenticatorData),
    client_data_json: toBase64(r.clientDataJSON),
    signature: toBase64(r.signature),
  };
}

// ---- the protections a person sets for themselves (§16) ---------------------

/** §16.5. How long a decided set waits, and how long it can be taken back. */
const COOLING = [
  ["none", null],
  ["an hour", 3600],
  ["a day", 86400],
] as const;

/** §16.3. What may settle for this household in one day, across every presenter. */
const DAILY = [
  ["no ceiling", null],
  ["¥3,000", 3000],
  ["¥10,000", 10000],
  ["¥30,000", 30000],
] as const;

async function protections(member: Member) {
  const read = await api<Mandate & { error?: string }>("GET", `/_node/mandates/${encodeURIComponent(member.mandate)}`);
  const current: Mandate | null = read.status === 200 ? read.body : null;
  const status = el("p", {});

  /**
   * §16.1, clause 47. Every button here writes a whole version of the record,
   * because that is what is signed: a change to one protection is a signature
   * over all of them, and a screen that sent a field would be asking the
   * person to sign something it had not shown them.
   *
   * A tightening is the person's alone. This screen offers nothing that
   * loosens, and says who would have to be asked rather than pretending the
   * move does not exist.
   */
  async function write(patch: Partial<Mandate>, refusal: string | null) {
    status.textContent = "";
    try {
      if (refusal) {
        throw new Error(
          refusal +
            (current && current.co_signers.length > 0
              ? `, and needs everyone you named: ${current.co_signers.join(", ")}`
              : ", and this screen does not do it")
        );
      }
      // A renewal moves the lapse later, which is a loosening, so it needs the
      // people the person named. With nobody named it is theirs alone.
      const renewal =
        current && current.co_signers.length > 0
          ? current.lapses_at
          : Date.now() + 365 * 86_400_000;
      const next: Mandate = {
        id: member.mandate,
        household: member.household,
        ceiling_out_of_network: current?.ceiling_out_of_network ?? 100000,
        ceiling_daily: current?.ceiling_daily ?? null,
        co_sign_categories: current?.co_sign_categories ?? [],
        cooling_seconds: current?.cooling_seconds ?? null,
        co_signers: current?.co_signers ?? [],
        // Clause 58. A standing mandate lapses unless renewed, and this is the
        // renewal: every version this screen writes puts the lapse a year out.
        // Carrying the old date forward would have stopped every offer to this
        // household on the day it passed, with every button on this screen
        // answering an error and none of them able to move the date.
        lapses_at: renewal,
        version: (current?.version ?? 0) + 1,
        ...patch,
      };
      const bytes = new TextEncoder().encode(canonicalMandate(next));
      const recorded = await api<{ error?: string; message?: string }>("POST", "/_node/mandates", {
        ...next,
        assertions: { [member.household]: await assertOver(member, bytes) },
      });
      if (recorded.status !== 201) throw new Error(recorded.body.message ?? `the record answered ${recorded.status}`);
      await protections(member);
    } catch (e) {
      status.textContent = (e as Error).message;
    }
  }

  // §16.5. How long a decided set waits before it can settle, and can be taken
  // back while it waits.
  const coolingRow: Node[] = [];
  for (const [label, seconds] of COOLING) {
    const chosen = current?.cooling_seconds === seconds || (current === null && seconds === null);
    const b = el("button", { class: chosen ? "chosen" : "" }, label);
    b.onclick = () =>
      write(
        { cooling_seconds: seconds },
        current && !longer(current.cooling_seconds, seconds)
          ? "shortening or removing a cooling window is a loosening"
          : null
      );
    coolingRow.push(b);
  }

  // §16.3. What may settle for this household in one day, across every
  // presenter. Absent is not zero: no ceiling refuses nothing and a ceiling of
  // zero refuses everything, and the signed bytes tell them apart.
  const dailyRow: Node[] = [];
  for (const [label, yenPerDay] of DAILY) {
    const chosen = current?.ceiling_daily === yenPerDay || (current === null && yenPerDay === null);
    const b = el("button", { class: chosen ? "chosen" : "" }, label);
    b.onclick = () =>
      write(
        { ceiling_daily: yenPerDay },
        current && !lower(current.ceiling_daily, yenPerDay)
          ? "raising or removing a daily ceiling is a loosening"
          : null
      );
    dailyRow.push(b);
  }

  show(
    el("h1", {}, "Atarasy"),
    el("h2", {}, "What you have set for yourself"),
    el("p", { class: "muted" },
      current
        ? `Version ${current.version}. Nothing here can be loosened without the people you named (clause 47).`
        : "Nothing yet. What you set here is yours to tighten alone, and needs the people you named to loosen."),
    el("div", { class: "card" },
      el("p", {}, "How long a decision waits before it can settle, and can be taken back."),
      el("div", { class: "row" }, ...coolingRow)),
    el("div", { class: "card" },
      el("p", {}, "The most that may be settled for you in one day, across every shop."),
      el("div", { class: "row" }, ...dailyRow)),
    // Clause 58, clause 46. What the person is signing besides the button they
    // pressed. A screen that hides the rest of the record asks for a signature
    // over things the person never saw.
    ...(current
      ? [el("p", { class: "muted" },
          `Also in what you signed: nothing offered to you may cost more than ${yen(current.ceiling_out_of_network)} at a shop outside the network, and this lapses on ${new Date(current.lapses_at).toDateString()} unless you set something again.`)]
      : [el("p", { class: "muted" }, "Setting one of these also records a ceiling of ¥100,000 on an offer from outside the network, and a lapse a year from now.")]),
    status,
    back(member)
  );
}
/** A longer window, or one where there was none, is a tightening. */
const longer = (before: number | null, after: number | null) =>
  after !== null && (before === null || after > before);

/**
 * A lower ceiling, or one where there was none, is a tightening. Absent is the
 * weakest value rather than zero, which is the same rule the canonical form
 * keeps: no daily ceiling refuses nothing, and a ceiling of zero refuses
 * everything.
 */
const lower = (before: number | null, after: number | null) =>
  after !== null && (before === null || after < before);

function back(member: Member) {
  const b = el("button", {}, "Back") as HTMLButtonElement;
  b.onclick = () => offers(member);
  return b;
}

const member = load();
if (member) offers(member); else setup();
