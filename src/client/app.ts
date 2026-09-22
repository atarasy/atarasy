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
 * confirmation is the person's signature over the set (§10.5), made with the
 * key the passkey releases after they verify (`signOver`). This page holds
 * that key for the length of one signature; the hub's server never sees it.
 */
import { canonicalDecisions, canonicalExport, canonicalLeave, canonicalStatement, canonicalWithdrawal, type Decision, type StatementLine } from "../shared/canonical.js";
import { canonicalMandate, type Mandate } from "../shared/mandate.js";
import { fromBase64, memberKeyFromHandle, newMemberKey, toBase64, toBase64Url } from "../shared/encoding.js";
// The rule that sorts a member's own list, in a module the suite can reach:
// filing a collected box as settled was the worst thing this screen did.
import { awaitsDecision, awaitsStatement, byArrival, holdsNextBox, type InboxOffer } from "../shared/inbox.js";
// The sentences a refusal reads as, in a module the suite can reach: four of
// them directed the member wrongly and nothing here could have said so.
import { REFUSALS, refusal } from "../shared/refusals.js";
// The judgements the screens make, separated from the drawing of them: a
// reviewer reverted five of them at once and the suite stayed green.
import { blocksFor, decidable, disputable, disputeMovesMoney, lostOutcome, statementTotal, validateCorrections, type Corrections } from "../shared/screen.js";

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
    /** §3, question 48. What the collection named this line; absent from an engine before the field. */
    collected_as?: "returned" | "consumed" | "missing" | null;
    is_exploration: boolean;
    alternatives: string[];
    argument_against: string;
    /** §10a.5. Which of the blocks below governs this line. */
    disclosure: { merchant: string; product: string | null };
  }[];
  /** §10a. Each merchant's own text, as it composed and signed it. */
  disclosures: {
    merchant: string;
    product: string | null;
    version: string;
    items: { label: string; value: string }[];
    /** §10a.7, question 72. Absent where the merchant gave none. */
    contact?: { kind: "email" | "tel" | "url"; value: string };
  }[];
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
    /**
     * `lost` is a line the collection recorded missing (question 46). It is
     * at 0, it is never charged, and the household may dispute it.
     */
    valence: "kept" | "defaulted" | "consumed" | "lost";
    quantity: number;
    unit_price: number;
    amount: number;
    /**
     * Question 46. The collection's note for a missing line, null otherwise.
     * Optional because an engine from before question 46 sends no such field.
     */
    note?: string | null;
    disclosure: { merchant: string; product: string | null };
  }[];
  disclosures: {
    merchant: string;
    product: string | null;
    version: string;
    items: { label: string; value: string }[];
    /** §10a.7, question 72. Absent where the merchant gave none. */
    contact?: { kind: "email" | "tel" | "url"; value: string };
  }[];
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

