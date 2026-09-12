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
import { canonicalStatement, challengeFor, type Decision, type StatementLine } from "../shared/canonical.js";
import { canonicalMandate, type Mandate } from "../shared/mandate.js";
import { fromBase64, spkiToPem, toBase64, toBase64Url } from "../shared/encoding.js";
// The rule that sorts a member's own list, in a module the suite can reach:
// filing a collected box as settled was the worst thing this screen did.
import { awaitsDecision, awaitsStatement, byArrival, type InboxOffer } from "../shared/inbox.js";
// The sentences a refusal reads as, in a module the suite can reach: four of
// them directed the member wrongly and nothing here could have said so.
import { REFUSALS, refusal } from "../shared/refusals.js";
// The judgements the screens make, separated from the drawing of them: a
// reviewer reverted five of them at once and the suite stayed green.
import { blocksFor, decidable, disputable, statementTotal } from "../shared/screen.js";

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
    /**
     * Clause 12. **Who made it, which is not who sold it.** This type had no
     * `maker` and the card printed "Made by ${c.merchant}", so the screen a
     * person signs from named the seller as the maker while the statement
     * screen beside it named the real one: two screens, two makers, one line.
     * Question 32 made them different parties on 2026-09-12.
     */
    maker: string;
    ships: string;
    /**
     * Clause 10, §6.2. A gift is never billed, and this card used to print
     * `unit_price × quantity` beside every line with nothing naming a giver,
     * so a person was asked to sign without being told which lines cost money.
     */
    given_by: string | null;
    /** §10 step 3c. `offered` is a line still this household's to decide. */
    valence: string;
    is_exploration: boolean;
    alternatives: string[];
    argument_against: string;
    /** §10a.5. Which of the blocks below governs this line. */
    disclosure: { merchant: string; product: string | null };
  }[];
  /** §10a. Each merchant's own text, as it composed and signed it. */
  disclosures: { merchant: string; product: string | null; version: string; items: { label: string; value: string }[] }[];
  /** §10a.5, §7.5b. What carriage costs, from the hub's delivery record. */
  carriage: number | null;
  excluded: { product: string; reason: string }[];
};

/**
 * §6.5. The statement a household signs before a physical box with goods used
 * is charged. The collection's record proposes it; the signature is what makes
 * a consumed line a purchase, and until it arrives nothing is charged and this
 * presenter's next box does not come.
 */
type Statement = {
  offer: string;
  household: string;
  expires_at: number;
  lines: {
    candidate: string;
    product: string;
    merchant: string;
    maker: string;
    ships: string;
    given_by: string | null;
    valence: "kept" | "defaulted" | "consumed";
    quantity: number;
    unit_price: number;
    amount: number;
    disclosure: { merchant: string; product: string | null };
  }[];
  disclosures: { merchant: string; product: string | null; version: string; items: { label: string; value: string }[] }[];
  carriage: number | null;
};

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

/**
 * Every call the screen makes.
 *
 * **It never throws**, and that is the point. A rejected fetch or a body that
 * is not JSON used to come out of here as an exception, and the only handler
 * above it was the one around a signature: the list drew "Loading." for ever
 * when this hub was down or answered HTML, which is the one state a member
 * cannot tell from an empty inbox. Status `0` is "nothing answered", and every
 * caller already checks the status.
 */
