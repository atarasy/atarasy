import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { join } from "node:path";

/**
 * The screens themselves, rendered.
 *
 * **Three independent refutation rounds found the same hole and this file is
 * the answer to it.** Round two reverted five screen fixes at once and the
 * suite stayed green; the judgements moved into `src/shared/`, and round three
 * repeated the measurement with eight reverts and the suite stayed green
 * again. The modules were provable and **nothing proved the screens called
 * them**, which is the half that reaches a member.
 *
 * The script is built exactly as `src/server.ts` builds it and run in a fresh
 * scope per case, against a `fetch` that answers the calls the screen makes.
 * Nothing here signs: `navigator.credentials` is not driven, so the confirm
 * and sign buttons are checked for what they offer and never pressed.
 */
let script = "";
/**
 * **Registering a DOM replaces the global `fetch`, and so does every case
 * here.** `test/hub.test.ts` talks to a real engine over a real socket in the
 * same process, so both are put back: fourteen of its cases went red the first
 * time this file ran beside it.
 */
const realFetch = globalThis.fetch;

beforeAll(async () => {
  GlobalRegistrator.register({ url: "http://localhost/" });
  const built = await Bun.build({
    entrypoints: [join(import.meta.dir, "..", "src", "client", "app.ts")],
    target: "browser",
    minify: false,
  });
  if (!built.success) throw new Error(built.logs.join("\n"));
  script = await built.outputs[0]!.text();
});

afterEach(() => {
  localStorage.clear();
  (globalThis as unknown as { fetch: unknown }).fetch = realFetch;
});

afterAll(async () => {
  (globalThis as unknown as { fetch: unknown }).fetch = realFetch;
  await GlobalRegistrator.unregister();
});

const MEMBER = {
  label: "A member",
  household: "household-AAAAAAAAAAAAAAAA",
  mandate: "mandate-AAAAAAAAAAAAAAAA",
  credential_id: "AAAAAAAAAAAAAAAA",
};

type Route = (path: string, method: string, body: unknown) => { status: number; body: unknown };

/** Render the screen against a set of answers, and hand back what it drew. */
async function render(routes: Route, member: Record<string, unknown> | null = MEMBER) {
  document.body.innerHTML = '<main id="app"></main>';
  if (member) localStorage.setItem("atarasy.member", JSON.stringify(member));
  (globalThis as unknown as { fetch: unknown }).fetch = async (input: string, init?: { method?: string; body?: string }) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    const parsed = init?.body ? JSON.parse(init.body) : undefined;
    const { status, body } = routes(url, method, parsed);
    // `/config` is read with `.json()` and everything under `/api` with
    // `.text()`, so the stub answers both the way a Response does.
    return {
      status,
      json: async () => body,
      text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
    } as unknown as Response;
  };
  // The bundle is the script `src/server.ts` serves, run the way a browser
  // runs it. It carries no import and no export, and nothing is interpolated
  // into it: it is the repository's own build output, verbatim.
  new Function(script)();
  return settled();
}

/** Let the screen's own promises finish before reading what it drew. */
async function settled() {
  for (let i = 0; i < 3; i++) await new Promise((r) => setTimeout(r, 5));
  return document.getElementById("app")!;
}

const text = (el: Element) => (el.textContent ?? "").replace(/\s+/g, " ").trim();
const buttons = (el: Element) => [...el.querySelectorAll("button")].map((b) => text(b));

const candidate = (over: Record<string, unknown> = {}) => ({
  id: "c-1",
  product: "tea-a",
  quantity: 1,
  unit_price: 1200,
  merchant: "shop-x",
  maker: "made-by-tea",
  ships: "carrier-a",
  given_by: null,
  valence: "offered",
  is_exploration: false,
  alternatives: ["a smaller tin"],
  argument_against: "you have two already",
  disclosure: { merchant: "shop-x", product: null },
  ...over,
});

const STANDING = {
  merchant: "shop-x",
  product: null,
  version: "d-1",
  items: [
    { label: "payment", value: "on confirmation" },
    { label: "returns", value: "as published" },
  ],
};

const offerRow = (over: Record<string, unknown> = {}) => ({
  id: "o-1",
  presenter: "presenter-a",
  state: "presented",
  binding: "digital",
  presented_at: 1_000,
  expires_at: 9_999_999_999_999,
  giver: null,
  candidates: [{ id: "c-1", valence: "offered" }],
  ...over,
});

const CONFIG = { presenters: ["presenter-a"] };