async function setup(notice?: Node) {
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
      // §13.2, question 55. The household is the name of a key, and a `get`
      // never hands the public key back, so the key is made here and its
      // parts ride in the user handle that every later assertion returns.
      const made = await newMemberKey();
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
          user: { id: made.handle, name: label, displayName: label },
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
      const credentialId = toBase64Url(credential.rawId);
      // §13.2, question 55. One registration, under the name the key has, and
      // nothing under the mandate's: a mandate has no key of its own, and its
      // identifier is this one with a label. Nobody can hold either by filing
      // it first, which is what the credential id used to be relied on for.
      const household = made.household;
      const mandate = made.mandate;
      const registered = await api<{ error?: string; message?: string }>("POST", "/_identities", { key: household, public_key: made.pem });
      if (registered.status !== 201) throw new Error(refusal(registered.body, registered.status));
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
   * holds for this site, which is what `residentKey: "required"` above makes
   * possible. The key is registered here, because a household that moved to
   * this host (clause 52) arrives with its rows and without its key, and the
   * same key under the name it has is not a conflict (§13.2).
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
      // §13.2, question 55. The household is the name of a key, and the key
      // is in the handle the authenticator just returned. A passkey made
      // elsewhere carries a handle of another length and is refused here
      // rather than becoming a household nothing answers for.
      const handle = (credential.response as AuthenticatorAssertionResponse).userHandle;
      if (!handle) throw new Error("this passkey carries no household");
      const known = await memberKeyFromHandle(handle);
      // Clause 52. A household that moved arrives at a host that holds its
      // rows and not its key, and this flow registered nothing on the reasoning
      // that the key was already the one the engine knew. That is true of the
      // host it left. Registering is safe and idempotent now, because the name
      // proves the key and the same key under the same name is not a conflict.
      // Named by a review pass on 2026-09-16.
      await api("POST", "/_identities", { key: known.household, public_key: known.pem });
      const member: Member = {
        label: input.value.trim() || `household-${credentialId.slice(0, 6)}`,
        household: known.household,
        mandate: known.mandate,
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
    ...(notice ? [notice] : []),
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
    // **A status is not a body, here too.** An unreadable `200` gave
    // `offers: undefined`, which `?? []` turned into an empty inbox: the
    // member read that nothing was waiting for them. Found by a fourth
    // refutation round on 2026-09-13, which measured it on four screens.
    if (list.status !== 200 || !Array.isArray(list.body.offers)) {
      problems.push(`${presenter}: ${list.status === 200
        ? "answered in a form this screen could not read, so what is waiting there is not on this list"
        : refusal(list.body, list.status)}`);
      continue;
    }
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
      // `04b` §1b.3, §2.2b, question 44 decided 2026-09-13. **The date a box's
      // owner needs is the swap, and it is the offer's expiry.** The engine
      // opens the recovery with the offer's own expiry as its due date, so the
      // two are one number wearing two names; what §2.2b asks for is not a
      // second figure but a second sentence, the route coming rather than a
      // deadline the person loses something by missing. The row had the
      // sentence and no date at all.
      el("p", { class: "muted" },
        o.binding === "physical"
          ? `This box is with you. What you use is bought; what you send back is not. It was offered until ${when(o.expires_at)}, and the route comes for it around then.`
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
    // §16.5. **The button belongs to a set the household signed, and the
    // binding is not that fact.** A physical box reaches this state two ways:
    // a collection resolving its last line, which nobody signed, and the
    // household answering the box on the approval, which is a signed set the
    // specification says keeps the window's whole meaning. Judging by binding
    // denied the take-back to exactly that box and told its owner the route
    // had resolved it. A `kept` line is producible only by a signed decision,
    // so it is the fact to read. **The residue is named**: a box the household
    // answered by returning everything looks like a collection that returned
    // everything, and only the engine's confirmation register tells them
    // apart, which question 43 puts on the row.
    const box = o.binding === "physical" && !o.candidates.some((c) => c.valence === "kept");
    const said = el("p", { class: "muted" },
      box
        ? "The route has resolved this box. Nothing here is waiting on you."
        // **Nothing settles when a window closes.** The engine has no
        // scheduler: a digital set settles when the presenter asks it to, and
        // a cooling window only stops that happening sooner. This was the
        // sentence family refuted in `mandate_cooling` the day before, sitting
        // one screen over where the module's own test cannot see it.
        : "Decided. It is the shop's to settle now; what you can still do is take it back.");
    if (box) {
      return el("div", { class: "card" },
        el("div", { class: "row" }, el("span", { class: "grow" }, `From ${o.presenter}`)),
        said);
    }
    // §16.5, question 47, decided 2026-09-15. A signed set on a box past its
    // expiry stands: withdrawing it would leave the kept goods to go `lost`,
    // which is never billed. The engine refuses, so the button is not offered.
    if (o.binding === "physical" && Date.now() >= o.expires_at) {
      said.textContent = "Decided. This box is past its expiry, so what you signed stands and it is the shop's to settle.";
      return el("div", { class: "card" },
        el("div", { class: "row" }, el("span", { class: "grow" }, `From ${o.presenter}`)),
        said);
    }
    const undo = el("button", {}, "Take it back") as HTMLButtonElement;
    undo.onclick = async () => {
      undo.disabled = true;
      try {
        if (o.decided_at === null) throw new Error("This decision has no recorded decision time, so it cannot be taken back safely.");
        const signature = await signOver(member, new TextEncoder().encode(canonicalWithdrawal(o.id, o.decided_at)));
        const taken = await api<{ error?: string; message?: string }>("DELETE", `/offers/${encodeURIComponent(o.id)}/decisions`, { signature });
        if (taken.status === 200) { await offers(member); return; }
        said.textContent = refusal(taken.body, taken.status);
      } catch (e) {
        said.textContent = (e as Error).message;
      }
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
      // §6.5, question 46. Only goods used hold the next box; a box whose
      // collection recorded only missing items owes nothing and holds nothing.
      el("p", { class: "muted" }, holdsNextBox(o)
        ? `The route found something used. Nothing is charged until you sign, and no further box comes from ${o.presenter} while it waits.`
        : "The route wrote down what came back. Nothing on it is charged to you; sign it, or say where it is wrong.")
    );
  });
  const settings = el("button", {}, "What you have set") as HTMLButtonElement;
  settings.onclick = () => protections(member);
  // §14.3. Near the protections a person sets for themselves, because it is
  // the same kind of decision: what this host holds of the household's, and
  // what to do about it.
  const leaveHost = el("button", {}, "Leave this host") as HTMLButtonElement;
  leaveHost.onclick = () => leave(member);
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
    el("div", { class: "row" }, settings, leaveHost, forget)
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
  blocks: { merchant: string; product: string | null; items: { label: string; value: string }[]; contact?: { kind: "email" | "tel" | "url"; value: string } }[],
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
    // Question 72. Beside this block's own terms, and only where this
    // merchant signed one. No message is composed and nothing is sent on
    // the household's behalf; the tap, if there is one, is the household's.
    if (block.contact) nodes.push(contactLink(block.contact));
  }
  return nodes;
}