async function api<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
  let response: Response;
  try {
    response = await fetch(`/api${path}`, {
      method,
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    return { status: 0, body: {} as T };
  }
  // **The body is read inside the guard too.** A connection that drops after
  // the headers and before the body ends rejects `text()`, and that rejection
  // used to escape this function past both catches, with no caller holding a
  // handler: "Loading." for ever, which is the state this function's own
  // comment says it exists to remove. Found by a refutation pass on
  // 2026-09-12, which is the second time this exact failure has been written.
  try {
    const text = await response.text();
    return { status: response.status, body: (text ? JSON.parse(text) : {}) as T };
  } catch {
    return { status: response.status, body: {} as T };
  }
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
          // **The handle is random, and it used to be the label the person
          // typed.** WebAuthn replaces a credential that shares an `rp.id` and
          // a `user.id`, so two people on one authenticator picking the same
          // name, or one person setting up twice, destroyed the earlier key:
          // the engine keeps the first key registered for a name and refuses a
          // later, different one (clause 22), so that household's decisions
          // could never be confirmed again by anything. A random handle makes
          // each setup its own account and leaves recovery to the discoverable
          // credential below, which is what actually carries the household.
          user: { id: crypto.getRandomValues(new Uint8Array(32)), name: label, displayName: label },
          // ES256 first, because that is what most phones and laptops carry;
          // EdDSA and RS256 after it. The engine checks by the registered key's type.
          pubKeyCredParams: [
            { type: "public-key", alg: -7 },
            { type: "public-key", alg: -8 },
            { type: "public-key", alg: -257 },
          ],
          // **"required", not "preferred", and the cost is named.** Coming
          // back to a household needs a discoverable credential, because
          // recovery asks the authenticator for any credential it holds for
          // this site. Under "preferred" an authenticator may make one that
          // is not discoverable, setup succeeds, and that member has no way
          // back and no way to know. An authenticator that cannot make one
          // now fails here instead, loudly.
          authenticatorSelection: { userVerification: "required", residentKey: "required" },
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
        if (registered.status !== 201) throw new Error(refusal(registered.body, registered.status));
      }
      const member: Member = { label, household, mandate, credential_id: credentialId };
      localStorage.setItem(STORAGE, JSON.stringify(member));
      await offers(member);
    } catch (e) {
      status.textContent = (e as Error).message;
      button.disabled = false;
    }
  };

  /**
   * §16.1. **Coming back, which there was no way to do.**
   *
   * The household and the mandate are derived from the credential's id, so the
   * credential is the household: a person holding the passkey holds everything
   * this browser's storage held. Until 2026-09-12 nothing asked for it. A
   * second device, a cleared browser or a tap on "Forget this device" created
   * a new household, and every offer placed with the old one, every protection
   * set under it and any statement waiting on it became unreachable, while the
   * shop that had been given the old identifier went on placing boxes nobody
   * could sign for. Found by a refutation pass over this hub.
   *
   * An empty `allowCredentials` asks the authenticator for any credential it
   * holds for this site, which is what `residentKey: "preferred"` above makes
   * possible. Nothing is registered here: the key is already the one the
   * engine knows, and re-registering would be refused (clause 22).
   */
  const again = el("button", {}, "Use a passkey I already have") as HTMLButtonElement;
  again.onclick = async () => {
    again.disabled = true;
    status.textContent = "";
    try {
      const credential = (await navigator.credentials.get({
        publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)),
          rpId: location.hostname,
          userVerification: "required",
        },
      })) as PublicKeyCredential | null;
      if (!credential) throw new Error("no passkey was offered");
      const credentialId = toBase64Url(credential.rawId);
      const member: Member = {
        label: input.value.trim() || `household-${credentialId.slice(0, 6)}`,
        household: `household-${credentialId}`,
        mandate: `mandate-${credentialId}`,
        credential_id: credentialId,
      };
      localStorage.setItem(STORAGE, JSON.stringify(member));
      await offers(member);
    } catch (e) {
      status.textContent = (e as Error).message;
      again.disabled = false;
    }
  };

  show(
    el("h1", {}, "Atarasy"),
    el("p", {}, "Nothing is offered to you until you have a key to answer with."),
    el("div", { class: "card" }, el("div", { class: "row" }, input, button), note, status),
    el("div", { class: "card" },
      el("p", {}, "Already have one, on this device or another?"),
      el("p", { class: "muted" }, "Your passkey is your household. Answering with it here brings back everything placed with it, wherever you last used it."),
      el("div", { class: "row" }, again))
  );
}

// ---- the offers waiting on the person ---------------------------------------

