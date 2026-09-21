# Protected refresh and minimal notification

The native app registers for APNs, then sends the device token to the authenticated member host only after a session is open. Development builds explicitly select the APNs sandbox in their trusted plist. A notification contains only `aps.content-available = 1` and `{ "atarasy": { "profile": "atarasy.member-refresh-hint.1" } }`. The decoder rejects extra custom fields, including an offer, household, presenter, state or count.

The application delegate validates the payload and posts only an in-process wake. It returns `noData` without opening the session vault, fetching offers or decrypting records in the background callback. If the account is already in the foreground, the account marks its proposal rows stale, clears retained detail/review content and runs one existing bounded refresh across configured presenters. On later foreground re-entry, normal session restoration and initial proposal refresh provide the same path.

Each source records its own last verified time. A failed source remains unavailable rather than becoming an empty list; rows from that source's last verified in-memory result remain visibly stale. Successful empty responses remain distinguishable from failure. A current 401 clears the account through the existing session-invalid boundary.

The host and APNs can observe device registration and generic-wake timing. The payload does not reveal what changed, and no presenter receives a row-open, notification-open or refresh engagement event. No background plaintext processing, automatic mutation, notification service extension or analytics SDK is used.

Simulator/core tests cover the closed payload, registration request, stale cache and partial/denied behavior. Actual APNs credentials, provider delivery, OS throttling and physical-device background acceptance remain deployment gates.
