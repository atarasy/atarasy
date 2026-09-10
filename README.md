# Atarasy

**The reference hub. What a member opens.**

[Ataraxia](https://github.com/atarasy/ataraxia) is the constitution. [Valence](https://github.com/atarasy/valence) is the specification and the engine underneath an offer. Atarasy is the screen a person is asked to sign, drawn by a party to no transaction (clause 54), and the one implementation of the hub that carries this name. A fork may claim Ataraxia conformance; it may not use the name.

----

## What it does

Three things, and nothing the engine already does.

- **Serves the screen.** A single page that renders what `GET /offers/{id}/approval` returns: each candidate with its maker and its carrier (clause 12), the alternatives the agent considered and the argument against taking it (clause 59), what was left out and which published rule left it out (clause 36), and whether the one reminder has gone (clause 33). Text from data fields, in the hub's own type. The order of the candidates, the alternatives and the exclusions is the presenter's agent's, which is the one thing here a presenter chooses, and it is a list of text either way (clause 54).
- **Confirms with a passkey.** A member's key is a passkey in the browser's own authenticator. The public half is registered at `/_identities` under two names, both derived from the credential id: the mandate reference, which confirms decided sets (§10.5), and the household's own name, which signs the protections a mandate carries (§16.1). A decided set is confirmed by the authenticator's assertion, whose challenge is the SHA-256 of the set's canonical form. The hub never sees a private key and signs nothing on anyone's behalf (clause 35).
- **Carries the screen's four calls to the engine** under `/api`, because the engine sets no CORS headers and should not, and refuses every other route. A hub that forwarded whatever it was handed would put the engine's whole surface behind a page anyone can open, and the reference engine authenticates nobody by design.

What is declined is sent as a decision, not left as silence. That is the event the specification exists for.

## Running it

```
VALENCE_ENGINE_URL=http://localhost:8787 VALENCE_PRESENTERS=reference-merchant bun run src/server.ts
```

| Variable | What |
|---|---|
| `VALENCE_ENGINE_URL` | the engine this hub asks for offers and sends decisions to |
| `VALENCE_PRESENTERS` | the presenters it asks, comma separated. Clause 8: an engine lists offers per presenter and never a household's union, so the union is made here, on the person's side. A deployment reads these from the registry (§17); the reference is told them |
| `PORT` | default 8790 |

The engine listens on 8787 unless `PORT` says otherwise, and it has to be told the hub's hostname, because that is the name a passkey signs for: `VALENCE_RP_ID` equal to the host the page is opened at, which is `localhost` here. It refuses to start without one (specification §14b), and without `VALENCE_RECOVERY_GRACE_DAYS`, which has no recommended figure either.

Open the page, name a household, create a passkey. The page then shows the two references a shop needs. Offers presented to that household appear when a presenter places them; each opens to the approval screen, where every candidate is kept or returned by a tap and the set is confirmed once.

## Checks

```
bun install
bun run typecheck
bun test            # needs the engine: a checkout of atarasy/valence beside this one, or VALENCE_ENGINE_DIR
```

`test/hub.test.ts` starts the engine and the hub, seeds a presenter the way a deployment does, and then does what the screen does after the button: lists what is waiting, reads the approval, registers a P-256 key and confirms a set with an assertion built the way an authenticator builds one. The button itself is the one thing it cannot press.

## What it does not do

- **It does not draft.** Candidates, alternatives and the argument against come from the agent that composed the offer, through the engine. The hub refuses to render a screen that does not carry them, and this page shows that refusal rather than filling the gap.
- **It does not know about an offer until a presenter it asks has presented one.** Nothing in the specification tells a hub that an offer was presented; the decided copy arrives (§13.2), the presented one does not. So this hub asks each presenter it is configured with. That is an open question in the specification's §15, added the day this was written, and it works only for presenters the person already deals with.
- **It does not tell a presenter who a member is.** An offer names a household and a mandate, and both are the credential's id here rather than anything the person typed. How a presenter comes to know them is between the household and the presenter, outside the specification, so the screen shows the person both and leaves the handing over to them. What the person types is a label this browser keeps.
- **It holds nothing of the member's but a name and a credential id**, in the browser's local storage. The node is the engine's hub side (§13.2); this is the screen in front of it.

## Licence

MIT.