async function offers(member: Member) {
  let presenters: string[] = [];
  try {
    presenters = ((await (await fetch("/config")).json()) as { presenters: string[] }).presenters;
  } catch {
    // It is this hub that did not answer, not an engine: `/config` is served
    // here. Saying "the engine" sent the member looking in the wrong place.
    show(el("h1", {}, "Atarasy"), failure("This page could not reach the service that serves it, so nothing could be listed. Nothing was sent."), retry(member));
    return;
  }
  const waiting: InboxOffer[] = [];
  const decided: InboxOffer[] = [];
  const unsigned: InboxOffer[] = [];
  const problems: string[] = [];
  // Clause 8. Each presenter answers for its own offers to this household and
  // never for another's. The union is made here, on the person's side.
  for (const presenter of presenters) {
    const list = await api<{ offers?: InboxOffer[]; error?: string; message?: string }>(
      "GET",
      `/offers?household=${encodeURIComponent(member.household)}&presenter=${encodeURIComponent(presenter)}`
    );
    if (list.status !== 200) { problems.push(`${presenter}: ${refusal(list.body, list.status)}`); continue; }
    for (const o of list.body.offers ?? []) {
      // §6.5. A box whose collection found goods used waits for the
      // household's signature, and **it waits in the open**: from the
      // collection until the signature it stands here, reachable, rather than
      // being announced once and forgotten. A reminder would be the wrong
      // instrument, because a statement does not expire; what stops is
      // delivery, and a household that is not shown the waiting statement
      // learns only that a box did not come.
      if (awaitsStatement(o)) unsigned.push(o);
      else if (awaitsDecision(o)) waiting.push(o);
      else if (o.state === "decided") decided.push(o);
    }
  }
  waiting.sort(byArrival);
  decided.sort(byArrival);
  unsigned.sort(byArrival);

  const card = (o: InboxOffer) => {
    const open = el("button", { class: "primary" }, "Open") as HTMLButtonElement;
    open.onclick = () => approval(member, o.id, o.binding);
    return el("div", { class: "card" },
      el("div", { class: "row" },
        el("span", { class: "grow" }, o.giver ? `A gift from ${o.giver}, offered by ${o.presenter}` : `From ${o.presenter}`),
        open),
      // §11, `04b` §1b.3. **The two bindings say different things and one
      // sentence used to cover both.** A digital offer expires and nothing is
      // ordered if the person does nothing. A physical box is already in the
      // home, and what is used is bought whether or not this screen is ever
      // opened, so telling its owner that doing nothing orders nothing is
      // false about the one row where it matters.
      el("p", { class: "muted" },
        o.binding === "physical"
          ? "This box is with you. What you use is bought; what you send back is not."
          : `Waiting until ${when(o.expires_at)}. Nothing is ordered if you do nothing.`)
    );
  };
  // `04b` §1b.2. The two bindings are separated, and each is newest first.
  const boxes = waiting.filter((o) => o.binding === "physical").map(card);
  const cards = waiting.filter((o) => o.binding === "digital").map(card);

  // §16.5. A decided set waits out its cooling window before it can settle,
  // and the person can take it back while it does. Without a cooling window
  // there is no window to take it back into, which is what the protections
  // screen is for.
  const decidedCards = decided.map((o) => {
    // `04b` §1b.2 separates the bindings, and this was the one section that
    // did not: a digital set the household signed sat beside a box the
    // collection resolved, under one sentence about a window closing.
    //
    // **The button belongs only to the first of those.** Taking a decision
    // back is taking back something the household signed (§16.5); a box the
    // route resolved with nothing used carries no signed set, so offering to
    // withdraw it offers to withdraw a commitment that was never made, and
    // pressing it returns the box to `presented` and drops the row off this
    // screen. Found by a refutation pass on 2026-09-12.
    const box = o.binding === "physical";
    const said = el("p", { class: "muted" },
      box
        ? "The route has resolved this box. Nothing here is waiting on you."
        : "Decided. It settles when its window closes.");
    if (box) {
      return el("div", { class: "card" },
        el("div", { class: "row" }, el("span", { class: "grow" }, `From ${o.presenter}`)),
        said);
    }
    const undo = el("button", {}, "Take it back") as HTMLButtonElement;
    undo.onclick = async () => {
      undo.disabled = true;
      const taken = await api<{ error?: string; message?: string }>("DELETE", `/offers/${encodeURIComponent(o.id)}/decisions`);
      if (taken.status === 200) { await offers(member); return; }
      said.textContent = refusal(taken.body, taken.status);
      undo.disabled = false;
    };
    return el("div", { class: "card" },
      el("div", { class: "row" }, el("span", { class: "grow" }, `From ${o.presenter}`), undo),
      said);
  });
  // §6.5. The waiting statements, above everything else on this screen: a
  // household that does nothing here is one whose next box will not come, and
  // that is the one thing on this surface with a consequence attached.
  const unsignedCards = unsigned.map((o) => {
    const open = el("button", { class: "primary" }, "See what came back") as HTMLButtonElement;
    open.onclick = () => statement(member, o.id);
    return el("div", { class: "card" },
      el("div", { class: "row" }, el("span", { class: "grow" }, `From ${o.presenter}`), open),
      // Clause 11. **The presenter is not the seller.** A box is one
      // presenter's and several merchants', and §6.5 blocks the next box of
      // the presenter this one came from. Saying "this seller" told the
      // household that the wrong party had stopped delivering.
      el("p", { class: "muted" }, `The route found something used. Nothing is charged until you sign, and no further box comes from ${o.presenter} while it waits.`)
    );
  });
  const settings = el("button", {}, "What you have set") as HTMLButtonElement;
  settings.onclick = () => protections(member);
  const forget = el("button", {}, "Forget this device") as HTMLButtonElement;
  // §16.1. It forgets the browser's copy and not the household, which lives in
  // the passkey. The setup screen takes that passkey back, and this used to
  // be a one-way door with nothing on the screen saying so.
  forget.onclick = () => { localStorage.removeItem(STORAGE); setup(); };
  // **Nothing waiting and nothing answering are different things**, and one
  // screen used to draw them together: a presenter that failed put a card at
  // the foot of the page while "Nothing is waiting for you." stood above it.
  // A member cannot act on a list that is silent about how much of it is
  // missing.
  const partial = problems.length > 0;
  const empty = !boxes.length && !cards.length;
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
    ...problems.map((p) => failure(p)),
    ...(unsignedCards.length ? [el("h2", {}, "Waiting for your signature"), ...unsignedCards] : []),
    ...(boxes.length ? [el("h2", {}, "Boxes with you now"), ...boxes] : []),
    ...(cards.length ? [el("h2", {}, "Offered to you"), ...cards] : []),
    ...(empty
      ? [el("p", {}, partial
          ? "Nothing is waiting for you from the shops that answered. What the card above names did not answer, so this list is not the whole of it."
          : "Nothing is waiting for you.")]
      : []),
    ...(decidedCards.length ? [el("h2", {}, "Decided, and not yet settled"), ...decidedCards] : []),
    el("div", { class: "row" }, settings, forget)
  );
}

