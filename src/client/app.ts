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
import { awaitsDecision, awaitsStatement, byArrival, rowGoods, rowMerchants, rowStatus, type InboxOffer } from "../shared/inbox.js";
// The sentences a refusal reads as, in a module the suite can reach: four of
// them directed the member wrongly and nothing here could have said so.
import { REFUSALS, refusal } from "../shared/refusals.js";
// The judgements the screens make, separated from the drawing of them: a
// reviewer reverted five of them at once and the suite stayed green.
import { blocksFor, decidable, decisionGoodsTotal, decisionOutcome, disputable, disputeMovesMoney, lostOutcome, statementTotal, undoDeadline, validateCorrections, type Corrections } from "../shared/screen.js";
// D-1, D-3. What a member reads for money, a date and the goods themselves,
// mirroring `ios/AtarasyPrototype/MemberFormat.swift` so the two apps say
// the same thing about the same offer.
import { formatDay, formatDayTime, formatMoney, goodsTitle, sellers } from "../shared/format.js";
// D-5. The screen's vocabulary in the member's own language, picked once
// from `navigator.language` and carried for the length of the session; the
// iOS app's own English and Japanese, not translated again here.
import { pickLanguage, t, type Lang } from "./copy.js";

const LANG: Lang = pickLanguage(navigator.language);
/** Short form of `t(LANG, ...)`, used throughout this file. */
const L = (key: string, ...args: (string | number)[]) => t(LANG, key, ...args);
// So a screen reader and the browser's own UI (spell-check, form controls)
// treat the page as what it now shows, not as the document's static markup.
document.documentElement.lang = LANG;

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
    /**
     * D-1, catalogue revision 3. The goods' own name and variant (size or
     * pack), where the merchant's catalogue entry carries them. Absent is
     * legitimate: an entry published before revision 3 has neither, and
     * `goodsTitle()` falls back to `product`, the reference this screen has
     * always shown.
     */
    name?: string | null;
    variant?: string | null;
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
    /** D-1, catalogue revision 3. See the same field on `Approval.candidates`. */
    name?: string | null;
    variant?: string | null;
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
/**
 * D-3. A host deployment serves one currency (Stage 0 is JPY only), declared
 * once rather than read per offer, since nothing in the specification carries
 * a currency field yet (`SPEC.md` §14b). Revisit when a second currency
 * exists.
 */
const CURRENCY = "JPY";
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

/**
 * D-3. Money is the host's configured currency (JPY by default), grouped and
 * with no decimal place, through `Intl.NumberFormat` rather than a bare
 * integer with a symbol glued on.
 */
const yen = (n: number) => formatMoney(n, CURRENCY, navigator.language);
/**
 * D-3. A day a person reads, weekday first, never the device's raw long
 * date-and-time format and never an epoch. Used for a close, a swap or an
 * expiry, which are days rather than moments (clause 30: nothing here counts
 * down to one).
 */
const day = (ms: number) => formatDay(ms, navigator.language);
/** The same day with a clock time beside it, for a deadline that is also an hour. */
const when = (ms: number) => formatDayTime(ms, navigator.language);

// ---- setup: a passkey, registered as the mandate's key ----------------------

async function setup(notice?: Node) {
  const input = el("input", { placeholder: "a name for this household", value: `household-${Math.random().toString(36).slice(2, 8)}` }) as HTMLInputElement;
  const button = el("button", { class: "primary" }, L("Create passkey")) as HTMLButtonElement;
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
  const again = el("button", {}, L("Sign in with passkey")) as HTMLButtonElement;
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
    // The entry sentence the iOS app opens with (vault `80` §6.2 E), the
    // one used here because nothing is offered until a key exists to
    // answer with, which is exactly what that sentence says.
    el("p", {}, L("Your own agent for things that arrive to be tried. You pay only for what you keep, and nothing is bought without your signature.")),
    el("div", { class: "card" }, el("div", { class: "row" }, input, button), note, status),
    el("div", { class: "card" },
      el("p", {}, "Already have one, on this device or another?"),
      el("p", { class: "muted" }, "Your passkey is your household. Answering with it here brings back everything placed with it, wherever you last used it."),
      el("div", { class: "row" }, again))
  );
}

// ---- persistent navigation: Inbox, Limits, Account (vault `80` §6.1) --------

type Tab = "inbox" | "limits" | "account";

/**
 * Three destinations reachable from anywhere while signed in, the ones the
 * iOS `TabView` names in `MemberAppView.swift` (`MemberTab`: `.inbox`,
 * `.limits`, `.account`). Before this, a signed-in member's only screen was
 * a single scroll stacking the inbox above the household's own protections
 * and its account controls (vault `80` finding S1); every one of those now
 * has its own destination, and none of them is the first thing a new member
 * has to read past.
 */
function nav(member: Member, active: Tab): Node {
  const items: [Tab, string, () => void][] = [
    ["inbox", L("Inbox"), () => offers(member)],
    ["limits", L("Limits"), () => protections(member)],
    ["account", L("Account"), () => account(member)],
  ];
  return el("nav", { class: "tabs" }, ...items.map(([id, label, go]) => {
    const b = el("button", { class: id === active ? "tab active" : "tab" }, label) as HTMLButtonElement;
    b.disabled = id === active;
    b.onclick = go;
    return b;
  }));
}

