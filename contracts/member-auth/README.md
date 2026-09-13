# Member authentication client contract

Service baseline: Valence 5254b7cc74f993062a72d762b4f9dd4236278e45, experiments/member-login/transport.ts and ENROLLMENT.md. This pack is separate from the historical ios-first response corpus.

POST /auth/enrollment/options takes invitation; POST /auth/enrollment/verify takes id and response and returns 201 registered=true. POST /auth/login/options takes an empty object; POST /auth/login/verify takes id and response and returns id, token and expiresAt. GET /auth/session returns id, household, presenters and expiresAt. POST /auth/logout takes an empty object with a bearer token and returns empty 204. All timestamps are integer milliseconds. Successful JSON responses have application/json media type and no-store caching. Auth errors do not establish whether a lost earlier verification completed.

The client inspects the issued session before storing it, binding matching session ID and expiry to the server-derived household. Presenter grants come from that inspection. Storage keys include environment, HTTPS origin and exact household UTF-8 bytes. Restored sessions are re-inspected; no household claimed by the caller becomes authority.

URLSession is ephemeral, rejects redirects, disables cookies/cache/credential storage and enforces time/response-size bounds. Verification is never retried automatically. A generation change prevents stale operations from restoring a session or releasing an old response. Keychain items use kSecAttrAccessibleWhenUnlockedThisDeviceOnly and do not synchronise. See [Apple Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly) and [redirect control](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).

The Swift prototype UI remains synthetic. The core adapters do not perform a system passkey ceremony, choose an RP deployment, certify device storage protection or implement private-node decryption. Live UI, hardware and deployed transport evidence remain separate.