function contactLink(contact: { kind: "email" | "tel" | "url"; value: string }): Node {
  // Only https is a link: the engine refuses any other scheme at
  // registration, and a host that did not would otherwise hand this page a
  // `javascript:` link. Anything else is shown as text.
  const https = (() => { try { return new URL(contact.value).protocol === "https:"; } catch { return false; } })();
  const href =
    contact.kind === "email" ? `mailto:${contact.value}`
    : contact.kind === "tel" ? `tel:${contact.value}`
    : https ? contact.value : null;
  if (href === null) return el("p", { class: "muted" }, "Contact: ", contact.value);
  return el("p", { class: "muted" }, "Contact: ", el("a", { href, rel: "noopener noreferrer" }, contact.value));
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
  // **A status is not a body.** `api()` stopped throwing on a body it could
  // not read, and hands back `{}` with the status it got, so a `200` from a
  // captive portal or a truncated response reached the renderer and threw a
  // `TypeError` inside an `onclick` with no handler: the button did nothing,
  // silently, which is the defect the rewrite was said to have removed. It had
  // moved up one level. Found by a third refutation round on 2026-09-13.
  if (got.status !== 200 || !Array.isArray(got.body.candidates)) {
    show(el("h1", {}, "Atarasy"), failure(
      got.status === 200
        ? "This offer came back in a form this screen could not read. Nothing was decided."
        : refusal(got.body, got.status)), back(member));
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
          : c.valence === "lost"
            // Questions 46 and 48. Which kind of loss this is comes from what
            // the collection named the line.
            ? lostOutcome(c.collected_as)
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
      // §10.5. What is signed is the set in the canonical shape the engine
      // compares, and the gesture that releases the key is over the same
      // bytes: `signOver` puts their hash in the assertion's challenge even
      // though what goes to the engine is the signature.
      const decided = await api<{ state?: string; error?: string; message?: string }>("POST", `/offers/${encodeURIComponent(a.offer)}/decisions`, {
        decisions,
        signature: await signOver(member, new TextEncoder().encode(canonicalDecisions(a.offer, decisions))),
      });
      if (decided.status !== 200) throw new Error(refusal(decided.body, decided.status));
      // The count below is this screen's own, so a `200` that carried no state
      // would have been reported as a decision the engine never recorded.
      if (typeof decided.body.state !== "string") {
        throw new Error("The answer came back in a form this screen could not read, so it cannot say whether this was recorded. Go back and open it again.");
      }
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
         // §10a.5 counts the expiry among the facts of the sale, because a
         // merchant's stated application period is measured against it, and
         // §2.2b says a box's owner should not read it as their deadline. One
         // date, said once, carrying both.
         // **Not "which is when this offer closes".** Measured 2026-09-13 with
         // a grace of one day: the box is still `presented` past the expiry
         // and its approval still answers, and with a grace of zero it goes
         // `lost` at once. The date is when the offer was open until and when
         // the route is due; what happens at it is the deployment's grace, and
         // the screen does not know that number.
         el("p", { class: "muted" }, `It was offered until ${when(a.expires_at)}, and the route comes for it around then.`)]
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
            ? `${settled.length} of these ${settled.length === 1 ? "line is" : "lines are"} already resolved by what the route found. ${open.length} ${open.length === 1 ? "is" : "are"} still yours to decide.`
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
  if (got.status !== 200 || !Array.isArray(got.body.lines)) {
    show(el("h1", {}, "Atarasy"), failure(
      got.status === 200
        ? "What came back with this box came back in a form this screen could not read. Nothing was signed."
        : refusal(got.body, got.status)), back(member));
    return;
  }
  const st = got.body;
  // Question 46. The list files every box with a `lost` line here, because it
  // cannot tell a missing record from a deadline loss, and a deadline loss is
  // on no statement. Offering a signature over nothing would ask the person to
  // confirm a document with no line on it.
  if (st.lines.length === 0) {
    show(el("h1", {}, "Atarasy"),
      el("h2", {}, "What the box came back with"),
      el("p", { class: "muted" }, "Nothing on this box needs your signature. Anything not collected by the deadline is never charged to you."),
      back(member));
    return;
  }
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
    // Question 46. A disputed missing line was never charged, so it is counted
    // apart: saying it is "not charged here" would imply it otherwise was.
    const charges = st.lines.filter((l) => disputeMovesMoney(l) && disputed.has(l.candidate)).length;
    const losses = st.lines.filter((l) => !disputeMovesMoney(l) && disputed.has(l.candidate)).length;
    totalLine.textContent = `To be charged for the goods: ${yen(total())}.` +
      (st.carriage ? ` The carriage above is not in this figure.` : "") +
      (charges ? ` ${charges} line${charges === 1 ? "" : "s"} disputed and not charged here.` : "") +
      (losses ? ` ${losses} missing item${losses === 1 ? "" : "s"} disputed.` : "");
  };

  const cards = st.lines.map((l) => {
    // §6.5, question 46. A missing line is the collection saying the item was
    // not in the box. The household is never charged for it and may say it
    // was there. "Borne by the merchant" is not said: the stock holder may be
    // the maker.
    const missing = l.valence === "lost";
    const idle = missing ? "It was in the box" : "I did not use this";
    const mark = el("button", {}, idle) as HTMLButtonElement;
    const note = el("p", { class: "muted" }, "");
    const paint = () => {
      const isDisputed = disputed.has(l.candidate);
      mark.className = isDisputed ? "chosen" : "";
      mark.textContent = isDisputed ? "Disputed" : idle;
      note.textContent = !isDisputed
        ? ""
        : missing
          ? "You say this was in the box. Nothing moves either way; your signature records that you dispute it."
          : "Not charged here. What is owed for it, if anything, is between you and the seller.";
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
        el("span", {}, missing ? "not charged" : l.given_by ? "a gift" : yen(l.amount))),
      // Clause 10. A gift arrives at its price and is never billed, and the
      // screen says who gave it rather than leaving a zero to be read as luck.
      el("p", { class: "muted" },
        l.given_by
          ? `Given by ${l.given_by}. Never billed to you (clause 10).`
          : missing
            ? `Sold by ${l.merchant}, made by ${l.maker}.`
            : `${yen(l.unit_price)} each. Sold by ${l.merchant}, made by ${l.maker}.`),
      el("p", { class: "muted" },
        wasKept
          ? "You kept this when you decided. It is here because it is on the same bill."
          : missing
            ? "The collection says this was not in the box. You are never charged for it and it is no claim against you. If it was there, dispute it."
            : "The collection found this used."),
      // Question 46. The collection's own words, as text (clause 54).
      ...(missing && l.note ? [el("p", { class: "muted" }, `The collection's note: ${l.note}`)] : []),
      ...blockFor(st.disclosures ?? [], l.disclosure),
      // §6.5, §11.2. Only a consumed or missing line can be disputed: a kept
      // line is one this household signed itself.
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
        disputed: disputable(l) && disputed.has(l.candidate),
      }));
      // §6.5, question 40. What the screen showed as the carriage is inside
      // what the passkey signs. `carriage` is null only where no delivery is
      // recorded, and the engine refuses such a settlement before reading a
      // signature, so 0 there signs bytes nothing can settle.
      const bytes = new TextEncoder().encode(canonicalStatement(st.offer, st.carriage ?? 0, lines));
      const signature = await signOver(member, new Uint8Array(bytes));
      const settled = await api<{ charged?: number; disputed_amount?: number; error?: string; message?: string }>(
        "POST",
        `/offers/${encodeURIComponent(st.offer)}/settle`,
        { signature, disputed: [...disputed] }
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
            await showReceipt(member, st.offer, stood.body, "refused");
            return;
          }
        }
        // **Nothing answered, and the signature may still have settled the
        // box.** This is the case the receipt above exists for, and it could
        // not be reached: the member was told to open the list again, a
        // settled box is on no list, and nothing read the settlement. Asking
        // once here is what turns "this may or may not have gone through"
        // into an answer. Found by a third refutation round on 2026-09-13.
        if (settled.status === 0) {
          const stood = await api<Receipt & { error?: string }>(
            "GET",
            `/offers/${encodeURIComponent(st.offer)}/settlement`
          );
          if (stood.status === 200) {
            // §6.5. The settlement records the signature that made it, so
            // whether it is this member's is read rather than guessed. A
            // second tab or device signs the same statement, so matching lines
            // alone do not say it.
            // `null` is a settlement no signature made, so not this one.
            const recorded = stood.body.confirmation;
            const mine = recorded === signature
              ? "unanswered-mine"
              : typeof recorded === "string" || recorded === null ? "unanswered-other" : "unanswered-unknown";
            await showReceipt(member, st.offer, stood.body, mine);
            return;
          }
        }
        throw new Error(refusal(settled.body, settled.status));
      }
      // A `200` whose body carries no charge is not a settlement this screen
      // can report as one: the engine always names the figure.
      if (typeof settled.body.charged !== "number") {
        throw new Error("The answer came back in a form this screen could not read, so it cannot say whether this settled. Open the list again before signing a second time.");
      }
      await showReceipt(member, st.offer, settled.body, "signed");
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
    // The engine's rule: goods used hold the next box, and so does a missing
    // line beside a kept or defaulted one (question 46, decided 2026-09-14).
    el("p", { class: "muted" }, st.lines.some((l) => l.valence === "consumed") ||
      (st.lines.some((l) => l.valence === "lost") && st.lines.some((l) => l.valence === "kept" || l.valence === "defaulted"))
      ? "The route wrote this down. Nothing is charged until you sign it, and no further box comes from whoever sent this one while it waits."
      : "The route wrote this down. Nothing is charged until you sign it."),
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
    // §6.5, question 46, decided 2026-09-14. What signing attests over a
    // missing line, so silence is not read as agreeing the item is gone.
    ...(st.lines.some((l) => l.valence === "lost")
      ? [el("p", { class: "muted" }, "Signing shows you were told which items the collection did not find. It is not you agreeing they are missing or taking responsibility for them; you are never charged for them, and you can dispute any you had.")]
      : []),
    totalLine,
    el("div", { class: "row" }, sign, back(member)),
    status
  );
}

