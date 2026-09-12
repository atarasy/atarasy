# Atarasy Swift design prototype

This isolated development branch contains the first native iPhone/iPad interaction prototype and a small independently implemented Swift canonical codec. It does not connect to a host, use a passkey, contact a payment provider or claim production privacy. Every record is synthetic.

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

Dials/co-signer UI, account enrollment, actual AuthenticationServices, private keys/storage, host migration, operator workbench and the production coordinator are not implemented here. The schemas are an executable native request/statement subset, not all IC-01–08. The proposed integration envelope has no deployed endpoint. The separate contract README and manifest retain those distinctions.

Measured results and screenshots are retained in [the validation record](evidence/validation.json).
