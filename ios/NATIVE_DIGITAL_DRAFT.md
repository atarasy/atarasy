# Native digital decision flow

The authenticated digital approval view allows an explicit choice for each offered candidate. Nothing is preselected. Keep means keep for this household; onward gifting remains outside this increment. Maker, carrier, alternatives, argument against and applicable disclosures remain beside each choice. Leaving or refreshing discards unsent choices.

A complete selection with known carriage can open the digital decision screen. Preparation sends the choices to `/member/decisions/prepare`, verifies the returned approval against the locally read offer and choices, checks the mandate and amounts, reconstructs canonical decisions and independently checks the contextual passkey challenge. No currency is inferred. Unknown carriage, incomplete choice, expiry and unsafe arithmetic prevent a review.

The frozen screen shows each choice beside its terms, the goods and carriage amounts, the mandate version and protections. Confirmation requires explicit review acknowledgement and a separate passkey action. The selected credential and the `atarasy.member-decision-authorisation.1` profile remain separate from login and physical statement approval. A fresh operation review must match the frozen content before the authenticator opens.

`MemberDigitalFlow` discards signing readiness on session changes, stale review, expiry or uncertain submission. Cancelling the passkey sends nothing and retains the review. Cancelling a prepared server operation preserves its saved correlation handle. Returning from a ceremony after logout, account change or leaving the screen never submits an assertion.

The shared operation store now retains an optional profile and an immutable digital-terms digest. Older handles without a profile remain physical statements. The attempt is persisted before the network send, including a digest of the submitted signature; bearer credentials and assertion payloads are not saved. An already attempted operation cannot be submitted again. Restarted accounts discover only saved decisions for their environment, household and granted presenter. Physical flows ignore digital handles.

Result checks perform GET only. The historical decision is checked against the operation ID, expected household and presenter, canonical choices, decision timestamps and digest of immutable offer terms. Changed prices, parties, disclosures or choices do not become a matching result. The UI calls this the decision recorded for the saved operation; it does not infer provider payment, current order status or which physical device approved it.

## Evidence and outstanding scope

The Swift fixture `Tests/AtarasyCoreTests/Fixtures/member-digital-runtime.json` is captured from the Valence PostgreSQL HTTP test based on implementation `25d8ca7`. It contains actual synthetic preparation, pre-decision detail, public session and committed response. Its exporter is opt-in (`ATARASY_DIGITAL_FIXTURE_OUTPUT`) and refuses overwrite. It contains no bearer token, private key or submitted assertion.

Core tests cover service response compatibility, changed scope/terms/amounts/challenge, wrong result data, storage failures, durable attempt recovery, cross-profile refusal, passkey cancellation, session change during ceremony, review change and saved-source filtering. The UI fixture replays the captured responses with a synthetic authenticator and lost response; it is compiled only for UITesting and makes no real network or provider call.

This advances IOS-B15, APP-02 and IOS-10/16, but does not complete them. No device acceptance or deployment is claimed. The current Valence presenter API still refuses digital delivery writes; a proper carriage-quotation path is required before merchant-to-native end-to-end acceptance. Withdrawal/redecision also needs an explicit operation-incarnation design retaining history. The file store's existing private-directory protections are not proof of the separate private-node encryption and recovery requirements.