/** §6.5. What a settlement came to, as the member reads it. */
type Receipt = { charged?: number; disputed_amount?: number; settled_at?: number; confirmation?: string | null };

/**
 * How the screen reached a receipt. `signed` is a settle that answered;
 * `refused` is `already_settled`, where the engine said this signature did not
 * settle the box; the `unanswered` three are a settle with no answer followed
 * by a read of the settlement, told apart by whether its confirmation is the
 * signature just sent.
 */
type ReceiptPath = "signed" | "refused" | "unanswered-mine" | "unanswered-other" | "unanswered-unknown";

/**
 * §6.5. What was charged.
 *
 * **A missing amount is not zero, and this printed one.** `api()` hands back
 * an empty body for a `200` whose body was truncated on the wire or was not
 * JSON, and `charged ?? 0` then drew "Signed. ¥0 charged." over a settlement
 * the engine had made at its real figure. Zero is a real amount here, every
 * line disputed or every line a gift, so the member could not tell the two
 * apart and the screen had invented a number it never received.
 *
 * **`stood` is not the member's own signature, and the sentence said it was.**
 * The engine throws `already_settled` for exactly one reason: a signed body
 * arrived and a settlement already stood, so what was just signed did not
 * settle this box. That is true of a lost answer, where the standing
 * settlement is the member's own earlier act, and equally true of a second tab
 * that disputed a line and lost the race. Telling the second tab that its
 * signature is what settled the box is the thing the engine's refusal exists
 * to prevent. So the sentence says what the engine said.
 */
