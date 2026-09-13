# Authenticated offer detail

The configured member list opens a separate native detail view. It fetches the actual offer projection through the same scoped member client. It does not reuse the sample offer model, totals, journal or signing controls.

## Display and validation

Digital details show choice status and proposal expiry. Physical details show reported candidate outcomes and collection due date. Candidate rows preserve product reference, quantity, merchant, maker, carrier, catalogue unit price and gift attribution. Standing and product-specific merchant disclosures remain plain text in their original order. No native signature-verification or provider-paid badge is inferred from the response.

The service supplies no currency or human product title. Catalogue unit prices are therefore labelled in the merchant's units and never summed into an amount payable. The physical detail does not invent an actual collection time, grace period, carriage charge or settlement statement. Gift attribution remains visible alongside catalogue information.

The decoder pins required keys, including explicit nulls, and rejects unsafe numbers, duplicate candidate IDs, unknown states, unrelated disclosure blocks and a different resource/household/presenter. The detail coordinator additionally binds the result to the selected binding and current session. A source failure gives a named unavailable state; no sample or earlier detail is substituted.

## Navigation and session lifetime

Account teardown belongs to the account sheet's disappearance, not to the form disappearing when a detail is pushed. The sheet owns the account while its navigation stack changes. Detail data is cleared when leaving the detail, refreshing, changing selection or changing session. Generation checks reject late responses; a current 401 clears the authenticated account, while a stale 401 cannot clear a replacement session. A visible-detail timer checks session expiry even while the account form is off-screen.

The current UI tests use the existing labelled UITesting list fixture, including captured digital and physically collected detail payloads. They exercise navigation into detail, returning to the list, reopening, gift display and reported consumption. They do not authenticate a real member or measure the configured account's native passkey lifecycle. That still needs actual team/domain configuration and device acceptance.

## Evidence and next steps

[The detail contract](../contracts/member-detail/README.md) records the response capture and fixture regeneration procedure. [Detail validation](evidence/member-detail-validation.json) records source/log hashes, simulator results, normal Release checks and negative control evidence. Earlier validation files retain their original source revisions.

Next, pin the authenticated physical statement and digital approval projections, then connect their separate read-only review views. Preserve carriage absence, gift attribution and disclosure/alternative context before considering any signature control. Transaction submission needs its own canonical challenge, uncertain-result handling and authoritative read-back tests; a readable detail screen does not satisfy that gate. Actual device/service configuration and private-node recovery remain open.