/** When nothing answered at all, the one thing left to offer is another try. */
function retry(member: Member) {
  const b = el("button", { class: "primary" }, "Try again") as HTMLButtonElement;
  b.onclick = () => offers(member);
  return b;
}


/**
 * §10a, §10a.5. The block a line is governed by, drawn beside that line and
 * nowhere else.
 *
 * **The hub renders and never composes.** The items come back in the
 * merchant's own order and are drawn as they are: no shortening, no
 * translating, no folding behind a tap, because each of those would be this
 * surface deciding what a seller said. Which block governs a line is on the
 * line (`disclosure`), so this looks the block up rather than guessing.
 */
function blockFor(
  blocks: { merchant: string; product: string | null; items: { label: string; value: string }[] }[],
  which: { merchant: string; product: string | null }
): Node[] {
  const governing = blocksFor(blocks, which);
  if (governing.length === 0) {
    // §10a.3 refuses an offer with no block long before a screen is drawn, so
    // this is a hub reading a response it should never receive. Saying so is
    // better than drawing a sale with no terms beside it.
    return [failure(`${which.merchant} sent no terms for this line.`)];
  }
  const nodes: Node[] = [];
  for (const { block, scope } of governing) {
    nodes.push(el("p", { class: "muted" },
      scope === "product"
        ? `${which.merchant}, for this product:`
        : governing.length > 1 ? `${which.merchant}, in general:` : `${which.merchant}:`));
    nodes.push(el("dl", { class: "terms" },
      ...block.items.flatMap((i) => [el("dt", {}, i.label), el("dd", {}, i.value)])));
  }
  return nodes;
}