function receipt(r: Receipt, path: ReceiptPath): Node {
  const stood = path !== "signed";
  const amount = typeof r.charged === "number" ? yen(r.charged) : null;
  return el("div", { class: "card" },
    el("p", {},
      stood
        ? `This box has settled${r.settled_at ? `, on ${when(r.settled_at)}` : ""}.`
        : "Signed."),
    el("p", {},
      amount === null
        ? "The amount could not be read back, so this screen cannot say what was charged. Nothing here means it was nothing."
        : stood
          ? `${amount} was charged by the settlement that stands.`
          : `${amount} charged.`),
    // **Which signature settled it is not the same question on the two paths
    // that reach here**, and one sentence said the same thing on both. After a
    // refusal the engine has told us this signature was not the one; after no
    // answer at all the settlement's confirmation says whether it was, and a
    // guess either way is what the review of atarasy #5 took out.
    ...(stood
      ? [el("p", { class: "muted" }, {
          refused: "What you just signed is not what settled it. This is the settlement that stands, and nothing was charged twice.",
          "unanswered-mine": "The answer to your signature never came back, but this settlement carries the signature you just gave. Nothing was charged twice.",
          "unanswered-other": "The answer to your signature never came back, and the settlement that stands was not made by the signature you just gave. Nothing was charged twice.",
          "unanswered-unknown": "The answer to your signature never came back, and this is the settlement that stands. This screen could not read which signature made it. Nothing was charged twice.",
        }[path as Exclude<ReceiptPath, "signed">])]
      : []),
    ...(r.disputed_amount
      ? [el("p", { class: "muted" }, `${yen(r.disputed_amount)} was disputed and is not charged here. What is owed for it, if anything, is between you and the seller.`)]
      : []));
}

