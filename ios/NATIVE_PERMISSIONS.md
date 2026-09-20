# Member permission history and revocation

The configured Account screen links to Permissions. It reads the authenticated household's full grant history and shows purpose, access kind, expiry and active/expired/revoked status. Recipient and exact field identifiers are preserved in expandable details instead of being the primary heading. A requesting-party directory with verified human-readable labels is not yet implemented.

Revocation requires a confirmation alert; cancellation sends nothing. After submission the screen requires a fresh list before another action, including when the response is uncertain. No background retry or queued write occurs. On response loss, refresh issues a GET and shows the retained server record. A restart starts by reading the list; no local grant is treated as authority.

The core independently validates exact response shapes, household scope, unique grant identities, mandatory expiry, allowed aggregate form and unchanged grant terms on revocation. It refuses foreign lists, unknown fields and a revocation response changing the purpose or scope. Session changes and view departure invalidate pending presentation; cancelled tasks do not initiate a write. The server remains authoritative about access at expiry.

Tests replay public synthetic PostgreSQL responses from Valence ba17945. The UI fixture is gated by ATARASY_UI_TEST_FIXTURES and uses a local transport that discards the revocation response. It does not reach a provider, deployed service or actual private data. This is list/revoke integration, not completion of action-specific new-grant review, verified party naming, co-signer management or device acceptance.

## Action-specific access requests

Account > Access requests lists requests already issued by the service. Opening an action fetches its frozen review, showing requester name, purpose, supported field label, review expiry and access expiry. Allow this access and Cancel request submit only the displayed digest. Leaving the screen submits nothing. A response loss disables both decisions until explicit GET readback; a recorded decision cannot be submitted again from this view. Session changes discard the review. The one currently supported field is duplicate_check; the view cannot create an arbitrary or blanket grant.

The native implementation independently reproduces the service's JSON.stringify property order and SHA-256 digest, checks exact nested shapes, scope, identifiers, safe times and state/outcome consistency, and compares the granted permission with the displayed terms. The digest is a terms-binding check, not a passkey signature or proof that a human read them. The service enforces actual access expiry.

Core and Simulator fixtures replay synthetic responses captured from Valence d7c63f7. The request fixture uses a fixed clock and simulates response loss after granting; restarting resets only the local test fixture. No provider or deployed service is called. Native navigation from an actual requesting action and the trusted request producer/directory remain to be connected. Display names are supplied by the trusted issuer and do not establish external identity verification. This implementation does not finish IOS-B18 or real-device acceptance by itself.
