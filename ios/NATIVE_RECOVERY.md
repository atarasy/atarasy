# Native member recovery

The configured account exposes a separate recovery screen. Recovery setup stays closed unless trusted application configuration supplies `AtarasyRecoveryNoticeChannel`, an opaque token for a delivery route independent of the named recoverer. The app never invents a fallback channel.

## Key and share placement

Each installation has a recovery-only P-256 agreement key in a non-synchronizing `WhenUnlockedThisDeviceOnly` Keychain item. Registration binds its public key to the current session credential with a fresh WebAuthn assertion. It does not grant private-node reads.

The owner splits the existing 256-bit private-node key into three 64-byte shares. The construction chooses independent random values A and B and uses C = key XOR A XOR B:

| Participant | Stored components |
|---|---|
| Device | A, B |
| Named recoverer | B, C |
| Host | C, A |

Every pair has all three components and reconstructs the key. One share is missing one uniformly random component. Reconstruction requires two different participant labels and verifies their overlapping component before producing a key.

The device share remains installation-bound in Keychain. The recoverer share is sealed to the named recoverer's public key with ephemeral P-256 ECDH, HKDF-SHA256 and AES-256-GCM. Packet authenticated data binds the profile, purpose, owner, recoverer, configuration/request reference and epoch. The host receives its opaque share, the encrypted recoverer packet and the ledger-key digest.

## Lost-device flow

A replacement installation creates a separate P-256 requester key and sends only its public key. The named recoverer opens the configuration packet locally, seals that share to the requester and signs the exact request and release. The recoverer response never contains the host share or ledger-key digest.

The replacement device cannot receive recovery material while the server log is `notice_pending`. After the trusted service worker records independent delivery, the owner projection supplies the encrypted recoverer release, host share and expected key digest. The app opens the release, reconstructs the key and compares its digest. Before installing it, `MemberPrivateNode` authenticates and decrypts every hosted record with that exact key. A wrong key, malformed packet, changed scope or damaged ciphertext leaves Keychain unchanged and the node in `recoveryRequired`.

The requester key is removed only after successful record verification and key installation. A recovered passkey by itself never creates or replaces a ledger key. The recovery log is readable from the account screen, and a named recoverer gains no standing access to ordinary records.

## Validation and limits

Core tests cover all three reconstruction pairs, duplicate/tampered shares, packet recipient and context binding, wrong-key refusal before Keychain installation, completed replacement-device recovery and strict decoding of a fixture emitted by the Valence PostgreSQL HTTP test. The native client also rejects role projections that expose the host share to a recoverer.

The checked-in app build normally has no independent channel token, so recovery configuration remains visibly unavailable. No delivery provider is connected, and no real-device recovery ceremony has been accepted. These are deployment and device gates for IOS-B20, not results implied by the local simulator and service tests.
