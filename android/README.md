# Android member client

This is the Kotlin and Jetpack Compose implementation boundary for Android. It currently establishes the independent canonical contract, exact Credential Manager request/response adapter, phone/tablet adaptive shell and saved navigation state.

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