/**
 * §6.6, question 70. Reads the settled offer's receipt beside its
 * settlement and shows both. A correction only ever lowers what was signed
 * and is appended beside it, never rewriting the settlement above: there is
 * nothing to sign or dispute on this screen (clause 54).
 *
 * **A failed or absent corrections read is never a reason to hide the
 * settlement.** A 404 (the offer has no settlement, which cannot arise once
 * `r` itself was read), a malformed body or an offer mismatch all come back
 * from `validateCorrections` as `null`, drawn as nothing rather than as a
 * failure of the receipt the household is here to see.
 */
async function showReceipt(member: Member, offerId: string, r: Receipt, path: ReceiptPath) {
  const got = await api<unknown>("GET", `/offers/${encodeURIComponent(offerId)}/corrections`);
  const corrections = got.status === 200 ? validateCorrections(got.body, offerId) : null;
  show(el("h1", {}, "Atarasy"), receipt(r, path), ...correctionsCard(corrections), back(member));
}

/**
 * §6.6. The merchant's own words are shown as text, never as a link or
 * markup (clause 54): `el()` appends every string child as a text node, so
 * a note is never parsed as HTML here.
 */
function correctionsCard(c: Corrections | null): Node[] {
  if (!c || c.corrections.length === 0) return [];
  return [el("div", { class: "card" },
    el("p", {}, "The merchant of record has appended the following to the settlement above. There is nothing here for you to sign or dispute."),
    ...c.corrections.map((line) =>
      el("div", {},
        el("p", {}, `${line.kind === "refund" ? "Refund" : "Collection"} from ${line.merchant}: −${yen(line.amount)}, ${when(line.corrected_at)}.`),
        el("p", { class: "muted" }, line.note))
    ),
    el("p", {}, `Net after corrections: ${yen(c.net)}.`))];
}

/**
 * §10.5, §16.1. The person's signature over the canonical bytes, in the first
 * of the two shapes the specification names.
 *
 * **It was the second shape until 2026-09-16**, an assertion by the passkey's
 * own key, because that key was the household's. Question 55 made a household
 * the name of a key and a `get` never returns a public key, so the key a
 * member carries between devices is the one inside the handle instead. The
 * gesture is unchanged: the authenticator releases the handle only after the
 * person verifies, and this holds the key for the length of one signature.
 * What is lost is that a page which kept it could sign again without asking.
 */
