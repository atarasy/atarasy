# Physical statement preparation and result reconciliation

`PreparedMemberStatement` freezes independently constructed physical statement bytes and expected receipt lines. It requires a live session with matching household/presenter, a decided or expired physical offer with consumed goods, no unresolved offered candidates, known carriage, and a matching reviewed statement. The offer's collection due date may already have passed; it is not a digital decision deadline.

Consumed-only dispute choices must be unique and refer to this offer. The canonical line retains its full amount and marks it disputed; expected goods charged excludes that amount. Gifts contribute zero goods charge. Lost goods are outside the statement but remain expected stock-loss lines in the receipt, including the catalogue value of a lost gift. Safe-integer and complete-line checks prevent silent overflow or omission. Preparation does not grant transaction authority and does not verify merchant signatures.

`PendingMemberStatement` holds that preparation and a SHA-256 fingerprint of the exact public signature string the future dispatcher says it submitted. It does not retain the signature, sign, verify an assertion, write a journal or send a request. It is an in-memory value, not crash recovery or proof that a submission occurred.

`MemberClient.reconcile` makes one authenticated GET of the settlement using the original environment, session, household and presenter scope. Session replacement, expiry, revocation and cancellation cannot publish a match. Missing/malformed responses and non-401 HTTP failures stay unresolved. Nothing in this API retries a write.

A matching protocol record requires the exact confirmation fingerprint, payer, presenter, complete line identities/parties/outcomes/disputes and all goods/loss totals. The same offer and same total are insufficient. A different confirmation is not permission to retry; it remains a distinct unresolved operation. Matching reference-engine evidence never establishes provider payment, carriage collection or cryptographic verification of the receipt.

## Authority contract

The proposed member write boundary is specified at Valence commit `2690d6b0feaaec0a0f60934203896f80f7c9c463`, `experiments/member-transactions/CONTRACT.md`. It is an implementation contract, not an enabled API or amendment to canonical protocol bytes. It requires verified login-credential/engine-mandate binding, consistent reviewed revisions, cross-process operation claims, effect idempotency and crash recovery. The reference engine's awaited external effects prevent an HTTP wrapper from promising atomicity by itself.

Digital confirmation read-back needs an operation receipt: offer detail contains no submitted-confirmation ledger. Do not infer the caller's digital operation succeeded from equal valences. The current member HTTP handler and native UI remain read-only.

## Captures and tests

The twelve responses in `responses.json` came from the clean pinned service at `5254b7cc74f993062a72d762b4f9dd4236278e45`. The capture uses actual handler/member-gate reads with test-only session/ownership adapters. It includes digital review/refusal setup, physical detail and statement with known/unknown carriage, missing settlement, settled/read-again receipts, foreign and revoked reads. Physical setup uses an ephemeral helper private key and a bare test signature through the trusted handler. That proves the reference receipt shape, not native passkey signing, member write authorisation, durable effects or deployed transport.

```
bun scripts/member-transaction/capture.ts /path/to/clean/pinned/valence
swift test --package-path ios/AtarasyCore
```

The captured contract pack and Swift test resource are byte-identical; previous capture packs remain historical. No new UI fixture or button is added. Tests cover altered but internally balanced receipts, signature mismatch, missing carriage, invalid scope/disputes, cancellation and late replies after session restoration. A synthetic lost-gift variant tests the independent stock-loss rule separately from actual captures. A negative-control package copy removes confirmation equality; the different-confirmation test must fail.
