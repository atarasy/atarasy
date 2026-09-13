# Member review projections

The application reads the already allowed `GET /offers/{id}/approval` and `GET /offers/{id}/statement` routes after refreshing the owned offer. `MemberApproval` and `MemberStatement` independently validate the closed response shapes against that offer. Candidate identity, quantities, prices, parties, gift attribution, outcomes, expiry and disclosure blocks must agree. These are sequential reads, not an atomic snapshot, version lock or authority to transact.

The nine responses in `responses.json` came from the actual clean pinned Valence handler and member read boundary at `5254b7cc74f993062a72d762b4f9dd4236278e45`. Session inspection and ownership resolution are test adapters, the engine is in memory, and helper keys are ephemeral. No native authentication, network service, durable session or device association is measured by this pack.

| Case | Meaning |
|---|---|
| digital-missing-deliberation | Actual 422 before deliberation is recorded |
| digital-detail | Offer used to cross-check approval |
| digital-unknown-carriage | Alternatives, argument against, exclusions, standing mandate and no delivery |
| digital-known-carriage | The same offer with explicitly zero carriage |
| physical-detail | Collected offer with two consumed lines, including a gift |
| physical-unknown-carriage | Null carriage and the service's zero-placeholder challenge |
| physical-known-carriage | Recorded carriage 550, goods 3000 and gift goods 0 |
| foreign-statement | Neutral 404 for an unowned offer |
| revoked-approval | Neutral 401 for a revoked test session |

Both offers contain standing and product-specific signed disclosure blocks. Native display preserves the supplied text and order beside each relevant line but does not verify those signatures. A product block governs duplicate labels; it does not erase other standing terms.

The independent statement check computes eligible lines from the refreshed offer, checks goods amounts separately from the hash, and compares the supplied challenge to `Canonical.statement` and `Canonical.challenge`. Missing carriage remains nil even though the server hashes zero in that case. No signing readiness, payable total, currency or completed recovery is inferred. Digital approval has no signature challenge; no decision set is constructed here.

To deliberately recapture from a clean service checkout:

```
bun scripts/member-review/capture.ts /path/to/clean/pinned/valence
python3 scripts/member-review/sync-fixture.py
```

The Swift test resource is byte-identical to the contract pack. The UITesting-only embedded copy is also byte-identical before rebinding. That fixture replaces offer, household and presenter identifiers to fit the synthetic list session and recomputes the physical challenge for the changed offer ID. The UI fixture uses unknown digital carriage and recorded physical carriage. It is not an unchanged end-to-end response. Normal Debug and Release exclude the fixture entry and payload.

Review sections stay within the detail screen. Refresh clears earlier review data; navigation departure and account/session changes invalidate outstanding reads. Current 401 and expiry end the account session. Other failures show an unavailable message and never substitute sample data. Returning to the proposal list retains the account session but clears the review.
