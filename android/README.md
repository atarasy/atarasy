# Android member client

This is the Kotlin and Jetpack Compose implementation boundary for Android. It currently establishes the independent canonical contract, exact Credential Manager request/response adapter, closed authenticated HTTP/session boundary, Android Keystore protected session storage, scoped offer list and detail projections, phone/tablet adaptive shell and saved navigation state.

The HTTP boundary uses only the configured HTTPS origin, refuses redirects, does not install a cookie handler, bounds request and response bytes, requires `Cache-Control: no-store`, and checks the exact session response schema. Bearer state is cleared from memory when the activity stops. The on-disk session is AES-256-GCM encrypted with authenticated environment and household scope using a non-exportable, unlocked-device-only Android Keystore key. App backup and device transfer are disabled. A missing/replaced key, scope swap, truncation or changed ciphertext fails closed.

After sign-in, the Offers screen reads each presenter owned by the authenticated session with at most four requests in flight. List and detail responses use exact schemas and reject unknown or missing fields, unsafe numbers, invalid protocol states, duplicate candidates, and any household, presenter, or offer scope mismatch. Leaving the app clears the rendered private state as well as the in-memory bearer authority.

Opening an offer also reads its server review. Digital approvals are checked against the displayed candidates, alternatives, exclusions, mandate terms, and disclosures. Physical statements recompute line amounts and the canonical challenge from the selected goods; settled boxes validate their receipt totals and signing scope. A review failure never supplies a decision or payment authority.

Digital decisions use a two-stage review and signing boundary. Complete local keep/decline choices produce a canonical decision and safe total, then the server's frozen operation is checked against the session, offer, approval, mandate, RP, credential and derived challenge. The operation is encrypted under the installation Keystore key before signing. Immediately before Credential Manager opens, the operation is read again and must be unchanged. Submission atomically marks the journal attempted with only a signature digest before the first network byte is sent; a lost response becomes unresolved and cannot be submitted again. Read-only outcome reconciliation validates the immutable offer terms and original canonical choices.

Physical statements use the same durable operation boundary. The client reconstructs the statement from consumed, kept, defaulted and collection-confirmed lost lines, applies only eligible disputes, preserves gift zero amounts, and rechecks the server's frozen statement, mandate, carriage, canonical bytes and challenge before signing. Settlement readback recomputes the signed statement from the receipt and attributes it to this device only when the recorded confirmation digest matches.

The Saved screen opens the encrypted journal without exposing operation identifiers. It can reconcile decisions, statements and cooling-window withdrawals without resubmitting them, and it can cancel an unattempted prepared operation through the scoped acknowledgement route. A withdrawal first rereads the committed decision and its frozen review, then verifies the original immutable offer, choices, mandate, totals, decision revision, cooling deadline and next incarnation. The withdrawal operation is reread before Credential Manager opens and uses the same claim-before-dispatch rule; its historical result must restore the same immutable offer in a wholly presented state.

The Access screen validates the complete permission history and pending permission-request terms before rendering them. Permission grants bind the requester, single supported field, purpose, review deadline and access deadline to the issuer's canonical digest. Grant, decline and revocation responses must preserve the reviewed grant or request exactly; an unconfirmed write forces a fresh read before another action.

The development build deliberately has no Android passkey release identity. A usable ceremony requires all of the following to agree:

- a reviewed release signing certificate;
- its `android:apk-key-hash:<base64url SHA-256 certificate digest>` in Valence `androidAppOrigins`;
- `delegate_permission/common.get_login_creds` Digital Asset Links statements for `dev.atarasy.prototype` and the release certificate on every relying-party host;
- a release-signed physical phone and tablet acceptance run.

Build and test with a JDK 17 or newer supported by the pinned Gradle toolchain:

```sh
./gradlew testDebugUnitTest assembleDebug lintDebug assembleRelease
```

The app must pass the server's public-key credential option JSON directly to Credential Manager. It must submit the returned registration or authentication response JSON without converting base64url values, changing omitted fields, or creating a WebAuthn challenge locally.