async function signOver(member: Member, bytes: Uint8Array<ArrayBuffer>): Promise<string> {
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
  const handle = (credential.response as AuthenticatorAssertionResponse).userHandle;
  if (!handle) throw new Error("this passkey carries no household");
  const held = await memberKeyFromHandle(handle);
  if (held.household !== member.household) throw new Error("this passkey is another household's");
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, held.key, bytes as unknown as BufferSource);
  return toBase64(signature);
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
  const readable = read.status === 200 && typeof read.body.version === "number";
  if (read.status !== 404 && !readable) {
    show(el("h1", {}, "Atarasy"), failure(
      read.status === 200
        ? "What you have set came back in a form this screen could not read. Nothing here has changed."
        : refusal(read.body, read.status)), back(member));
    return;
  }
  const current: Mandate | null = readable ? read.body : null;
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
      // Clause 47, amended 2026-09-13, and §16.1. **A loosening needs the
      // people the mandate names, and where it names none the person's own
      // signature is the whole of it.** This screen refused every loosening
      // and told the member so, which was the only thing making a household
      // stuck: measured on 2026-09-13, the engine accepts a lone loosening
      // from a household with no co-signers, and this hub can create no other
      // kind. Three passes and two documents had taken the refusal for the
      // engine's rule and reasoned from it.
      if (loosening && current && current.co_signers.length > 0) {
        throw new Error(`${loosening}, and needs everyone you named: ${current.co_signers.join(", ")}`);
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
      // §16.1, question 58. Signed for this host, which is the relying party
      // the engine behind it asserts for, so the version records nowhere else.
      const bytes = new TextEncoder().encode(canonicalMandate(next, location.hostname));
      const recorded = await api<{ error?: string; message?: string }>("POST", "/_node/mandates", {
        ...next,
        signatures: { [member.household]: await signOver(member, bytes) },
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
      current && current.co_signers.length > 0
        ? `Version ${current.version}. Tightening is yours alone; loosening needs everyone you named: ${current.co_signers.join(", ")} (clause 47).`
        : current
          // **The honest sentence for the only household this hub can make.**
          // No co-signer can be recorded here, so nothing it sets is protected
          // from the person who set it. Saying otherwise was the screen
          // claiming a protection that was never there.
          ? `Version ${current.version}. You have named nobody to hold these with you, so anything here is yours to change back at any time. Naming somebody is what would make it otherwise, and this screen cannot yet do that (clause 47).`
          : "Nothing yet. Until you name somebody to hold them with you, anything you set here stays yours alone to change back."),
    el("div", { class: "card" },
      el("p", {}, "How long a decision waits before it can settle, and can be taken back."),
      el("div", { class: "row" }, ...coolingRow)),
    el("div", { class: "card" },
      el("p", {}, "The most that may be settled for you in one day, across every shop."),
      // §16.3, question 39, decided 2026-09-13. **A ceiling can stop a box
      // settling and not merely delay it**, because since §6.5 the household
      // is the party that presses the button and a box whose used goods come
      // to more than the ceiling can never be signed at that ceiling. The
      // specification makes saying so a requirement on this surface, and the
      // requirement shipped in the refusal and not here, where a person
      // chooses the number.
      el("p", { class: "muted" }, "A ceiling can stop a box settling altogether, not just delay it: if what you used in one box comes to more than this, it cannot settle until the ceiling is raised, and raising one needs the people you named."),
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
// ---- leaving this host (§14.3) -----------------------------------------------

type LeaveBlocker = { kind: string; id: string };

/**
 * §14.3. What each blocker kind reads as, in words a person can act on. A kind
 * this screen does not recognise is still shown, by its own name, rather than
 * dropped: a household is never told nothing is holding it here when the
 * engine said otherwise.
 */
const BLOCKERS: Record<string, string> = {
  offer_in_progress: "A box or order is still open. Finish or decline it first.",
  statement_unsigned: "A box is waiting for your signature on what it cost.",
  reservation_held: "Money is still held for an order.",
  gift_in_flight: "A gift you are paying for has not finished.",
  co_signer: "You co-sign another household's mandate. Step down first.",
  recoverer: "You help another household recover its account. Step down first.",
};

/** §14.3. Reads what would block a departure, and draws the screen for it. */
async function leave(member: Member) {
  const got = await api<{ blockers?: LeaveBlocker[]; error?: string; message?: string }>(
    "GET",
    `/households/${encodeURIComponent(member.household)}/leave`
  );
  if (got.status !== 200 || !Array.isArray(got.body.blockers)) {
    show(el("h1", {}, "Atarasy"), failure(
      got.status === 200
        ? "What is holding you here came back in a form this screen could not read. Nothing was deleted."
        : refusal(got.body, got.status)), back(member));
    return;
  }
  renderLeave(member, got.body.blockers);
}

/**
 * §14.3. **A household with a blocker is offered no deletion at all**, not a
 * disabled button beside one: a set this screen cannot make is not something
 * to dangle in front of a person as a choice. A clean household is told what
 * leaves and what does not, may save the export first, and signs a deliberate
 * confirmation before the deletion itself is signed.
 */
function renderLeave(member: Member, blockers: LeaveBlocker[], notice?: string) {
  const status = el("p", {}, notice ?? "");
  if (blockers.length > 0) {
    show(
      el("h1", {}, "Atarasy"),
      el("h2", {}, "Leave this host"),
      el("p", {}, "This host cannot delete your account yet."),
      el("ul", {}, ...blockers.map((b) => el("li", {}, BLOCKERS[b.kind] ?? `${b.kind} (${b.id})`))),
      status,
      back(member)
    );
    return;
  }

  const save = el("button", {}, "Save a copy of my records") as HTMLButtonElement;
  save.onclick = async () => {
    save.disabled = true;
    status.textContent = "";
    try {
      // Clause 43. The export as this host holds it, saved to the person's own
      // device before anything is deleted. `api()` is not used here: it parses
      // a body as JSON, and this file is handed to the browser to save as it
      // came, not re-encoded.
      // Signed, with the moment: the export carries notes and permissions no
      // other read here does, so the engine hands it over only to the household.
      const at = Date.now();
      const signature = await signOver(member, new TextEncoder().encode(canonicalExport(member.household, location.hostname, at)));
      let response: Response;
      try {
        response = await fetch(`/api/households/${encodeURIComponent(member.household)}/export`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ at, signature }) });
      } catch {
        throw new Error("This page could not reach the service that serves it. Nothing was saved.");
      }
      if (response.status !== 200) throw new Error(`this answered ${response.status}`);
      const text = await response.text();
      const url = URL.createObjectURL(new Blob([text], { type: "application/json" }));
      const link = el("a", { href: url, download: `atarasy-export-${new Date().toISOString().slice(0, 10)}.json` }) as HTMLAnchorElement;
      link.click();
      URL.revokeObjectURL(url);
    } catch (e) {
      status.textContent = (e as Error).message;
    }
    save.disabled = false;
  };

  const understood = el("input", { type: "checkbox", id: "leave-confirm" }) as HTMLInputElement;
  const del = el("button", {}, "Delete my account") as HTMLButtonElement;
  del.disabled = true;
  understood.onchange = () => { del.disabled = !understood.checked; };

  del.onclick = async () => {
    del.disabled = true;
    status.textContent = "";
    try {
      // §14.3, §16.1. Signed for this host, the way a mandate is: the relying
      // party the engine behind it asserts for, so the signature records
      // nowhere else.
      const at = Date.now();
      const signature = await signOver(member, new TextEncoder().encode(canonicalLeave(member.household, location.hostname, at)));
      const done = await api<{ deleted?: Record<string, number>; blockers?: LeaveBlocker[]; error?: string; message?: string }>(
        "POST",
        `/households/${encodeURIComponent(member.household)}/leave`,
        { at, signature }
      );
      if (done.status === 409) {
        // **Something opened between the read above and this signature.** The
        // refusal carries its blockers; an older engine's did not, so they are
        // read again when the body has none.
        const blockers = Array.isArray(done.body.blockers)
          ? done.body.blockers
          : (await api<{ blockers?: LeaveBlocker[] }>("GET", `/households/${encodeURIComponent(member.household)}/leave`)).body.blockers ?? [];
        renderLeave(member, blockers, "Something changed since this screen opened. What is holding you here now:");
        return;
      }
      if (done.status !== 200) throw new Error(refusal(done.body, done.status));
      const deleted = done.body.deleted ?? {};
      const count = Object.values(deleted).reduce((a, b) => a + b, 0);
      // §14.3. The deletion is the household's alone and needs no co-signer
      // (clause 47 governs a mandate, not the account it protects), so nothing
      // here waits on anyone else. What this browser keeps for the household
      // is cleared the same way "Forget this device" clears it; the passkey
      // itself is the authenticator's to discard, which this screen cannot do.
      localStorage.removeItem(STORAGE);
      await setup(el("div", { class: "card" },
        el("p", {}, "Deleted. This host no longer holds anything for your household."),
        el("p", { class: "muted" }, `${count} record${count === 1 ? "" : "s"} removed.`)));
    } catch (e) {
      status.textContent = (e as Error).message;
      del.disabled = false;
    }
  };

  show(
    el("h1", {}, "Atarasy"),
    el("h2", {}, "Leave this host"),
    el("p", {}, "Deleting your account removes everything this host holds for your household: every offer, decision, statement, mandate and protection."),
    el("p", { class: "muted" }, "A shop keeps its own record of what it sold you. A gift you gave stays in the other household's records, with you shown as a member who has left."),
    el("div", { class: "row" }, save),
    el("div", { class: "row" }, understood, el("label", { for: "leave-confirm" }, "I understand this deletes my account from this host and cannot be undone.")),
    el("div", { class: "row" }, del, back(member)),
    status
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