/** Every top-level screen (as opposed to one pushed from a card) draws through here. */
function shell(member: Member, active: Tab, ...content: (string | Node)[]) {
  show(el("h1", {}, "Atarasy"), nav(member, active), ...content);
}

// ---- the offers waiting on the person (Inbox) --------------------------------

/**
 * `04b` §1b, vault `80` §6.2 I. Two sections, "At home" and "Proposals",
 * each newest arrival first over every presenter (clause 14), plus the
 * waiting statements above both: a household that does nothing there is one
 * whose next box will not come, which is the one thing on this screen with
 * a consequence attached to leaving it unread.
 *
 * A box the route has already resolved, and a proposal the household has
 * already decided, stay in the section they belong to rather than moving to
 * a list of their own (vault `80` finding S2's guardrail, `04b` §1b.2): the
 * binding is what a row's status line is about, and splitting bindings
 * apart is the one grouping clause 14 does not forbid.
 */
async function offers(member: Member) {
  let presenters: string[] = [];
  try {
    presenters = ((await (await fetch("/config")).json()) as { presenters: string[] }).presenters;
  } catch {
    // It is this hub that did not answer, not an engine: `/config` is served
    // here. Saying "the engine" sent the member looking in the wrong place.
    shell(member, "inbox", failure("This page could not reach the service that serves it, so nothing could be listed. Nothing was sent."), retry(member));
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

  // Item 4, vault `80` §6.2 I's "decided and in cooling" row case. The
  // cooling window is on the mandate, not the offer, so it takes a second
  // read to say when a decided set can no longer be undone. **Fetched once
  // for the whole screen, never once per row**: the mandate is the same
  // record for every decided offer this household has, so a request per row
  // would ask the engine the same question as many times as there are rows.
  // `undefined` here is "not fetched" (no decided offer, or the read failed);
  // `null` is a mandate read with no cooling window recorded.
  let coolingSeconds: number | null | undefined;
  if (decided.length > 0) {
    const read = await api<Mandate & { error?: string }>("GET", `/_node/mandates/${encodeURIComponent(member.mandate)}`);
    if (read.status === 200 && typeof read.body.cooling_seconds !== "undefined") coolingSeconds = read.body.cooling_seconds;
    else if (read.status === 404) coolingSeconds = null;
    // Any other status (unreachable, unreadable) leaves it `undefined`, and
    // the row falls back to the sentence it always had rather than guessing.
  }

  /**
   * `04b` §1b.3, §2.2b, vault `80` §6.2 I. **One status line, in the
   * member's own words rather than a protocol state**, from `rowStatus()`
   * (`shared/inbox.ts`) so the case a row falls into is decided once, in a
   * module the suite can hold to the same case table the plan does. This
   * used to be a longer sentence explaining what doing nothing means for a
   * box; that consequence is still said, once, at the top of the box itself
   * (`approval()`), and repeating it on every row was the noise finding S1
   * named.
   */
  const statusLine = (o: InboxOffer): string => {
    const status = rowStatus(o);
    switch (status.kind) {
      case "box-waiting":
        return L("Next swap %@", day(status.nextSwap));
      case "box-statement-ready":
        return status.holdsNext ? L("Confirm the statement to receive the next box") : L("Statement ready to confirm");
      case "proposal-undecided":
        return L("Closes %@. Nothing is bought if you do nothing.", day(status.closes));
      case "proposal-decided":
        return L("You decided");
    }
  };
  /**
   * D-1, vault `80` §6.2 I. The list already carries each candidate's
   * `product`, `merchant` and, since catalogue revision 3, `name`/`variant`
   * (`shared/inbox.ts`'s `InboxOffer`), so a row's title and seller are read
   * off the same answer this screen already asked for, and never a second
   * request per row.
   */
  const card = (o: InboxOffer) => {
    const open = el("button", { class: "primary" }, L("Open")) as HTMLButtonElement;
    open.onclick = () => (awaitsStatement(o) ? statement(member, o.id) : approval(member, o.id, o.binding));
    const goods = rowGoods(o);
    const headline = goods.moreCount > 0 ? L("%@ and %lld more", goods.title, goods.moreCount) : goods.title;
    const merchants = rowMerchants(o);
    return el("div", { class: "card" },
      el("div", { class: "row" },
        el("strong", { class: "grow" }, headline || o.presenter),
        open),
      ...(merchants.length ? [el("p", { class: "muted" }, sellers(merchants, navigator.language))] : []),
      ...(o.giver ? [el("p", { class: "muted" }, L("Gift from %@", o.giver))] : []),
      el("p", { class: "muted" }, statusLine(o))
    );
  };
  // `04b` §1b.2. The two bindings are separated, and each is newest first.
  const boxes = [...waiting.filter((o) => o.binding === "physical"), ...unsigned].sort(byArrival).map(card);
  const cards = waiting.filter((o) => o.binding === "digital").map(card);

  // §16.5. A decided set waits out its cooling window before it can settle,
  // and the person can take it back while it does. Without a cooling window
  // there is no window to take it back into, which is what the protections
  // screen is for.
  const decidedCard = (o: InboxOffer): Node => {
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
    // Item 4, vault `80` §6.2 I. When both the decision's own moment and the
    // mandate's cooling window are in hand (fetched once for the whole
    // screen, above), and the window has not yet closed, the row says the
    // actual deadline rather than the generic "what you can still do is take
    // it back": the same undoDeadline() a test in `shared/screen.ts` proves
    // on its own. Anything less than both known keeps the sentence this row
    // always had; no request is made per row to find out.
    const deadline = undoDeadline(o.decided_at, coolingSeconds);
    const said = el("p", { class: "muted" },
      box
        ? "The route has resolved this box. Nothing here is waiting on you."
        : deadline !== null && Date.now() < deadline
          ? `Decided. It is the shop's to settle now; you can undo until ${when(deadline)}.`
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
    const undo = el("button", {}, L("Undo this decision")) as HTMLButtonElement;
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
  };
  // `04b` §1b.2. A decided set stays with the binding it belongs to rather
  // than moving to a section of its own (vault `80` finding S2's guardrail).
  const decidedBoxes = decided.filter((o) => o.binding === "physical").map(decidedCard);
  const decidedProposals = decided.filter((o) => o.binding === "digital").map(decidedCard);
  // **Nothing waiting and nothing answering are different things**, and one
  // screen used to draw them together: a presenter that failed put a card at
  // the foot of the page while "Nothing is waiting for you." stood above it.
  // A member cannot act on a list that is silent about how much of it is
  // missing.
  const partial = problems.length > 0;
  const atHome = [...boxes, ...decidedBoxes];
  const proposals = [...cards, ...decidedProposals];
  const emptyText = (kind: "boxes" | "proposals") => {
    if (partial) return "This list may be incomplete: not every shop answered.";
    return kind === "boxes" ? L("No boxes at home.") : L("No proposals here.");
  };
  shell(member, "inbox",
    ...problems.map((p) => failure(p)),
    el("h2", {}, L("At home")),
    el("p", { class: "muted" }, L("Boxes delivered to you. Use what you like; you pay only for what you use.")),
    ...atHome,
    ...(atHome.length ? [] : [el("p", { class: "muted" }, emptyText("boxes"))]),
    el("h2", {}, L("Proposals")),
    el("p", { class: "muted" }, L("Nothing is bought unless you choose it and sign.")),
    ...proposals,
    ...(proposals.length ? [] : [el("p", { class: "muted" }, emptyText("proposals"))])
  );
}

/** When nothing answered at all, the one thing left to offer is another try. */
function retry(member: Member) {
  const b = el("button", { class: "primary" }, L("Try again")) as HTMLButtonElement;
  b.onclick = () => offers(member);
  return b;
}

// ---- the Account tab --------------------------------------------------------

/**
 * Vault `80` §6.2 A. Who is signed in, and the controls that were sitting on
 * the Inbox screen before every other decision on it (finding S1, S3): the
 * household and mandate identifiers a shop needs move here, under "About
 * this account", never the first line a member reads (guardrail: no raw
 * identifier on a primary screen).
 */
async function account(member: Member) {
  const forget = el("button", {}, L("Sign out")) as HTMLButtonElement;
  // §16.1. It forgets the browser's copy and not the household, which lives
  // in the passkey. The setup screen takes that passkey back, and this used
  // to be a one-way door with nothing on the screen saying so.
  forget.onclick = () => { localStorage.removeItem(STORAGE); setup(); };
  const leaveHost = el("button", {}, L("Delete account")) as HTMLButtonElement;
  leaveHost.onclick = () => leave(member);
  shell(member, "account",
    el("p", {}, member.label),
    el("div", { class: "row" }, forget),
    el("details", {},
      el("summary", {}, L("About this account")),
      // An offer names the household it is placed with and the mandate it is
      // made under, and how a presenter comes to know either is between the
      // household and the presenter. Neither is a secret and neither is
      // guessable, so support may ask for it; nothing else on this screen
      // reads it.
      el("p", { class: "muted" }, L("Support may ask you for the account reference shown under Account on a device where you are signed in. It does not sign you in by itself.")),
      el("ul", {},
        el("li", {}, "household ", el("code", {}, member.household)),
        el("li", {}, "mandate ", el("code", {}, member.mandate)))),
    el("h2", {}, L("Delete account")),
    el("p", { class: "muted" }, L("Deleting removes your account and everything this host holds for it. Shops keep their own records of sales. Gifts you shared with other households stay in their records, showing you as a member who has left.")),
    el("div", { class: "row" }, leaveHost)
  );
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
/**
 * D-7. `collapsed` draws the block(s) inside a `<details>` naming the
 * merchant, for the browsing view a line sits on; `open` (the review step
 * that carries the Sign button) draws them directly, as this always did
 * before D-7. Vault `80` §4's own open question ("whether a collapsed
 * 'Terms from <merchant>' row... satisfies" §10a.4) is answered by this
 * plan's own choice: collapsed while browsing, open where the signature is.
 */
function blockFor(
  blocks: { merchant: string; product: string | null; items: { label: string; value: string }[]; contact?: { kind: "email" | "tel" | "url"; value: string } }[],
  which: { merchant: string; product: string | null },
  collapsed: boolean
): Node[] {
  const governing = blocksFor(blocks, which);
  if (governing.length === 0) {
    // §10a.3 refuses an offer with no block long before a screen is drawn, so
    // this is a hub reading a response it should never receive. Saying so is
    // better than drawing a sale with no terms beside it.
    return [failure(`${which.merchant} sent no terms for this line.`)];
  }
  const body: Node[] = [];
  for (const { block, scope } of governing) {
    body.push(el("p", { class: "muted" },
      scope === "product"
        ? `${which.merchant}, for this product:`
        : governing.length > 1 ? `${which.merchant}, in general:` : `${which.merchant}:`));
    body.push(el("dl", { class: "terms" },
      ...block.items.flatMap((i) => [el("dt", {}, i.label), el("dd", {}, i.value)])));
    // Question 72. Beside this block's own terms, and only where this
    // merchant signed one. No message is composed and nothing is sent on
    // the household's behalf; the tap, if there is one, is the household's.
    if (block.contact) body.push(contactLink(block.contact));
  }
  if (!collapsed) return body;
  return [el("details", {}, el("summary", {}, L("Terms from %@", which.merchant)), ...body)];
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
  // D-6, D-7. This screen is the browsing step: it picks, it does not sign.
  // "Review" (iOS's own label for the same button, `MemberOfferScreen.swift`)
  // opens `approvalReview()`, where the terms are open and the one passkey
  // prompt is.
  const confirm = el("button", { class: "primary" }, L("Review")) as HTMLButtonElement;
  confirm.disabled = true;
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
    const keep = el("button", {}, L("Keep")) as HTMLButtonElement;
    const ret = el("button", {}, L("Decline")) as HTMLButtonElement;
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
        el("strong", { class: "grow" }, `${goodsTitle(c)} × ${c.quantity}`),
        // Clause 10, §6.2. A gift arrives at its price and is never billed, so
        // the card says so instead of printing a figure nobody will be charged.
        el("span", {}, c.given_by ? L("Free") : yen(c.unit_price * c.quantity))),
      // Clause 12. The maker and the carrier are on the screen the person
      // signs from, and the maker is not the merchant.
      el("p", { class: "muted" },
        c.given_by
          ? `${L("Gift from %@", c.given_by)}. Never billed to you (clause 10). ${L("Made by %@", c.maker)}. Carried by ${c.ships}.`
          : `${L("Sold by %@", c.merchant)}. ${L("Made by %@", c.maker)}. Carried by ${c.ships}.`),
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
      // §10a.5, D-7. This merchant's terms, beside this merchant's line and
      // no other, collapsed while the person is still choosing (drawn open
      // on the review step, `approvalReview()`, right before the signature).
      // One screen carries several sellers' blocks, and each seller answers
      // for the whole 映像面 it appears on.
      ...blockFor(a.disclosures ?? [], c.disclosure, true),
      ...(decidable ? [el("div", { class: "row" }, keep, ret)] : [])
    );
  });

  const excluded = a.excluded.length
    ? [el("h2", {}, "Left out, and why (clause 36)"),
       el("ul", {}, ...a.excluded.map((x) => el("li", {}, `${x.product}: ${RULES[x.reason] ?? x.reason}`)))]
    : [];

  // D-6, D-7. Picking is done; what is signed is frozen and shown with its
  // terms open on `approvalReview()`, never here.
  confirm.onclick = () => {
    const decisions: Decision[] = open.map((c) => {
      const valence = choices.get(c.id)!;
      return valence === "kept" ? { candidate: c.id, valence, kept_as: "self" } : { candidate: c.id, valence };
    });
    approvalReview(member, a, decisions, binding);
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
         el("p", { class: "muted" }, `It was offered until ${day(a.expires_at)}, and the route comes for it around then.`)]
      : [el("p", {}, `Offered by ${a.presenter}. ${L("Closes %@.", day(a.expires_at))}`)]),
    el("p", { class: "muted" },
      a.mandate.kind === "standing"
        ? `Under a standing mandate: ${a.mandate.scope}, lapsing ${a.mandate.lapses_at ? day(a.mandate.lapses_at) : "never"} (clause 58).`
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
    el("div", { class: "row" }, ...(open.length ? [confirm] : []), back(member))
  );
}

