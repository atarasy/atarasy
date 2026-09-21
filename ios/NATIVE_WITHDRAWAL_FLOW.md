# Native digital withdrawal

The configured member account offers withdrawal review from saved digital decisions. The client reads the immutable original decision outcome and committed review, then prepares a separate `atarasy.member-withdrawal-authorisation.1` operation. It checks the decision identifier, generation canonical bytes, contextual challenge, cooling deadline, original choices and amounts, current mandate scope, and immutable offer terms before saving the operation.

Withdrawal uses the selected credential and required user verification. Immediately before opening the platform ceremony, the client checks the frozen review again. Session changes, expiry, view departure and ceremony cancellation prevent dispatch. A durable attempt is claimed before the submission request; an uncertain response is recovered only with the saved operation's outcome GET. Historical outcomes must name the original decision and expected successor incarnation and contain the unchanged offer terms with reopened choices.

The screen requires an explicit acknowledgement. A recorded withdrawal tells the member to refresh the proposal before choosing again; the original proposal expiry still applies. It does not present withdrawal as payment cancellation, a refund or current order status. The retained cooling right can survive a mandate lapse; the service remains authoritative about eligibility and generation changes.

`MemberWithdrawalTests` replays public responses captured from Valence's synthetic PostgreSQL HTTP test. The UI-only `--member-withdrawal-fixture` scenario adds a synthetic passkey response and a lost submission response. Neither exercises a hardware authenticator, deployed service, payment provider or real-device journey. The embedded fixture is excluded from normal configurations through `ATARASY_UI_TEST_FIXTURES`.

The saved journal carries no session token or assertion. Existing statement and decision handles remain decodable. This increment does not establish deployment acceptance or complete the broader co-signer, recovery and host-move requirements.
