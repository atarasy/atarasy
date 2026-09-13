# Native member account setup and acceptance

The native account sheet is opt-in. The checked-in simulator build contains no member service origin or environment and offers no registration/login controls. Opening Member account makes no auth request in that build. The sample Overtures inbox remains synthetic even in a build with member account configuration. The account now has a separate authenticated summary list, described in [member proposals](MEMBER_PROPOSALS.md).

## Trusted configuration

The account sheet reads two string values from the built application's Info.plist:

| Key | Required value |
|---|---|
| AtarasyMemberEnvironment | Stable ASCII letters, digits, underscore or hyphen naming the deployment |
| AtarasyMemberOrigin | Canonical HTTPS origin, without credentials, query, fragment or an application path |

Supply these through a reviewed XcodeGen target Info.plist configuration or explicit Info.plist file. Inspect the resulting application plist before installation. Never derive these values from an invitation, scanned URL, notification or text field. The RP identifier is the origin's hostname; this client does not support an independent parent-domain RP. A valid configuration enables real requests, so it must name the intended member transport, not a bare engine or the historical hub proxy.

The initial configuration inventory found no development team, Associated Domains entitlement, AASA file or configured member service in this isolated iOS project. A separate opt-in Development configuration now targets `https://api-dev.vox.delivery`; see [development setup](development/README.md). The default configurations remain unconfigured. `dev.atarasy.prototype` remains a development-only bundle identifier. No domain ownership or signing identity was inferred from unrelated projects or local credentials.

For device acceptance, select the actual team and bundle identifier and sign a separate development build. Associate the controlled domain using `webcredentials:<domain>` and serve the matching app identifier in the domain's `.well-known/apple-app-site-association`. Verify entitlement, provisioning and domain association on each device before interpreting a platform error as an authentication-service problem. Apple requires that association for platform passkey requests. See [Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys), [Supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains) and [Apple's service sample](https://developer.apple.com/documentation/authenticationservices/connecting-to-a-service-with-passkeys).

## Native behaviour

The adapter builds the system [registration request](https://developer.apple.com/documentation/authenticationservices/asauthorizationplatformpublickeycredentialprovider/createcredentialregistrationrequest(challenge:name:userid:)) or assertion request from a pinned ceremony. It decodes canonical unpadded base64url challenge/user bytes, requires a 32-byte challenge, checks expiry and matches the RP to the configured origin. Registration accepts ES256, required discoverable credentials and no attestation conveyance. Both request types require user verification. Registration exclusion lists and login allow lists remain empty. Statement approval requires exactly one allowed credential from the prepared operation; see [native statement flow](NATIVE_STATEMENT_FLOW.md).

The system selects and operates the passkey. The app forwards its credential ID, raw client data and registration attestation or assertion authenticator data/signature/user handle as base64url. It does not hold a signing key. The platform provider controls passkey storage and possible synchronisation; the device-only Keychain setting in this project applies to the bearer session, not to the passkey.

The authoriser presents in the sheet's window, permits one active controller, scopes cancellation to that operation and ignores callbacks from a previous controller. No window means no request. The service still verifies the response and challenge expiry; creating a platform request is not proof of successful authentication.

Enrollment clears the invitation field when submitted and requires a separate login after confirmed registration. Login stores only a server-inspected session via the member client. Restore uses a typed household reference solely to find a scoped local record and re-inspects it. Sign-out clears displayed session state immediately and distinguishes failed local storage updates from unconfirmed remote revocation. Session expiry hides authenticated state on the visible screen and when the app becomes active.

The sheet disables concurrent actions and ordinary dismissal while work is pending. Forced view disappearance cancels the task and hides late completions. Cancellation before verification prevents submission. Once verification has been sent, cancellation or closing cannot undo a server result and may leave a valid locally persisted session; reopen and inspect a saved session or perform a fresh login. No automatic verification retry occurs. Normal sheet dismissal preserves a saved session; it is not sign-out.

## Device acceptance sequence

1. Review the six auth routes against Valence `5254b7cc74f993062a72d762b4f9dd4236278e45`. Compose the opted-in handler behind TLS, trusted admission/rate controls and request bounds. Keep administration and the engine off the public member route surface.
2. Provision a trusted principal and issue a fresh, short-lived invitation through protected delivery. Never archive the invitation, bearer token, credential private key or verification payload in acceptance logs.
3. On an iPhone and an iPad, use Register a passkey. Cancel once before completion and confirm no verification request. With a fresh ceremony, complete system registration and confirm the registered notice with no implied active session.
4. Sign in using the system picker. Confirm household and expiry originate from session inspection. Check that a different household's saved-session lookup does not grant access. Close/reopen and restore the expected record; inspect the session again.
5. Exercise platform cancellation, failed association, expired challenge, session expiry while backgrounded, offline restoration and a lost verification response. Confirm no stale signed-in screen or repeated verification request.
6. Sign out with a working connection and confirm subsequent server access is refused. Repeat with the revocation response lost and confirm the local record is absent while remote status remains unconfirmed. Test a locked-device storage failure separately; do not treat a host Keychain test as that evidence.
7. Keep one record per device with OS/build identifiers, app/service commits, RP and app association checks, observed screen outcomes and redacted server request counts. Report native, service and deployment failures separately. Authenticated proposal device acceptance, transaction approval and private-node recovery remain separate integration gates.

## Current measurement boundary

The package tests create real AuthenticationServices request objects and exercise the account model through injected service/authenticator seams. They do not present a successful system credential ceremony. The simulator UI checks cover the unconfigured account sheet and the existing synthetic journeys. No physical-device, configured network UI, RP/AASA, deployed TLS or hardware storage result is claimed here.
