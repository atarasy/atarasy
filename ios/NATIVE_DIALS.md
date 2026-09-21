# Native Dials and mandate co-signatures

The configured member account now opens Dials for authenticated effective mandates and pending changes. It shows the effective version, all four protection fields, lapse and named co-signers. Editing produces a complete next version; it never silently weakens a protection in response to an offer refusal.

Before a passkey ceremony, the UI displays the fixed effective and proposed terms and the signer set derived by Valence from the previous effective version. A zero-co-signer change can become effective after the household signs. A loosening with prior co-signers remains pending until each named signer opens the same change through their own authenticated account and signs the same canonical bytes. Cancellation changes no effective record.

The client validates the exact before/after shape, version increment, signer sets, state and `valence.mandate.2` challenge. It consumes a prepared signature attempt before network suspension. A lost response is shown as unconfirmed and directs the member to refresh the existing change; the app does not create or sign a replacement version. `409` and `422` responses produce contextual stale/pending and invalid-protection guidance.

The test-only Dials fixture contains one effective mandate with zero co-signers and one loosening already waiting for a prior co-signer. Its UI acceptance walks both states and reads back the zero-co-signer change at version 2. Swift transport tests check exact routes and one-use submission. Simulator evidence does not replace real-device passkey or deployed multi-account acceptance.