/**
 * D-6, D-7. The review step: what the signature covers, in one sentence; the
 * exact lines and their outcome; the total, carriage stated apart; the
 * merchants' own terms drawn open (never collapsed here); and the one
 * "Sign with passkey" button, which is the whole of the act (`22` UX-06,
 * `04b` §2.2c). Reached only from `approval()`'s "Review", and never reached
 * with an empty `decisions` array, since that button is disabled until every
 * open line has a choice.
 */
function approvalReview(member: Member, a: Approval, decisions: Decision[], binding?: "digital" | "physical") {
  const byId = new Map(a.candidates.map((c) => [c.id, c]));
  const kept = decisions.filter((d) => d.valence === "kept").map((d) => byId.get(d.candidate)!);
  const declined = decisions.filter((d) => d.valence === "returned").map((d) => byId.get(d.candidate)!);
  const goods = decisionGoodsTotal(a.candidates, decisions);
  const carriage = a.carriage ?? 0;

  const sign = el("button", { class: "primary" }, L("Sign with passkey")) as HTMLButtonElement;
  const status = el("p", {});
  sign.onclick = async () => {
    sign.disabled = true;
    status.textContent = "";
    try {
      // §10.5. What is signed is the set in the canonical shape the engine
      // compares, and the gesture that releases the key is over the same
      // bytes: `signOver` puts their hash in the assertion's challenge even
      // though what goes to the engine is the signature.
      const decided = await api<{ state?: string; error?: string; message?: string }>("POST", `/offers/${encodeURIComponent(a.offer)}/decisions`, {
        decisions,
        signature: await signOver(member, new TextEncoder().encode(canonicalDecisions(a.offer, decisions))),
      });
      if (decided.status === 0) {
        // Item 2, IOS-10, COPY-04. The signature may or may not have reached
        // the engine; re-signing here would be a second act over the set the
        // household already tried once. The only safe move is to ask again,
        // through the read this hub already carries.
        unknownDecisionResult(member, a.offer, decisions);
        return;
      }
      if (decided.status !== 200) throw new Error(refusal(decided.body, decided.status));
      // The count below is this screen's own, so a `200` that carried no state
      // would have been reported as a decision the engine never recorded.
      if (typeof decided.body.state !== "string") {
        throw new Error("The answer came back in a form this screen could not read, so it cannot say whether this was recorded. Go back and open it again.");
      }
      show(el("h1", {}, "Atarasy"), decisionRecordedCard(kept.length, declined.length), back(member));
    } catch (e) {
      status.textContent = (e as Error).message;
      sign.disabled = false;
    }
  };

  const lineRow = (c: Approval["candidates"][number]) =>
    el("div", { class: "row" },
      el("span", { class: "grow" }, goodsTitle(c)),
      el("span", {}, c.given_by ? L("Free") : yen(c.unit_price * c.quantity)));

  const backToPicking = el("button", {}, L("Back")) as HTMLButtonElement;
  backToPicking.onclick = () => approval(member, a.offer, binding);

  show(
    el("h1", {}, "Atarasy"),
    el("h2", {}, L("Sign this decision")),
    el("p", {}, L("Signing buys the items you keep, from the shops named, at the prices shown. The items you decline are declined, and nothing else is bought.")),
    el("div", { class: "card" },
      el("p", {}, L("You keep")),
      ...(kept.length ? kept.map(lineRow) : [el("p", { class: "muted" }, L("Nothing. You decline every item."))]),
      ...(declined.length ? [el("p", {}, L("You decline")), ...declined.map((c) => el("p", { class: "muted" }, goodsTitle(c)))] : [])),
    el("div", { class: "card" },
      el("div", { class: "row" }, el("span", { class: "grow" }, L("Goods")), el("span", {}, yen(goods))),
      el("div", { class: "row" }, el("span", { class: "grow" }, L("Delivery")), el("span", {}, yen(carriage))),
      el("div", { class: "row" }, el("strong", { class: "grow" }, L("Total")), el("strong", {}, yen(goods + carriage)))),
    el("p", { class: "muted" },
      a.mandate.kind === "standing"
        ? `Under a standing mandate: ${a.mandate.scope}, lapsing ${a.mandate.lapses_at ? day(a.mandate.lapses_at) : "never"} (clause 58).`
        : `Under an individual mandate: ${a.mandate.scope}.`),
    // D-7. Open, one details-free block per decided line's governing terms:
    // this is the step §10a.4 asks the disclosure to be seen on, before the
    // signature below it.
    el("h2", {}, L("Shop terms")),
    ...[...kept, ...declined].flatMap((c) => blockFor(a.disclosures ?? [], c.disclosure, false)),
    el("div", { class: "row" }, sign, backToPicking),
    status
  );
}

