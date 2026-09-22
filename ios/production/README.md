# Atarasy release identity

The release configuration, decided on 2026-09-22 (vault `Projects/Atarasy/77_iOS_Release_Identity_2026-09-22.md`):

| Value | Setting |
|---|---|
| Member origin and RP ID | `https://members.vox.delivery` |
| Team | `83W4J65UE6` |
| Bundle ID | `com.vox.atarasy` |
| Display name | Atarasy |
| Devices | iPhone only (`TARGETED_DEVICE_FAMILY` 1) |
| APNs | `production` |

**The RP ID is the one value that cannot be changed later.** A passkey is bound to it, and a pilot household's identifier is its passkey's key (K1, vault `74`), so moving to another domain re-registers every member and re-creates every household.

## Build

Run `xcodegen generate --spec ios/project.yml` and select the `AtarasyProduction` scheme; archiving uses the `Production` configuration. Check a build with:

```sh
python3 ios/development/verify.py --profile-dir ios/production --app /absolute/path/to/AtarasyPrototype.app
python3 ios/development/verify.py --profile-dir ios/production --app /absolute/path/to/AtarasyPrototype.app --signed-entitlements /absolute/path/to/entitlements.plist
```

The second form compares a signed build's exported entitlements (`codesign -d --entitlements :- <app>`) with this directory.

## Not done yet

- The App ID `com.vox.atarasy` is not registered. It needs the Associated Domains and Push Notifications capabilities, and an App Store Connect record.
- `members.vox.delivery` does not exist. The production member service must serve [apple-app-site-association](.well-known/apple-app-site-association) at `/.well-known/apple-app-site-association` over HTTPS, status 200, `application/json`, with no redirect and no authentication. Apple's CDN fetches it, not the device, within 24 hours of install.
- `signedApplicationIdentifierVerified` in [identity.json](identity.json) stays `false` until a signed build's entitlements have been compared.
- **App Review guideline 5.1.1(v) requires in-app account deletion for an app that supports account creation**, and the hub has none. Its design is open (vault `77`).
- App Review needs a way in for the reviewer (guideline 2.1(a)), which an invitation-only passkey app has to provide deliberately.
