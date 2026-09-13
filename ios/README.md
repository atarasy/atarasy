# Atarasy Swift design prototype

This isolated development branch contains the first native iPhone/iPad interaction prototype and a small independently implemented Swift canonical codec. The default sample inbox does not connect to a host or contact a payment provider, and its records are synthetic. The separate member account flow is enabled only by trusted service configuration; no production privacy or deployed integration is claimed.

## Run

Use the installed Xcode with an available iOS simulator and XcodeGen. From the repository root:

```sh
xcodegen generate --spec ios/project.yml
open ios/AtarasyPrototype.xcodeproj
```

Select the AtarasyPrototype scheme and an iPhone/iPad simulator. Signing is disabled for this simulator prototype. The bundle identifier is a development-only identifier; no associated domain or production app identity is configured. iOS 17 is the prototype's API floor, not a settled supported-device promise. The first measured toolchain is recorded in the validation record.

The app starts at Overtures. Choose a digital proposal or physical statement. Digital unselected lines are explicitly returned when the simulated decision is submitted; leaving the screen sends nothing. Only consumed physical lines have dispute controls. Gifts remain free and carriage remains explicit.

Use the labelled prototype scenarios to lose an acknowledgement, omit carriage or invalidate a review. After a simulated lost reply, close/reopen the app and check the original result: the simulated effect count remains one. Reset is destructive only to that synthetic scenario. Presentation and journal state use UserDefaults solely for these fake records; it is not the proposed private production store.

## Checks

```sh
swift test --package-path ios/AtarasyCore
bun scripts/ios-first/generate-vectors.ts
python3 -m venv /path/to/isolated-contract-tools
/path/to/isolated-contract-tools/bin/pip install -r scripts/ios-first/requirements.txt
/path/to/isolated-contract-tools/bin/python scripts/ios-first/validate-contracts.py
python3 scripts/ios-first/verify-engine-vectors.py --engine-repo /path/to/valence
xcodebuild -project ios/AtarasyPrototype.xcodeproj -scheme AtarasyPrototype -destination 'platform=iOS Simulator,id=<available-device-id>' test
```

Generated canonical vectors are committed and copied into package test resources. If intentionally regenerated, update the resource copy in the same change; the structural validator checks byte equality. The Web generator and independent Swift implementation are checked against pinned engine Git objects, without importing a running or mutated engine working tree.

UI tests exercise household filtering, arrival ordering, partial-source display, cancellation, missing-carriage refusal and physical dispute/lost-response/relaunch/read-back. They test the native simulated experience, not WebAuthn, deployed authorisation, financial idempotency or hardware credentials. Core tests add canonical byte/hash/challenge compatibility, invalid values, cancellation and local operation restoration.

## What remains

Dials/co-signer UI, private-node key storage, host migration, operator workbench and the production coordinator are not implemented here. Native account presentation and AuthenticationServices request handling are now implemented, with device acceptance still outstanding. The schemas are an executable native request/statement subset, not all IC-01–08. The proposed integration envelope has no deployed endpoint. The separate contract README and manifest retain those distinctions.

Measured results and screenshots are retained in [the validation record](evidence/validation.json).

## Reference response increment

The core now also decodes the pinned engine's settlement read response and preserves HTTP/refusal distinctions without treating a receipt as provider-paid. [The response pack](../contracts/ios-first/README.md) records 27 actual in-process handler responses and source provenance. The native UI still uses its original synthetic presentation model; transport, credentials and authenticated integration remain separate work. The first UI screenshots/validation record describe the earlier prototype commit, not a fresh device test of this decoder increment.

The publication increment adds mandate response validation, including household/ID binding and null/zero handling. Its current tests and source/log hashes are in [the publication validation record](evidence/publication-validation.json). The earlier evidence files remain historical checkpoints. Native screens still use synthetic data.

## Member client increment

The opt-in Swift core now includes typed enrollment/session requests, authenticated member reads, an ephemeral URLSession transport and scoped Keychain session storage. The session actor inspects server grants before persistence and rejects stale, expired or differently scoped results. It clears local credentials before attempting remote logout and preserves uncertain outcomes. At that checkpoint, the prototype UI remained synthetic and did not compose the client or present AuthenticationServices; the native account increment below adds that composition.

[The separate auth contract](../contracts/member-auth/README.md) pins seven captured responses from Valence 5254b7c. [The member client validation](evidence/member-client-validation.json) records 33 passing Swift tests and a successful iOS Simulator build. Controlled URLProtocol tests exercise the real URLSession adapter; the host Keychain test checks save/load/remove and scope separation. These are not network TLS, device-lock, hardware passkey or live UI acceptance evidence.

## Native passkey and account increment

Member account now opens a separate sheet. The configured flow connects system passkey registration/assertions to the typed member client, with session restoration, expiry and logout handling. The checked-in build has no service configuration, so the sheet explains that sign-in is unavailable and sends no auth request. The sample inbox remains synthetic.

See [native setup and acceptance](NATIVE_MEMBER_SETUP.md) for the trusted Info.plist keys, device identity/domain prerequisites, lifecycle behaviour and separate device checks. [Native validation](evidence/native-passkey-validation.json) records this increment's measurements; earlier evidence remains historical.

## Authenticated proposal list increment

The configured member account now loads read-only summaries from its server-derived presenter grants. Each source remains visibly loading, checked or unavailable. Refresh, logout, expiry and account switching invalidate stale results. The sample inbox remains separate; authenticated detail and approval are not yet connected.

[Proposal behaviour and test configurations](MEMBER_PROPOSALS.md) describe the four-request concurrency bound, incomplete-source handling, test-only fixture scheme and next integration steps. [Proposal validation](evidence/member-proposals-validation.json) retains current measurements without replacing earlier checkpoints.

## Authenticated detail increment

Member proposal rows now open independently decoded native details. The screen preserves product references, quantities, merchant/maker/carrier identity, gifts and disclosure text, and distinguishes physical reported outcomes from digital choice status. It does not invent currency, totals, recovery facts or signing results.

[Detail behaviour and lifecycle](MEMBER_DETAIL.md) describes validation, navigation and remaining statement/approval work. [Detail validation](evidence/member-detail-validation.json) keeps this increment's measurements separate from sample and device evidence.