/** What a decided set came to, said once so the live path and the recheck path agree. */
function decisionRecordedCard(kept: number, returned: number): Node {
  return el("div", { class: "card" },
    el("p", {}, LANG === "ja"
      ? `${L("Decision recorded")}。${kept} 点を受け取り、${returned} 点を見送りました。`
      : `${L("Decision recorded")}. ${kept} kept, ${returned} declined.`),
    el("p", { class: "muted" }, "What you returned is recorded as a decision of yours, not as nothing (clause 8)."));
}

/**
 * Item 2, IOS-10, COPY-04. A decision's own `POST .../decisions` never
 * answered, so this screen does not know whether it was recorded. The one
 * safe move is to ask again, and the read it asks with is `GET
 * .../approval`, the route this hub already carries for the same offer
 * (`server.ts`'s `carries()`), never a second signature over the set: a
 * WebAuthn assertion is the one act the specification signs, and asking for
 * a second one over an unanswered first is what the statement flow's own
 * `unknownResult` was built to avoid on the settle path.
 */
function unknownDecisionResult(member: Member, offerId: string, decisions: Decision[]) {
  const card = el("div", { class: "card" },
    el("p", {}, L("Result not known yet")),
    el("p", { class: "muted" }, refusal({}, 0)),
    el("p", { class: "muted" }, L("Payment status is not available here."))
  );
  const check = el("button", { class: "primary" }, L("Check result")) as HTMLButtonElement;
  let busy = false;
  check.onclick = async () => {
    if (busy) return;
    busy = true;
    check.disabled = true;
    const got = await api<{ candidates?: { id: string; valence: string }[] }>("GET", `/offers/${encodeURIComponent(offerId)}/approval`);
    if (got.status === 200 && Array.isArray(got.body.candidates)) {
      const outcome = decisionOutcome(decisions, got.body.candidates);
      if (outcome.resolved) {
        show(el("h1", {}, "Atarasy"), decisionRecordedCard(outcome.kept, outcome.returned), back(member));
        return;
      }
      // Read cleanly, but not yet decided: still nothing to sign a second
      // time, so the screen stays here rather than offering a fresh act.
    }
    busy = false;
    check.disabled = false;
  };
  show(el("h1", {}, "Atarasy"), card, el("div", { class: "row" }, check, back(member)));
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
  // D-6, D-7. This screen is the browsing step: it disputes, it does not
  // sign. "Review and sign" (iOS's own label for the same button,
  // `MemberBoxView.swift`'s `openStatementApproval`) opens
  // `statementReview()`, where the terms are open and the one passkey
  // prompt is.
  const sign = el("button", { class: "primary" }, L("Review and sign")) as HTMLButtonElement;

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
        el("strong", { class: "grow" }, `${goodsTitle(l)} × ${l.quantity}`),
        el("span", {}, missing ? L("Not charged") : l.given_by ? L("Free") : yen(l.amount))),
      // Clause 10. A gift arrives at its price and is never billed, and the
      // screen says who gave it rather than leaving a zero to be read as luck.
      el("p", { class: "muted" },
        l.given_by
          ? `${L("Gift from %@", l.given_by)}. Never billed to you (clause 10).`
          : missing
            ? `${L("Sold by %@", l.merchant)}. ${L("Made by %@", l.maker)}.`
            : `${yen(l.unit_price)} ${l.quantity > 1 ? `× ${l.quantity}` : "each"}. ${L("Sold by %@", l.merchant)}. ${L("Made by %@", l.maker)}.`),
      el("p", { class: "muted" },
        wasKept
          ? "You kept this when you decided. It is here because it is on the same bill."
          : missing
            ? "The collection says this was not in the box. You are never charged for it and it is no claim against you. If it was there, dispute it."
            : "The collection found this used."),
      // Question 46. The collection's own words, as text (clause 54).
      ...(missing && l.note ? [el("p", { class: "muted" }, `The collection's note: ${l.note}`)] : []),
      // D-7. Collapsed on this browsing view; open on `statementReview()`.
      ...blockFor(st.disclosures ?? [], l.disclosure, true),
      // §6.5, §11.2. Only a consumed or missing line can be disputed: a kept
      // line is one this household signed itself.
      ...(wasKept ? [] : [el("div", { class: "row" }, mark), note])
    );
  });
  refreshTotal();

  // D-6, D-7. Disputing is done; what is signed is frozen and shown with its
  // terms open on `statementReview()`, never here.
  sign.onclick = () => statementReview(member, st, disputed);

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
    el("p", { class: "muted" }, `This box was offered until ${day(st.expires_at)}.`),
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
    el("div", { class: "row" }, sign, back(member))
  );
}

