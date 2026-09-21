# Native private storage and device lifecycle

The configured native account now opens an authenticated private-node index before exposing protected account actions. An empty node creates one random 256-bit data key. Existing ciphertext with no installation key enters `recoveryRequired`; it never creates a replacement key or presents unreadable records as an empty account.

Remote private records use AES-256-GCM. Authenticated data binds the profile, environment, origin, household, record UUID and revision. The host receives only nonce, ciphertext plus authentication tag, revision and timing metadata. The Swift reader rejects unknown response keys, duplicate or unsorted records, invalid identifiers/numbers, changed envelopes and plaintext-shaped responses. A fixture emitted by the actual Valence PostgreSQL HTTP test decrypts in CryptoKit.

The same account-scoped Keychain key protects the native operation journal. Production no longer writes operation handles as plaintext JSON. Files contain a scope digest and authenticated ciphertext, use complete file protection and mode `0600`, and bind their random operation filename in authenticated data. Submitted-operation fingerprints remain recoverable after restart without exposing their reviewed content on disk.

Keys are non-synchronizing `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` generic-password items. Their service name includes an installation identity stored under complete file protection outside Keychain. If Keychain survives app removal but the application container does not, the new installation identity prevents silent reuse of the old key.

| Event | Native behavior |
|---|---|
| App becomes inactive | Covers the account UI so the app-switcher snapshot does not retain private review content. A system passkey presentation is not mistaken for logout. |
| App enters background/device lock | Clears decrypted account models, fences late HTTP results and drops the in-memory bearer. The saved session remains available for an explicit restore after unlock. |
| Sign out | Clears visible/decrypted state first, removes the local session and asks the service to revoke it. The installation-bound data key remains so a later authenticated login on this installation can reopen the node. |
| Remote credential/session revocation | The next private-node request is refused by Valence. Revocation cannot erase plaintext that was already copied while the device was authorised. |
| Reinstall or new device | Existing host ciphertext without this installation's key enters recovery-required. A recovered passkey alone does not mint a ledger key. |
| Missing/tampered key or ciphertext | Authentication fails and no operation handle or private record is returned. |

This increment implements the IOS-B19 storage boundary and local lifecycle behavior. It does not claim real-device lock/reinstall acceptance. The constitutional 2-of-3 share placement, recovery logging/notice and recovered-key installation remain IOS-B20; cross-origin export and authority retirement remain IOS-B21.
