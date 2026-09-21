# Android member client

This is the Kotlin and Jetpack Compose implementation boundary for Android. It currently establishes the independent canonical contract, exact Credential Manager request/response adapter, closed authenticated HTTP/session boundary, Android Keystore protected session storage, phone/tablet adaptive shell and saved navigation state.

The HTTP boundary uses only the configured HTTPS origin, refuses redirects, does not install a cookie handler, bounds request and response bytes, requires `Cache-Control: no-store`, and checks the exact session response schema. Bearer state is cleared from memory when the activity stops. The on-disk session is AES-256-GCM encrypted with authenticated environment and household scope using a non-exportable, unlocked-device-only Android Keystore key. App backup and device transfer are disabled. A missing/replaced key, scope swap, truncation or changed ciphertext fails closed.

The development build deliberately has no Android passkey release identity. A usable ceremony requires all of the following to agree:

- a reviewed release signing certificate;
- its `android:apk-key-hash:<base64url SHA-256 certificate digest>` in Valence `androidAppOrigins`;
- `delegate_permission/common.get_login_creds` Digital Asset Links statements for `dev.atarasy.prototype` and the release certificate on every relying-party host;
- a release-signed physical phone and tablet acceptance run.

Build and test with a JDK 17 or newer supported by the pinned Gradle toolchain:

```sh
./gradlew testDebugUnitTest assembleDebug
```

The app must pass the server's public-key credential option JSON directly to Credential Manager. It must submit the returned registration or authentication response JSON without converting base64url values, changing omitted fields, or creating a WebAuthn challenge locally.