/**
 * D-6, D-7. The review step for a physical statement: the lines as they
 * will be signed (read-only; disputing is done, back on the browsing
 * screen), the total, carriage stated apart, the merchants' own terms drawn
 * open, and the one "Sign with passkey" button (`22` UX-06, `04b` §2.2c).
 */
function statementReview(member: Member, st: Statement, disputed: ReadonlySet<string>) {
  const sign = el("button", { class: "primary" }, L("Sign with passkey")) as HTMLButtonElement;
  const status = el("p", {});
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
            await showReceipt(member, st.offer, stood.body, "refused", st.disclosures);
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
            await showReceipt(member, st.offer, stood.body, mine, st.disclosures);
            return;
          }
          // Requirement 5. Neither the signature nor the read that was meant
          // to explain it answered: this screen genuinely does not know
          // whether the box settled, and re-signing here would risk a second
          // attempt over a statement that may already have. The one honest
          // move is to offer to ask again, not a fresh act.
          unknownResult(member, st.offer, st.disclosures, refusal(settled.body, settled.status));
          return;
        }
        throw new Error(refusal(settled.body, settled.status));
      }
      // A `200` whose body carries no charge is not a settlement this screen
      // can report as one: the engine always names the figure.
      if (typeof settled.body.charged !== "number") {
        throw new Error("The answer came back in a form this screen could not read, so it cannot say whether this settled. Open the list again before signing a second time.");
      }
      await showReceipt(member, st.offer, settled.body, "signed", st.disclosures);
    } catch (e) {
      status.textContent = (e as Error).message;
      sign.disabled = false;
    }
  };

  const goods = statementTotal(st.lines, disputed);
  const carriage = st.carriage ?? 0;
  const lineRow = (l: Statement["lines"][number]) =>
    el("div", { class: "row" },
      el("span", { class: "grow" }, goodsTitle(l)),
      el("span", {}, l.valence === "lost" ? L("Not charged") : l.given_by ? L("Free") : disputed.has(l.candidate) ? L("Not charged") : yen(l.amount)));

  const backToDisputing = el("button", {}, L("Back")) as HTMLButtonElement;
  backToDisputing.onclick = () => statement(member, st.offer);

  show(
    el("h1", {}, "Atarasy"),
    el("h2", {}, L("Sign this statement")),
    el("p", {}, "Signing confirms what the collection recorded, except the lines you marked, and lets the shops named charge the goods amount below."),
    el("div", { class: "card" }, ...st.lines.map(lineRow)),
    el("div", { class: "card" },
      el("div", { class: "row" }, el("span", { class: "grow" }, L("Goods")), el("span", {}, yen(goods))),
      el("div", { class: "row" }, el("span", { class: "grow" }, L("Delivery")), el("span", {}, yen(carriage))),
      el("div", { class: "row" }, el("strong", { class: "grow" }, L("Total")), el("strong", {}, yen(goods + carriage)))),
    // D-7. Open, per line's governing terms: this is the step §10a.4 asks
    // the disclosure to be seen on, before the signature below it.
    el("h2", {}, L("Shop terms")),
    ...st.lines.flatMap((l) => blockFor(st.disclosures ?? [], l.disclosure, false)),
    el("div", { class: "row" }, sign, backToDisputing),
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
        ? `This box has settled${r.settled_at ? `, on ${day(r.settled_at)}` : ""}.`
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
 * Requirement 5, IOS-10, COPY-04. **An unknown result offers only "Check
 * result", never a fresh act.** This is the one case `showReceipt`'s own
 * retries cannot resolve: the signature never answered, and the settlement
 * read that was meant to say whether it went through failed too, so this
 * screen genuinely does not know. Re-signing here would risk a second
 * settlement attempt over a statement that may have already settled; the
 * only safe move is to ask the engine again, which is what the one button
 * does.
 */
function unknownResult(member: Member, offerId: string, disclosures: Statement["disclosures"], notice: string) {
  const busy = { current: false };
  const card = el("div", { class: "card" },
    el("p", {}, L("Result not known yet")),
    el("p", { class: "muted" }, notice),
    el("p", { class: "muted" }, L("Payment status is not available here."))
  );
  const check = el("button", { class: "primary" }, L("Check result")) as HTMLButtonElement;
  check.onclick = async () => {
    if (busy.current) return;
    busy.current = true;
    check.disabled = true;
    const stood = await api<Receipt & { error?: string }>("GET", `/offers/${encodeURIComponent(offerId)}/settlement`);
    if (stood.status === 200) {
      await showReceipt(member, offerId, stood.body, "unanswered-unknown", disclosures);
      return;
    }
    busy.current = false;
    check.disabled = false;
  };
  show(el("h1", {}, "Atarasy"), card, el("div", { class: "row" }, check, back(member)));
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
async function showReceipt(member: Member, offerId: string, r: Receipt, path: ReceiptPath, disclosures: Statement["disclosures"]) {
  const got = await api<unknown>("GET", `/offers/${encodeURIComponent(offerId)}/corrections`);
  const corrections = got.status === 200 ? validateCorrections(got.body, offerId) : null;
  show(el("h1", {}, "Atarasy"), receipt(r, path), ...correctionsCard(corrections, disclosures), back(member));
}

/**
 * §6.6. The merchant's own words are shown as text, never as a link or
 * markup (clause 54): `el()` appends every string child as a text node, so
 * a note is never parsed as HTML here.
 */
function correctionsCard(c: Corrections | null, disclosures: Statement["disclosures"]): Node[] {
  if (!c || c.corrections.length === 0) return [];
  return [el("div", { class: "card" },
    el("p", {}, "The merchant of record has appended the following to the settlement above. There is nothing here for you to sign or dispute."),
    ...c.corrections.map((line) =>
      el("div", {},
        el("p", {}, `${line.kind === "refund" ? "Refund" : "Collection"} from ${line.merchant}: −${yen(line.amount)}, ${day(line.corrected_at)}.`),
        el("p", { class: "muted" }, line.note))
    ),
    el("p", {}, `Net after corrections: ${yen(c.net)}.`),
    ...correctionReturnRows(c, disclosures))];
}

/**
 * SPEC §6.6a. A refund the issuer later returned, and the shop's own
 * repayment once it reports one. This platform moved no money either time and
 * never will: the shop reaches the household by whatever it signed as its own
 * contact, or, where it signed none, by the return terms already beside its
 * disclosure. Nothing here is sent to the merchant and there is no refund
 * action to take (clause 54).
 */
function correctionReturnRows(c: Corrections, disclosures: Statement["disclosures"]): Node[] {
  if (!c.returns || c.returns.length === 0) return [];
  const byId = new Map(c.corrections.map((row) => [row.id, row]));
  return c.returns.map((ret) => {
    const original = byId.get(ret.correction);
    const amount = original ? yen(original.amount) : "";
    return el("div", { class: "card" },
      ret.state === "returned"
        ? el("p", {}, `The refund of ${amount} from ${ret.merchant} did not reach you. The shop still owes it to you, off this platform.`)
        : el("p", {}, `${ret.merchant} reports it repaid this another way.`),
      el("p", { class: "muted" }, ret.note),
      ...merchantContactOrTerms(disclosures, ret.merchant));
  });
}

/**
 * SPEC §6.6a. A correction_return has no product, so the merchant's standing
 * disclosure (its `product`-less block) is what "its return terms" names. Where
 * the merchant signed a contact there, that is shown; where it signed none, the
 * block's own items stand in its place. Nothing is shown for a merchant with no
 * standing block at all: this hub never invents terms.
 */
function merchantContactOrTerms(disclosures: Statement["disclosures"], merchant: string): Node[] {
  const block = disclosures.find((b) => b.merchant === merchant && b.product === null);
  if (!block) return [];
  if (block.contact) return [contactLink(block.contact)];
  return [el("dl", { class: "terms" }, ...block.items.flatMap((i) => [el("dt", {}, i.label), el("dd", {}, i.value)]))];
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
    shell(member, "limits", failure(
      read.status === 200
        ? "What you have set came back in a form this screen could not read. Nothing here has changed."
        : refusal(read.body, read.status)));
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

  // The picker labels this screen already had, translated where the
  // dictionary has a matching iOS element and left as plain, short English
  // (with an inline Japanese equivalent) where it has none: iOS reads this
  // same picker through `Stepper` and a free-form hour count rather than a
  // fixed set of choices, so there is no exact string to copy for "an hour"
  // or "a day" here.
  const coolingLabel = (label: string, seconds: number | null): string => {
    if (seconds === null) return L("No time to undo");
    if (LANG !== "ja") return label;
    return seconds === 3600 ? "1 時間" : seconds === 86400 ? "1 日" : label;
  };
  const dailyLabel = (label: string, perDay: number | null): string =>
    perDay === null ? L("No daily limit") : yen(perDay);

  // §16.5. How long a decided set waits before it can settle, and can be taken
  // back while it waits.
  const coolingRow: Node[] = [];
  for (const [label, seconds] of COOLING) {
    const chosen = current?.cooling_seconds === seconds || (current === null && seconds === null);
    const b = el("button", { class: chosen ? "chosen" : "" }, coolingLabel(label, seconds));
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
    const b = el("button", { class: chosen ? "chosen" : "" }, dailyLabel(label, yenPerDay));
    b.onclick = () =>
      write(
        { ceiling_daily: yenPerDay },
        current && !lower(current.ceiling_daily, yenPerDay)
          ? "raising or removing a daily ceiling is a loosening"
          : null
      );
    dailyRow.push(b);
  }

  shell(member, "limits",
    el("p", { class: "muted" }, L("These are the limits your agent works within. Nothing outside them can be bought for you, and loosening them needs the people you name here.")),
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
          `Also in what you signed: nothing offered to you may cost more than ${yen(current.ceiling_out_of_network)} at a shop outside the network, and this lapses on ${day(current.lapses_at)} unless you set something again.`)]
      : [el("p", { class: "muted" }, "Setting one of these also records a ceiling of ¥100,000 on an offer from outside the network, and a lapse a year from now.")]),
    status
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
        : refusal(got.body, got.status)), backTo(member, "account"));
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
      el("h2", {}, L("This account cannot be deleted yet")),
      el("ul", {}, ...blockers.map((b) => el("li", {}, BLOCKERS[b.kind] ?? `${b.kind} (${b.id})`))),
      status,
      backTo(member, "account")
    );
    return;
  }

  const save = el("button", {}, L("Save a copy of my records")) as HTMLButtonElement;
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

  // D-6, requirement 4: one review screen per act, with the WebAuthn
  // assertion below as the one explicit gesture. An "I understand this
  // deletes my account" checkbox used to gate this button, duplicating the
  // confirmation the passkey prompt itself already asks for; the review
  // text above (what is kept, what is not) is the review, and the passkey
  // call is the act, exactly as it is for a decision or a statement.
  const del = el("button", {}, L("Delete account")) as HTMLButtonElement;

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
        el("p", {}, L("Account deleted")),
        el("p", { class: "muted" }, `${count} record${count === 1 ? "" : "s"} removed.`)));
    } catch (e) {
      status.textContent = (e as Error).message;
      del.disabled = false;
    }
  };

  show(
    el("h1", {}, "Atarasy"),
    el("h2", {}, L("Delete account")),
    el("p", {}, L("Deleting removes your account and everything this host holds for it. Shops keep their own records of sales. Gifts you shared with other households stay in their records, showing you as a member who has left.")),
    el("div", { class: "row" }, save),
    el("div", { class: "row" }, del, backTo(member, "account")),
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
  const b = el("button", {}, L("Back")) as HTMLButtonElement;
  b.onclick = () => offers(member);
  return b;
}

/** As `back`, but to a named tab rather than always to the Inbox. */
function backTo(member: Member, tab: Tab) {
  const b = el("button", {}, L("Back")) as HTMLButtonElement;
  b.onclick = () => (tab === "limits" ? protections(member) : tab === "account" ? account(member) : offers(member));
  return b;
}

const member = load();
if (member) offers(member); else setup();
