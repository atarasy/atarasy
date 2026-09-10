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
- **Add a probe with a surface.** The valence engine's recurring failure is a field or a route without a test that fails when it breaks. The same rule here: `test/hub.test.ts` exercises the path the screen takes, and a new screen action gets a step there in the same change. **Measured, not asserted**: on 2026-09-11 the two probes for the proxy's narrowing were run against a copy of this server with the narrowing removed, and both failed.
- **The proxy carries the screen's calls and nothing else** (`carries` in `src/server.ts`). A new screen action adds its route there, and a route added there is a route any browser that can open the page can reach on the engine. The engine authenticates nobody by design, so this list is the whole of the boundary.
- **The mandate's name is the credential's.** The engine keeps the first key registered for a name and refuses a later, different one, so a guessable name is a name somebody else can take first: `mandate-<household>` let anyone hold the key that confirms a named household's offers, and that household could then never register its own. Do not derive the name from anything a stranger can guess.

## Running

```
VALENCE_ENGINE_URL=http://localhost:8787 VALENCE_PRESENTERS=reference-merchant bun run src/server.ts
```

The engine needs `VALENCE_RP_ID` set to the hostname the page is opened at, because that is what a passkey signs for, and it refuses to start without one (§14b). `bun test` starts an engine from `../valence/engine` (or `VALENCE_ENGINE_DIR`) on port 9700 and the hub on 9701; both are chosen not to collide with the conformance harness's 8788, 8888, 8988 and 9088, so the test can run while a sweep is running there. **It runs the engine from that checkout's working tree**, so a mutation left applied there is what this test would measure against.

## What is not built

- **Telling the hub an offer was presented.** The specification's §13.2 sends the hub the decided copy and not the presented one, so this hub asks each presenter it is configured with. It is an open question in `SPEC.md` §15; a change there comes first.
- **Gifts onward.** `kept_as: "gift"` needs a lineage edge, and the screen keeps for the household only (`self`).
- **The second signature a mandate's categories need** (§16.4) and the cooling window (§16.5): the engine refuses correctly and the screen shows the refusal, and there is no co-signer flow.
- **Anything of the physical binding.** This is the digital binding's screen.
