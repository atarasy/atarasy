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

## Signed build, 2026-09-23

An `app-store-connect` export of the `AtarasyProduction` archive, signed `Apple Distribution: Vox Japan K.K. (83W4J65UE6)`, carries `application-identifier` `83W4J65UE6.com.vox.atarasy`, `aps-environment` `production` and `webcredentials:members.vox.delivery`, and `verify.py --signed-entitlements` reports both comparisons matching. Archive with `-allowProvisioningUpdates`:

```sh
xcodebuild -project ios/AtarasyPrototype.xcodeproj -scheme AtarasyProduction -configuration Production -destination 'generic/platform=iOS' -archivePath <new path>/Atarasy.xcarchive -allowProvisioningUpdates archive
```

**The first archive was unsigned and its export had lost both capabilities.** The project turns signing off for simulator runs, the Production configuration inherited that, and exporting re-signed the app with only the base entitlements. `verify.py` refused it; the Production configuration now allows signing.

## Production root, 2026-09-23

The `Production` configuration now sets the `ATARASY_RELEASE` Swift compilation condition, and App.swift's `WindowGroup` picks its content on that condition: everywhere else it opens the synthetic design-prototype inbox (fixture merchants, a "Simulate incomplete list" toggle), and under `ATARASY_RELEASE` it opens `MemberProductionRootView` (MemberAccountView.swift) instead, a `NavigationStack` around the same authenticated member account the other configurations reach through the inbox's "Member account" sheet. The prototype inbox's types (`InboxView`, `OfferView`, the app-target `merchantName` helper) and its `../contracts/ios-first/fixtures.json` resource are excluded from the Production target under the same condition and `EXCLUDED_SOURCE_FILE_NAMES`, so App Review's install never contains or can reach the demo. This was needed because Production previously launched into that inbox, with the real member flow reachable only behind a "Member account" button, which reads as a demo app.

`DemoFixtures`/`DemoOffer`/`DemoOperation` (the inbox's fixture and simulation types) live in the `AtarasyCore` Swift package alongside the package's own contract tests and are not excluded from Production at the library level; only the app-target code that instantiates and displays them is. They ship as unreachable library code, the same as any other unused symbol in a linked framework.

## Not done yet

- `members.vox.delivery` must serve [apple-app-site-association](.well-known/apple-app-site-association) at `/.well-known/apple-app-site-association` over HTTPS, status 200, `application/json`, with no redirect and no authentication. Apple's CDN fetches it, not the device, within 24 hours of install. `domainAssociationVerified` stays `false` until it does.
- App Review needs a way in for the reviewer (guideline 2.1(a)), which an invitation-only passkey app has to provide deliberately (vault `77`, decided as a single-use review invitation).