describe("the list, as a member sees it", () => {
  test("a box waiting on a signature, a box in the home and a digital offer land in their own sections", async () => {
    const app = await render((url) => {
      if (url === "/config") return { status: 200, body: CONFIG };
      if (url.startsWith("/api/offers?")) {
        return {
          status: 200,
          body: {
            offers: [
              offerRow({ id: "o-digital", presented_at: 3_000 }),
              offerRow({ id: "o-box", binding: "physical", presented_at: 2_000, candidates: [{ id: "c-1", valence: "offered" }] }),
              offerRow({
                id: "o-statement",
                binding: "physical",
                state: "decided",
                presented_at: 1_000,
                candidates: [{ id: "c-1", valence: "consumed" }],
              }),
            ],
          },
        };
      }
      return { status: 404, body: {} };
    });
    const heads = [...app.querySelectorAll("h2")].map((h) => text(h));
    expect(heads).toEqual(["Waiting for your signature", "Boxes with you now", "Offered to you"]);
    // §11. A box is not a draft, and one sentence used to cover both.
    expect(text(app)).toContain("This box is with you");
    expect(text(app)).toContain("The route comes for it on");
    expect(text(app)).toContain("Nothing is ordered if you do nothing");
  });

  test("a presenter that does not answer is a card, and not an empty inbox", async () => {
    const app = await render((url) => {
      if (url === "/config") return { status: 200, body: CONFIG };
      if (url.startsWith("/api/offers?")) return { status: 502, body: { error: "engine_unreachable" } };
      return { status: 404, body: {} };
    });
    expect(text(app)).toContain("presenter-a");
    expect(text(app)).toContain("this list is not the whole of it");
    expect(text(app)).not.toContain("Nothing is waiting for you.");
    // **The card carries a sentence and not a code.** The failure card was the
    // one place a raw engine code still reached a member after the refusal map
    // was written, and asserting the surrounding copy alone did not see it.
    expect(text(app)).toContain("Nothing answered");
    expect(text(app)).not.toContain("engine_unreachable");
  });

  test("a box the collection resolved offers no take-back, and a set the household signed does", async () => {
    // §16.5. The button belongs to a set the household signed. Judging by
    // binding denied it to a box the household had answered itself.
    const app = await render((url) => {
      if (url === "/config") return { status: 200, body: CONFIG };
      if (url.startsWith("/api/offers?")) {
        return {
          status: 200,
          body: {
            offers: [
              offerRow({ id: "o-route", binding: "physical", state: "decided", presented_at: 2_000, candidates: [{ id: "c-1", valence: "returned" }] }),
              offerRow({ id: "o-signed", binding: "physical", state: "decided", presented_at: 1_000, candidates: [{ id: "c-1", valence: "kept" }] }),
            ],
          },
        };
      }
      return { status: 404, body: {} };
    });
    const cards = [...app.querySelectorAll("div.card")];
    const routeCard = cards.find((c) => text(c).includes("The route has resolved this box"))!;
    const signedCard = cards.find((c) => text(c).includes("take it back"))!;
    expect(routeCard).toBeDefined();
    expect(buttons(routeCard)).toEqual([]);
    expect(signedCard).toBeDefined();
    expect(buttons(signedCard)).toContain("Take it back");
    // Nothing settles on a timer, and this card promised one.
    expect(text(app)).not.toContain("settles when its window closes");
  });
});

