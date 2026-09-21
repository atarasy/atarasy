# Native host move

The configured member account exposes **Exit / Move Host** only when the private node is open and a trusted target environment is bundled as `AtarasyMoveTargetEnvironment` and `AtarasyMoveTargetOrigin`. A deep link, invitation or typed value cannot select the target.

The flow signs in to the target with its own relying party, exports the source archive, decrypts every blind private record on the device and seals the same clear bytes under the target environment's authenticated-data scope with fresh nonces. Record identity, revision and update time remain fixed. After import, the app reads the durable receipt, installs the existing ledger key under the target storage scope, authenticates every target ciphertext, and compares owned offers and the full permission history at both hosts.

The target then issues a WebAuthn challenge bound to its exact durable receipt. The source accepts retirement preparation only after independently verifying that assertion against the household key, target origin and target relying party. A separate source-origin assertion retires source credentials and sessions. The app removes its saved source session only after the retirement response passes scope validation.

Import and retirement are separate user actions. Before target verification, every failure reports that source access remains active. After an import response becomes uncertain, the screen reports an unresolved copy and does not offer retirement. Once verification succeeds, the screen shows target coverage and its receipt while explicitly stating that source access is still active. Only then is the destructive retirement control enabled.

The local service and Swift tests cover exact archive digest validation, target attestation before retirement, source/target route separation, target-AAD re-encryption, target decryption and continued source readability. A real move still requires two configured deployments, supported passkey availability at both relying parties, deployed routing and a physical-device acceptance run.
