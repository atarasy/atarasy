# Native statement review and reconciliation

## Composition and display

A configured member account now owns one `MemberStatementFlow`, its existing `MemberClient` and native passkey authoriser, and a shared `FileMemberOperationStore` under app-private Application Support/MemberOperations. Session changes clear displayed review and rediscover only exact-session/environment/household handles. Closing a review invalidates late work. The configuration remains absent in the shipped prototype, so this does not activate a listener or a real member account.

The physical proposal detail links to a statement screen. The member selects disputed consumed lines, requests preparation, then sees the frozen statement: goods/disputed amounts, carriage, household and collection due date, each product's merchant/maker/carrier, quantity, unit price, valence and gift treatment, every disclosure block/version/label/value, and all mandate fields. Text is rendered as text, never presenter markup. `FrozenMemberStatement` validates the statement against the loaded detail and validates the mandate before enabling review. This can refuse a stale detail and requires fresh preparation rather than silently replacing displayed terms.

The member acknowledges the displayed statement and mandate before the passkey button enables. The flow rereads the operation and requires the displayed review, revision and public-key options to remain unchanged. It then calls the native authoriser with the separate statement kind. Statement requests require a single selected canonical credential ID, a 32-byte challenge, the configured RP and required user verification. The actual platform request sets `allowedCredentials`; discoverable login still requires an empty allow-list and retains its earlier options policy.

After the authenticator returns, the flow rechecks selection generation, task cancellation, session expiry and operation expiry before submission. A close or session change cannot cause a late assertion to be sent. Work already submitted may still complete. The transport's persisted attempt claim remains the boundary before dispatch; the flow does not implement another write path. A cancelled native ceremony has no submission. A changed review, an ambiguous failure or a completed submit hides further approval and offers result checking. An explicit cancel action calls only the existing cancellation route and does not infer success from a lost response.

## Restoration and results

The file store now enumerates UUID checkpoints with a bounded directory count. Account restoration discovers the selected session's saved operations; other sessions and environments are not exposed. Selecting a saved handle only reads outcome, even when it was never attempted. It does not reopen signing. Result messages distinguish recorded engine goods amounts from external provider payment, noncommitted states from success, and unresolved transport results from permission to retry.

The exact-session restriction is unchanged. A new login session cannot automatically recover an old session's operation. There is no cross-process dispatcher, checkpoint garbage collection, power-loss durability claim or combined auth/member server in this change. The app-private store is one shared instance per composition; other processes must not write its directory.

## Verification boundaries

Core tests cover frozen review/mandate decoding and totals, explicit native request construction, cancellation/changed review before submission, closing while an authenticator is suspended, result-only restoration and exact-session filtering, uncertainty blocking a second approval, and explicit prepared cancellation. Existing transport tests cover actual service challenge/receipt fixtures and persisted attempt reopening.

The dedicated UITesting configuration adds a synthetic screen fixture. Its fake service and passkey adapter exercise the actual coordinator and SwiftUI screen, but invoke neither network nor platform UI. The UI test checks the frozen total, acknowledgement gate, transition to unresolved, absence of another approval button, and result-only checking on phone and tablet simulators. Debug does not compile the fixture implementation.

Negative controls run only in disposable package copies: removing the post-authenticator generation guard admits a late submission (one intended assertion failure); omitting the platform allow-list assignment fails the actual request-property probe (two assertion failures). These are not real-device ceremony evidence. See `native-statement-validation.json` for verified runs, hashes and captured screenshots.

## Next step

Compose the existing authenticated login/session/read endpoints with the restricted member operation runtime under one configured development origin. Add the matching associated-domain/AASA and signing configuration, then exercise a real iPhone/iPad passkey registration/login, statement approval and response interruption. Do not use the fixture as proof of entitlement, AASA, credential persistence or real assertion verification. Cross-session operation recovery needs a separate explicit contract before widening the existing ownership model. Kotlin Android remains the later phase.