describe("the approval, as a member sees it", () => {
  const withApproval = (candidates: Record<string, unknown>[]) => (url: string) => {
    if (url === "/config") return { status: 200, body: CONFIG };
    if (url.startsWith("/api/offers?")) return { status: 200, body: { offers: [offerRow()] } };
    if (url.includes("/approval")) {
      return {
        status: 200,
        body: {
          offer: "o-1",
          presenter: "presenter-a",
          expires_at: 9_999_999_999_999,
          reminded: false,
          price_band: null,
          mandate: { kind: "individual", scope: "this offer", lapses_at: null },
          candidates,
          disclosures: [STANDING, { ...STANDING, product: "tea-a", items: [{ label: "returns", value: "eight days for this one" }] }],
          carriage: 500,
          excluded: [],
        },
      };
    }
    return { status: 404, body: {} };
  };

  async function open(candidates: Record<string, unknown>[]) {
    const app = await render(withApproval(candidates));
    const openButton = [...app.querySelectorAll("button")].find((b) => text(b) === "Open")!;
    openButton.click();
    return settled();
  }

  test("it names the maker apart from the merchant, and a gift by its giver", async () => {
    // Clause 12, clause 10. The card printed the merchant as the maker, and a
    // price beside a gift with nobody named.
    const app = await open([candidate(), candidate({ id: "c-2", product: "miso-a", given_by: "made-by-miso", disclosure: { merchant: "shop-x", product: null } })]);
    expect(text(app)).toContain("Sold by shop-x, made by made-by-tea");
    expect(text(app)).toContain("Given by made-by-miso");
    expect(text(app)).toContain("a gift");
  });

  test("only a line still the household's is asked about, and the rest say why not", async () => {
    // §10 step 3c. A screen that asked about every line posted a set the
    // engine refuses, so a half-collected box could never be confirmed.
    const app = await open([candidate({ valence: "consumed" }), candidate({ id: "c-2", product: "miso-a" })]);
    expect(buttons(app).filter((b) => b === "Keep")).toHaveLength(1);
    expect(buttons(app).filter((b) => b === "Return")).toHaveLength(1);
    expect(text(app)).toContain("It comes back on the statement you sign");
    // No money has moved, and the same card says so.
    expect(text(app)).not.toContain("already been settled");
  });

  test("a box's expiry is a fact on the screen and a digital offer's is a deadline", async () => {
    // `04b` §2.2b. A digital offer closes and nothing is ordered; a box is
    // goods in a home, and what resolves it is the collection, so the deadline
    // is not the person's event. One sentence used to cover both.
    const physical = await render((url) => {
      if (url === "/config") return { status: 200, body: CONFIG };
      if (url.startsWith("/api/offers?")) return { status: 200, body: { offers: [offerRow({ binding: "physical" })] } };
      return withApproval([candidate()])(url);
    });
    [...physical.querySelectorAll("button")].find((b) => text(b) === "Open")!.click();
    const box = text(await settled());
    expect(box).toContain("This box is with you");
    // Question 44. One date, in the swap's words, carrying the expiry §10a.5
    // needs and not reading as the person's deadline.
    expect(box).toContain("The route comes for it on");
    expect(box).toContain("which is when this offer closes");
    expect(box).not.toContain("Open until");

    const digital = await open([candidate()]);
    expect(text(digital)).toContain("Open until");
    expect(text(digital)).not.toContain("This box is with you");
  });

  test("a product block is drawn beside the standing text and never in its place", async () => {
    // §10a.5. A product block carries only what differs, so drawing it alone
    // took the payment and delivery terms off the screen entirely.
    const app = await open([candidate({ disclosure: { merchant: "shop-x", product: "tea-a" } })]);
    const body = text(app);
    expect(body).toContain("eight days for this one");
    expect(body).toContain("on confirmation");
    expect(body).toContain("shop-x, for this product:");
    expect(body).toContain("shop-x, in general:");
  });

  test("an offer that comes back unreadable is said so, not drawn as a dead button", async () => {
    // A `200` whose body could not be read used to reach the renderer and
    // throw inside an onclick with no handler.
    const app = await render((url) => {
      if (url === "/config") return { status: 200, body: CONFIG };
      if (url.startsWith("/api/offers?")) return { status: 200, body: { offers: [offerRow()] } };
      if (url.includes("/approval")) return { status: 200, body: "<html>not json</html>" };
      return { status: 404, body: {} };
    });
    const openButton = [...app.querySelectorAll("button")].find((b) => text(b) === "Open")!;
    openButton.click();
    expect(text(await settled())).toContain("could not read");
  });
});

describe("the statement, as a member sees it", () => {
  const LINES = [
    { candidate: "c-1", product: "tea-a", merchant: "shop-x", maker: "made-by-tea", ships: "carrier-a", given_by: null, valence: "consumed", quantity: 1, unit_price: 1200, amount: 1200, disclosure: { merchant: "shop-x", product: null } },
    { candidate: "c-2", product: "miso-a", merchant: "shop-x", maker: "made-by-miso", ships: "carrier-a", given_by: "made-by-miso", valence: "consumed", quantity: 1, unit_price: 700, amount: 0, disclosure: { merchant: "shop-x", product: null } },
  ];
  const routes = (url: string) => {
    if (url === "/config") return { status: 200, body: CONFIG };
    if (url.startsWith("/api/offers?")) {
      return { status: 200, body: { offers: [offerRow({ binding: "physical", state: "decided", candidates: [{ id: "c-1", valence: "consumed" }] })] } };
    }
    if (url.includes("/statement")) {
      return {
        status: 200,
        body: { offer: "o-1", household: MEMBER.household, expires_at: 9_999_999_999_999, lines: LINES, disclosures: [STANDING], carriage: 500 },
      };
    }
    return { status: 404, body: {} };
  };

  async function openStatement() {
    const app = await render(routes);
    [...app.querySelectorAll("button")].find((b) => text(b) === "See what came back")!.click();
    return settled();
  }

  test("it carries the expiry, prices no gift, and says the carriage is outside the total", async () => {
    const app = await openStatement();
    const body = text(app);
    expect(body).toContain("This box was offered until");
    expect(body).toContain("Given by made-by-miso");
    // §6.2. The gift adds nothing, which is what the engine charges.
    expect(body).toContain("To be charged for the goods: ¥1,200");
    expect(body).toContain("The carriage above is not in this figure");
  });

  test("disputing a line takes it out of the total", async () => {
    const app = await openStatement();
    [...app.querySelectorAll("button")].find((b) => text(b) === "I did not use this")!.click();
    expect(text(document.getElementById("app")!)).toContain("To be charged for the goods: ¥0");
  });
});
