# Swift member operation transport

## Implemented surface

`MemberClient` now calls the restricted authenticated prepare, review, submit, outcome and cancel routes from the member runtime. It reuses the existing origin-bound bearer transport, cache refusal, session expiry and generation checks. Login/session endpoints still belong to the earlier composition; the member runtime alone does not expose them. No combined listener or production base URL is installed by this change.

Preparation compares the server's canonical bytes with `PreparedMemberStatement`, validates review household/offer/mandate scope, reconstructs statement lines with disputes, and independently calculates the contextual challenge. Profile, UUID, digest syntax, RP ID, user verification and credential selection are checked. Review reads also match the saved operation ID, expiry and revision. The service-generated fixture proves Swift agrees with the actual service challenge and can decode its committed receipt.

`MemberPreparedOperation.review` is transport data. Its full disclosure/mandate presentation still needs the native review UI; it must not be treated as already displayed or approved. This transport does not invoke a passkey or turn a received review into user consent. Submission accepts an explicit assertion, checks its credential and client-data challenge/origin, and leaves cryptographic verification to the service. Placeholder assertions in transport tests do not establish a native ceremony.

## Checkpoint and interruption

Inject one shared `MemberOperationStore` instance for the app process. `FileMemberOperationStore` uses an app-private directory (0700), UUID-keyed files (0600), a lock and atomic file replacement. Use an Application Support location owned by the app, not a shared app-group or cloud directory. The implementation is not a cross-process lock or a power-loss durability protocol.

A prepared handle is saved before preparation returns. It binds environment/origin, session, household, presenter, offer, canonical bytes, operation ID, expiry, revision, digest and challenge/credential selection. It contains no bearer or full assertion. Before any submission awaits transport, `claim` saves `attempted=true`; storage failure prevents dispatch. Reusing the original handle or reopening the store cannot reset an attempted record. There is no automatic retry, even if the server later reports prepared. A cancelled task after claiming can conservatively leave an attempted record without dispatch.

Keep the operation ID in the owning screen/session's state and reload its handle with `load(id:)`. Outcome reads are permitted after operation expiry while the bound session is still valid. They use only GET and return a validated committed receipt, a noncommitted state or unresolved. A receipt must match operation, household, presenter, internal receipt invariants and canonical line amounts/disputes. This reports engine evidence, not external provider payment.

Transport errors, a generic 404, a changed session or a malformed response remain unresolved; none permits a new effect. The existing exact-session binding intentionally prevents automatic reconciliation after logging into a different session. Cross-session recovery and a restart discovery/index UI are not implemented. The host must retain the operation ID; the store currently offers no enumeration. Preparation-response loss before an ID is received also remains unresolved and must not trigger blind preparation loops.

## Verification

93 Swift tests pass (eight new), including actual service preparation/receipt decoding, signature-free reads, response-loss recovery, reopening persisted attempts, storage failure before send, scope/corrupt receipt refusal, changed challenge/revision, cancellation and preparation persistence. The reopening test simulates restart by constructing a new store; it does not kill the process. Two negative controls in disposable package copies fail the intended tests: removing the pre-dispatch claim causes three assertion failures in one test; removing contextual challenge verification causes one assertion failure in one test.

The pinned generated fixture contains public receipt/credential material, no bearer or private key. Its generator is committed in the service repository. See `member-operation-validation.json` for commits and source/log hashes. No shared engine source or mutation inputs changed.

## Next integration

Connect these core methods to a native review and reconciliation screen, with an app-private store, operation-ID restoration and explicit unresolved state. Render the complete frozen review before enabling native challenge signing; persist correlation before assertion dispatch. Add a configured composition exposing both existing login/session routes and the restricted member runtime, then run a real iPhone/iPad passkey ceremony and interruption walk. Kotlin Android remains the later phase.
