# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repository is

**Atarasy**, the reference hub: the screen a member opens to decide on an offer. `atarasy/atarasy`, public, MIT. It is the third of three names, and the three are three different things:

- **Ataraxia** is the constitution, the mark and the future foundation. `~/Documents/GitHub/ataraxia`.
- **Valence** is the specification and the engine underneath an offer. `~/Documents/GitHub/valence`.
- **Atarasy** is this: what a member opens. A fork may claim Ataraxia conformance; it may not use this name.

It has its own repository so that the hub is not filed under the specification's name. Clause 5 lists the hub and the engine separately among what must be open, and a screen inside `valence/` would have read as part of the specification.

**All documents here are in English.** British spelling, no em-dashes, dividers are `----`. The private strategy documents are in the Obsidian vault at `~/Documents/GitHub/hacci/Projects/Atarasy/`; read that folder's `CLAUDE.md` before a change that follows from a decision rather than from a bug. Change flows one way: **decide in the vault → specify in valence → implement here.**

## What is here

| | |
|---|---|
| `src/server.ts` | serves the page, builds the client script with `Bun.build` at start, proxies `/api/*` to the engine. No dependencies |
| `src/client/app.ts` | the screen. Setup (a passkey, registered at `/_identities`), the offers waiting, the approval screen, the confirmation |
| `src/shared/canonical.ts` | §10.5: the canonical form of a decided set and its challenge. Shared with the tests, imported from no implementation |
| `src/shared/encoding.ts` | base64 as the engine reads it; SPKI DER to the PEM `/_identities` takes |
| `test/hub.test.ts` | the hub against a running engine, end to end but for the button |

## Rules that are this repository's

- **The screen renders data and never presentation from a presenter** (clause 54). Text from fields, in the hub's own type. If a field arrives that looks like markup or an ordering directive, the bug is in the engine's contract, not something to render.
- **The hub holds no private key and signs nothing** (clause 35). A confirmation is the browser authenticator's assertion, and the challenge is the decided set (§10.5). Do not add a server-side signing path, however convenient a test would find it.
- **The canonical form in `src/shared/canonical.ts` must equal the engine's byte for byte**, and it must not import the engine's. A hub that agreed by importing would agree by accident, and a second implementation would have nothing to check against. `test/canonical.test.ts` pins the shape.
- **Returned is a decision, not silence.** The screen sends every candidate with a valence. Clause 8 puts what a person declined in their own node.
- **Drive the real thing before believing it.** The whole flow was run in a real browser with Chrome's virtual authenticator on 2026-09-11: a passkey created, an offer seeded under the mandate reference the screen issued, one candidate kept and one returned, and the engine read back `kept`/`returned`. That is the only measurement that covers what `test/hub.test.ts` cannot press, and it is also the only one that has exercised a genuine WebAuthn assertion rather than a simulated one.

  **The screens were rewritten on the night of 2026-09-12 and driven again the same night**, against a scratch engine on port 9710 and this hub on 9711, with a household seeded into three states: a digital offer waiting on a decision, a physical box the route had half collected, and a physical box collected with goods used. What was measured, and none of it is provable from a suite: the list drew the three sections in the right order with no second request per offer; the half-collected box's approval showed one Keep and one Return on the whole screen, with the confirm button disabled until that one line was answered, the consumed line saying it returns on the statement, and each line naming a maker distinct from its merchant; the statement carried the offer's expiry, showed the gift as a gift with its giver instead of a price, drew the product block **and** the standing text beside the gift line, totalled ¥1,500 against the engine's own ¥1,500, and moved to ¥0 with one line disputed; and with the engine killed the list drew a named failure card and said the list was not the whole of it, rather than "Loading." or an empty inbox. **Zero console errors across the whole walk**, which is the measurement that matters most, because the defect this replaced was a `TypeError` inside an `onclick` that made every button do nothing silently.

  **This pass used no authenticator**, so nothing was signed: the member was injected into `localStorage` and the two confirm buttons were checked for their enabled state and not pressed. A run that signs still needs Chrome's virtual authenticator, as the 2026-09-11 one did.
- **Add a probe with a surface.** The valence engine's recurring failure is a field or a route without a test that fails when it breaks. The same rule here: `test/hub.test.ts` exercises the path the screen takes, and a new screen action gets a step there in the same change. **Measured, not asserted**: on 2026-09-11 the two probes for the proxy's narrowing were run against a copy of this server with the narrowing removed, and both failed.
- **The proxy carries the screen's calls and nothing else** (`carries` in `src/server.ts`). A new screen action adds its route there, and a route added there is a route any browser that can open the page can reach on the engine. The engine authenticates nobody by design, so this list is the whole of the boundary.
- **Both of a member's names are the credential's**, the mandate reference and the household's own. The engine keeps the first key registered for a name and refuses a later, different one, so a guessable name is a name somebody else can take first. Deriving only the mandate reference is not enough, and it took a second adversarial round to see why: §16.1 signs a mandate record with the key registered under the **household's** name, so a member whose household name was free could record no protection at all, and the first stranger to register that name owned their ceiling, their co-signers and their cooling window. Do not derive either name from anything a stranger can guess, and do not let what the person types become an identifier.

## Running

```
VALENCE_ENGINE_URL=http://localhost:8787 VALENCE_PRESENTERS=reference-merchant bun run src/server.ts
```

The engine needs `VALENCE_RP_ID` set to the hostname the page is opened at, because that is what a passkey signs for, and it refuses to start without one (§14b). `bun test` starts an engine from `../valence/engine` (or `VALENCE_ENGINE_DIR`) on port 9700 and the hub on 9701; both are chosen not to collide with the conformance harness's 8788, 8888, 8988 and 9088, so the test can run while a sweep is running there. **It runs the engine from that checkout's working tree**, so a mutation left applied there is what this test would measure against.

## What is not built

- **Telling the hub an offer was presented.** The specification's §13.2 sends the hub the decided copy and not the presented one, so this hub asks each presenter it is configured with. It is an open question in `SPEC.md` §15; a change there comes first.
- **Gifts onward.** `kept_as: "gift"` needs a lineage edge, and the screen keeps for the household only (`self`).
- **Every protection but the cooling window and the daily ceiling** (§16): no co-signers, and so nothing that loosens, which is the half clause 47 says needs the people a person named. The categories needing a second signature were here until 2026-09-12, when §16.4 was withdrawn.
- **Anything of the physical binding.** This is the digital binding's screen.

## What a passkey can and cannot sign, which is the shape of this whole hub

An authenticator signs its own data and the SHA-256 of the client's, and never bytes a caller hands it. **So everywhere the specification asks this hub's member for a signature, the member can only send an assertion whose challenge is those bytes.** Three routes take that shape: a decided set (§10.5), a mandate change (§16.1) and a co-signer's signature on a decided set (§16.4). The last two were added on 2026-09-11, the mandate because building the protections screen ran into the wall the decided set had hit that morning, and the co-signature because a review found a family whose co-signer held a passkey could name a category needing a second signature and then have no way at all to give one.

**One route still takes a bare signature and cannot be used from here**: a lineage edge (§7.1), which is what a gift is. The reason it is the exception is not effort. **An edge is verified again every time it is imported**, and an assertion names the host it was made for, so an edge signed by one could be re-verified nowhere but where it was made. The rule is therefore "wherever a person's signature is checked once and then forgotten", and a gift is out of reach from a hub until §7.1 stops re-verifying.

**The trap to know**: a test that signs with a private key it holds proves the engine's side and nothing about the member's, because the browser has no such key. One test here did exactly that, claimed in its own comment to prove what a member can do, and was removed on the day it was written.
