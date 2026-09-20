# Member permission history and revocation

The configured Account screen links to Permissions. It reads the authenticated household's full grant history and shows purpose, access kind, expiry and active/expired/revoked status. Recipient and exact field identifiers are preserved in expandable details instead of being the primary heading. A requesting-party directory with verified human-readable labels is not yet implemented.

Revocation requires a confirmation alert; cancellation sends nothing. After submission the screen requires a fresh list before another action, including when the response is uncertain. No background retry or queued write occurs. On response loss, refresh issues a GET and shows the retained server record. A restart starts by reading the list; no local grant is treated as authority.

The core independently validates exact response shapes, household scope, unique grant identities, mandatory expiry, allowed aggregate form and unchanged grant terms on revocation. It refuses foreign lists, unknown fields and a revocation response changing the purpose or scope. Session changes and view departure invalidate pending presentation; cancelled tasks do not initiate a write. The server remains authoritative about access at expiry.

Tests replay public synthetic PostgreSQL responses from Valence ba17945. The UI fixture is gated by ATARASY_UI_TEST_FIXTURES and uses a local transport that discards the revocation response. It does not reach a provider, deployed service or actual private data. This is list/revoke integration, not completion of action-specific new-grant review, verified party naming, co-signer management or device acceptance.