// ---- the approval screen (§10 step 3 and 4) ---------------------------------

/**
 * `04b` §2.2b. **A deadline means different things in the two bindings**, and
 * the binding is not on the approval contract, so the list row that opened
 * this screen passes it.
 *
 * Digital: an undecided candidate becomes `returned` at expiry, so the person
 * loses nothing by letting it close and a date is the right thing to show.
 * Physical: the goods are in the home, `lost` is never billed (§3.2), and what
 * resolves the box is the collection rather than the deadline, so **the
 * deadline is not the person's event.** This screen said "Open until" for both
 * until 2026-09-12, which is the same category error the list row carried and
 * which was found by driving the screen rather than by any suite.
 *
 * **The expiry stays on the screen either way**, because §10a.5 counts it among
 * the facts of the sale and a merchant's stated application period is measured
 * against it. What changes is whether it is framed as the person's deadline.
 */
async function approval(member: Member, offerId: string, binding?: "digital" | "physical") {
  const got = await api<Approval & { error?: string; message?: string }>("GET", `/offers/${encodeURIComponent(offerId)}/approval`);
  if (got.status !== 200) {
    show(el("h1", {}, "Atarasy"), failure(refusal(got.body, got.status)), back(member));
    return;
  }
  const a = got.body;
  const choices = new Map<string, "kept" | "returned">();
  const confirm = el("button", { class: "primary" }, "Confirm with your passkey") as HTMLButtonElement;
  confirm.disabled = true;
  const status = el("p", {});
  // §10 step 3c. **Only the lines still waiting on this household are asked
  // about.** A physical box is collected line by line and the offer stays
  // presented, so an approval routinely carries a line the route already
  // found used beside one nobody has decided. This screen used to require a
  // choice on every candidate and post the lot, which the engine refused with
  // `already_decided` naming a candidate id: the member could never confirm
  // the lines that were still theirs, from the only screen that offers to.
  const { open, resolved: settled } = decidable(a.candidates);
  const refresh = () => { confirm.disabled = choices.size !== open.length || open.length === 0; };

  const cards = a.candidates.map((c) => {
    const decidable = c.valence === "offered";
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
        // Clause 10, §6.2. A gift arrives at its price and is never billed, so
        // the card says so instead of printing a figure nobody will be charged.
        el("span", {}, c.given_by ? "a gift" : yen(c.unit_price * c.quantity))),
      // Clause 12. The maker and the carrier are on the screen the person
      // signs from, and the maker is not the merchant.
      el("p", { class: "muted" },
        c.given_by
          ? `Given by ${c.given_by}. Never billed to you (clause 10). Made by ${c.maker}, carried by ${c.ships}.`
          : `Sold by ${c.merchant}, made by ${c.maker}. Carried by ${c.ships}.`),
      ...(decidable ? [] : [el("p", { class: "muted" },
        c.valence === "consumed"
          ? "The route found this used, so it is not yours to decide here. It comes back on the statement you sign."
          : `Already ${c.valence}. Nothing on this screen changes it.`)]),
      ...(c.is_exploration ? [el("p", { class: "exploration" }, "Something you have not been offered before (§5).")] : []),
      // Clauses 54 and 59. **These are the presenter's words, and the screen
      // says so.** The alternatives and the argument against are free text the
      // presenter's agent supplied, rendered here under headings this hub
      // wrote, on a surface a party to no transaction draws. Without the
      // attribution a person reads "you have two of these already" as their own
      // agent's finding when it is the merchant's sentence, and a proposal
      // whose maker cannot be weighed is the thing clause 59 exists against.
      el("p", {}, el("span", { class: "muted" }, `${a.presenter} argues against taking it: `), c.argument_against),
      el("p", { class: "muted" }, `${a.presenter} says it also considered:`),
      el("ul", {}, ...c.alternatives.map((alt) => el("li", {}, alt))),
      // §10a.5. This merchant's terms, beside this merchant's line and no
      // other. One screen carries several sellers' blocks, and each seller
      // answers for the whole 映像面 it appears on.
      ...blockFor(a.disclosures ?? [], c.disclosure),
      ...(decidable ? [el("div", { class: "row" }, keep, ret)] : [])
    );
  });

  const excluded = a.excluded.length
    ? [el("h2", {}, "Left out, and why (clause 36)"),
       el("ul", {}, ...a.excluded.map((x) => el("li", {}, `${x.product}: ${RULES[x.reason] ?? x.reason}`)))]
    : [];

  confirm.onclick = async () => {
    confirm.disabled = true;
    status.textContent = "";
    const decisions: Decision[] = open.map((c) => {
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
      if (decided.status !== 200) throw new Error(refusal(decided.body, decided.status));
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
    ...(binding === "physical"
      ? [el("p", {}, `Offered by ${a.presenter}. This box is with you: what you use is bought, and what you send back is not.`),
         el("p", { class: "muted" }, `It was offered until ${when(a.expires_at)}.`)]
      : [el("p", {}, `Offered by ${a.presenter}. Open until ${when(a.expires_at)}.`)]),
    el("p", { class: "muted" },
      a.mandate.kind === "standing"
        ? `Under a standing mandate: ${a.mandate.scope}, lapsing ${a.mandate.lapses_at ? when(a.mandate.lapses_at) : "never"} (clause 58).`
        : `Under an individual mandate: ${a.mandate.scope}.`),
    ...(a.price_band ? [el("p", { class: "muted" }, `The giver chose a band of ${yen(a.price_band.min)} to ${yen(a.price_band.max)} (clause 23).`)] : []),
    // Clause 33. Whether the one reminder has gone, never how many remain.
    ...(a.reminded ? [el("p", { class: "muted" }, "You were reminded once. There will be no second reminder.")] : []),
    // §10a.5, 法11条1号. The carriage is a line of its own beside the goods,
    // never folded into a price and never the word "free". Nothing recorded
    // is said as nothing recorded, because a screen that showed no carriage
    // would say the price includes it.
    el("p", { class: "muted" },
      a.carriage === null
        ? "Carriage: not recorded yet."
        : a.carriage === 0
          ? "Carriage: nothing to pay on this delivery."
          : `Carriage: ${yen(a.carriage)}.`),
    // §10 step 3c. Where the route has already resolved part of the box, the
    // screen says which part is still the person's rather than offering a
    // button that can never be pressed.
    ...(settled.length
      ? [el("p", { class: "muted" },
          open.length
            ? `${settled.length} of these ${settled.length === 1 ? "line has" : "lines have"} already been settled by what the route found. ${open.length} ${open.length === 1 ? "is" : "are"} still yours to decide.`
            : "Nothing on this screen is still yours to decide. Every line has already been resolved, by you, by the route, or by the deadline passing.")]
      : []),
    ...cards,
    ...excluded,
    el("div", { class: "row" }, ...(open.length ? [confirm] : []), back(member)),
    status
  );
}

// ---- the settlement statement (§6.5) ----------------------------------------

/**
 * The screen a household signs a physical settlement from. Question 36.
 *
 * **The collection's record is a proposal and this signature is the
 * application.** A box came back, the route wrote down what was used, and
 * until this is signed nothing is charged and this presenter's next box does
 * not come. The household confirms the statement as proposed or marks
 * consumed lines disputed and signs the rest; it cannot add a line, remove
 * one, change an amount, or dispute a line it kept, which it signed already.
 *
 * A disputed line leaves the rail. That is said here in words rather than
 * implied, because leaving the rail is not the same as owing nothing: what is
 * owed for it is between the household and the merchant, and a screen that
 * let a person think otherwise would be this hub answering for a contract it
 * is not party to (clause 54).
 */
async function statement(member: Member, offerId: string) {
  const got = await api<Statement & { error?: string; message?: string }>("GET", `/offers/${encodeURIComponent(offerId)}/statement`);
  if (got.status !== 200) {
    show(el("h1", {}, "Atarasy"), failure(refusal(got.body, got.status)), back(member));
    return;
  }
  const st = got.body;
  const disputed = new Set<string>();
  const status = el("p", {});
  const sign = el("button", { class: "primary" }, "Confirm with your passkey") as HTMLButtonElement;

  const total = () => statementTotal(st.lines, disputed);
  const totalLine = el("p", {});
  const refreshTotal = () => {
    // §7.5b. **The total is the goods and the carriage is beside it**, and the
    // screen used to print the two figures with nothing between them saying
    // which was inside which: a household reading "Carriage: ¥500" above "To
    // be charged: ¥900" could not tell whether it owed 900 or 1,400. The
    // engine's `charged` excludes the carriage, so the screen says so.
    totalLine.textContent = `To be charged for the goods: ${yen(total())}.` +
      (st.carriage ? ` The carriage above is not in this figure.` : "") +
      (disputed.size ? ` ${disputed.size} line${disputed.size === 1 ? "" : "s"} disputed and not charged here.` : "");
  };

  const cards = st.lines.map((l) => {
    const mark = el("button", {}, "I did not use this") as HTMLButtonElement;
    const note = el("p", { class: "muted" }, "");
    const paint = () => {
      const isDisputed = disputed.has(l.candidate);
      mark.className = isDisputed ? "chosen" : "";
      mark.textContent = isDisputed ? "Disputed" : "I did not use this";
      note.textContent = isDisputed
        ? "Not charged here. What is owed for it, if anything, is between you and the seller."
        : "";
      refreshTotal();
    };
    mark.onclick = () => {
      if (disputed.has(l.candidate)) disputed.delete(l.candidate);
      else disputed.add(l.candidate);
      paint();
    };
    const wasKept = !disputable(l);
    return el("div", { class: "card" },
      el("div", { class: "row" },
        el("strong", { class: "grow" }, `${l.product} × ${l.quantity}`),
        el("span", {}, l.given_by ? "a gift" : yen(l.amount))),
      // Clause 10. A gift arrives at its price and is never billed, and the
      // screen says who gave it rather than leaving a zero to be read as luck.
      el("p", { class: "muted" },
        l.given_by
          ? `Given by ${l.given_by}. Never billed to you (clause 10).`
          : `${yen(l.unit_price)} each. Sold by ${l.merchant}, made by ${l.maker}.`),
      el("p", { class: "muted" },
        wasKept
          ? "You kept this when you decided. It is here because it is on the same bill."
          : "The collection found this used."),
      ...blockFor(st.disclosures ?? [], l.disclosure),
      // §11.2. Only a consumed line can be disputed: a kept line is one this
      // household signed itself.
      ...(wasKept ? [] : [el("div", { class: "row" }, mark), note])
    );
  });
  refreshTotal();

  sign.onclick = async () => {
    sign.disabled = true;
    status.textContent = "";
    try {
      const lines: StatementLine[] = st.lines.map((l) => ({
        candidate: l.candidate,
        valence: l.valence,
        amount: l.amount,
        disputed: l.valence === "consumed" && disputed.has(l.candidate),
      }));
      const bytes = new TextEncoder().encode(canonicalStatement(st.offer, lines));
      const assertion = await assertOver(member, new Uint8Array(bytes));
      const settled = await api<{ charged?: number; disputed_amount?: number; error?: string; message?: string }>(
        "POST",
        `/offers/${encodeURIComponent(st.offer)}/settle`,
        { assertion, disputed: [...disputed] }
      );
      if (settled.status !== 200) {
        // §6.5. **A box that has already settled is one this member may have
        // settled themselves**, a moment ago, with an answer that never
        // arrived. Refusing and stopping there left them charged with no
        // screen anywhere that could say for what: the row is `settled`, so
        // it is on no list, and signing again only repeats the refusal.
        // Measured by a refutation pass on 2026-09-12.
        if (settled.body.error === "already_settled") {
          const stood = await api<Receipt & { error?: string; message?: string }>(
            "GET",
            `/offers/${encodeURIComponent(st.offer)}/settlement`
          );
          if (stood.status === 200) {
            show(el("h1", {}, "Atarasy"), receipt(stood.body, true), back(member));
            return;
          }
        }
        throw new Error(refusal(settled.body, settled.status));
      }
      show(el("h1", {}, "Atarasy"), receipt(settled.body, false), back(member));
    } catch (e) {
      status.textContent = (e as Error).message;
      sign.disabled = false;
    }
  };

  show(
    el("h1", {}, "Atarasy"),
    el("h2", {}, "What the box came back with"),
    // Clause 11. Whoever sent the box is the presenter, and a presenter is not
    // the seller: this box is one presenter's and several merchants'. The
    // statement names the merchants line by line and carries no presenter, so
    // the sentence names neither rather than naming the wrong one.
    el("p", { class: "muted" }, "The route wrote this down. Nothing is charged until you sign it, and no further box comes from whoever sent this one while it waits."),
    // §6.5, §10a.5. **The offer's expiry, because a merchant's block may state
    // an application period and a period is measured against something.** The
    // engine has carried it since this route was written and this screen
    // dropped it, so a block reading "apply within 7 days of the offer" stood
    // beside no date at all.
    el("p", { class: "muted" }, `This box was offered until ${when(st.expires_at)}.`),
    el("p", { class: "muted" },
      st.carriage === null
        ? "Carriage: not recorded."
        : st.carriage === 0
          ? "Carriage: nothing to pay on this delivery."
          : `Carriage: ${yen(st.carriage)}.`),
    ...cards,
    totalLine,
    el("div", { class: "row" }, sign, back(member)),
    status
  );
}

/** §6.5. What a settlement came to, as the member reads it. */
type Receipt = { charged?: number; disputed_amount?: number; settled_at?: number };

/**
 * §6.5. What was charged, drawn identically whether this signature made it or
 * found it already standing. **The second case is not an error to the member**:
 * it is their own earlier act, and the only wrong answer is silence about the
 * amount.
 */
function receipt(r: Receipt, stood: boolean): Node {
  return el("div", { class: "card" },
    el("p", {},
      stood
        ? `Already settled${r.settled_at ? ` on ${when(r.settled_at)}` : ""}. ${yen(r.charged ?? 0)} was charged.`
        : `Signed. ${yen(r.charged ?? 0)} charged.`),
    ...(stood
      ? [el("p", { class: "muted" }, "If you signed this a moment ago and the answer never came back, this is that signature. Nothing was charged twice.")]
      : []),
    ...(r.disputed_amount
      ? [el("p", { class: "muted" }, `${yen(r.disputed_amount)} was disputed and is not charged here. What is owed for it, if anything, is between you and the seller.`)]
      : []));
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
  const read = await api<Mandate & { error?: string; message?: string }>("GET", `/_node/mandates/${encodeURIComponent(member.mandate)}`);
  // **A record that could not be read is not a record that is absent**, and
  // this screen used to draw both as "Nothing yet": a member whose engine was
  // unreachable was shown a blank protections screen and would have set a
  // ceiling over a record it could not see, on version 1 of a mandate already
  // at version 4.
  if (read.status !== 200 && read.status !== 404) {
    show(el("h1", {}, "Atarasy"), failure(refusal(read.body, read.status)), back(member));
    return;
  }
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
  async function write(patch: Partial<Mandate>, loosening: string | null) {
    status.textContent = "";
    try {
      if (loosening) {
        throw new Error(
          loosening +
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
      if (recorded.status !== 201) throw new Error(refusal(recorded.body, recorded.status));
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
