# Member offer detail projection

Pinned service: `5254b7cc74f993062a72d762b4f9dd4236278e45`. The six cases in `responses.json` come from the actual engine HTTP handler and member read boundary: digital presented, physical presented, physical collected, foreign resource refusal, missing resource refusal and revoked-session refusal. The capture uses explicit test-only session and ownership adapters, an in-memory engine and ephemeral helper keys. It is not a native login, durable-authority integration or deployed transport measurement.

The offer projection comes from `engine/src/http.ts` (`offerView`, `candidateView`) and `engine/src/common/types.ts`, with the member boundary in `experiments/member-read/gate.ts`. The service checkout must be clean and match the pin before capture. No server code or route scope is changed by this increment. The recovery route is used only by the trusted fixture handler to arrange physical outcomes; it is not made available to the member client.

Regenerate deliberately from the application repository root:

```sh
bun scripts/member-detail/capture.ts /path/to/clean/pinned/valence
python3 scripts/member-detail/sync-fixture.py
```

The Swift test copy must remain byte-identical to `responses.json`. The UI-testing payload contains that same pack and rebinds only offer ID, household and presenter to the existing test-list session. Both the payload and its UI entry are compiled only for UITesting. Regeneration changes random offer/candidate IDs, timestamps and public test signatures, so rerun relevant tests and refresh evidence after doing it.

The detail decoder requires the complete pinned field set, including explicit nullable fields. It validates safe integer quantities/prices/timestamps, known binding/purpose/state/valence values, candidate identity and scope, and disclosure structure/context. Disclosure signatures are transported data; the native decoder does not verify them. UI rendering keeps their items as plain text in supplied order.

The response includes catalogue unit prices but no currency, carriage amount, amount payable, product display title, actual collection timestamp or recovery grace period. Gift attribution does not turn catalogue prices into a household invoice. Physical candidate outcomes are reported facts, and offer expiry is the collection due date. Full statement, approval, transaction submission and provider status remain separate contracts and integration work.
