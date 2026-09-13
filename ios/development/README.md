# Atarasy development connection

The approved development origin is **https://api-dev.vox.delivery**, with environment `development` and RP ID `api-dev.vox.delivery`. The existing Vox website remains at `https://vox.delivery`. These files configure the iOS client; they do not create DNS records or deploy a service.

## Build

Run `xcodegen generate --spec ios/project.yml`, then select the `AtarasyDevelopment` scheme. Its Development configuration uses the explicit [Info.plist](Info.plist) and [Associated Domains entitlement](AtarasyDevelopment.entitlements). Debug, Release and UITesting remain unchanged. Signing remains disabled by default; real-device signing requires an appropriate development provisioning profile and enabling code signing for that build.

Team ID: `83W4J65UE6`. Bundle ID: `dev.atarasy.prototype`. [identity.json](identity.json) records the values. The candidate AASA application identifier is `83W4J65UE6.dev.atarasy.prototype`. The App Store Connect issuer UUID is not an application identifier prefix. Before serving the AASA file, compare its identifier against `application-identifier` in the signed application's entitlements. Confirm the team and `webcredentials:api-dev.vox.delivery` in the signed entitlements and provisioning profile as well. Apple describes the association format in [Supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains).

Inspect a simulator build with:

```sh
python3 ios/development/verify.py --app /absolute/path/to/AtarasyPrototype.app
```

For a signed device build, export its entitlements with `codesign -d --entitlements :- /absolute/path/to/AtarasyPrototype.app` and pass the resulting plist to the same command with `--signed-entitlements /absolute/path/to/entitlements.plist`. This comparison does not replace signature, provisioning-profile or on-device association verification.

## Publish the development service

1. Deploy the PostgreSQL-compatible member service to Vercel with Neon PostgreSQL, the confirmed provider choice. Add the custom domain to the dedicated Vercel project and obtain its required DNS target. Create only the `api-dev` record in the `vox.delivery` zone, using the host's supplied CNAME or A/AAAA values. No target address has been selected yet. Leave apex and `www` records unchanged.
2. Configure HTTPS for `api-dev.vox.delivery`. Serve [apple-app-site-association](.well-known/apple-app-site-association) at `https://api-dev.vox.delivery/.well-known/apple-app-site-association` with status 200, `application/json`, no authentication and no redirect, after verifying the signed application identifier.
3. Use a new development database with environment `development`, origin `https://api-dev.vox.delivery` and RP ID `api-dev.vox.delivery`. Do not rewrite the scope of an existing database or reuse credentials registered for another RP. Compose only the member auth/read/statement-operation routes. Administrative provisioning and engine routes must remain inaccessible through this public member ingress.
4. Complete the combined service's outstanding integration tests and real PostgreSQL migration/concurrency tests before deployment. Configure trusted peer admission, body/time limits and HTTPS forwarding using the selected host's actual topology. The local composition does not itself start an HTTP listener.
5. Check the published AASA and unauthenticated session response, then perform registration, login and statement approval on an iPhone and iPad. Report successful native ceremonies only after these checks actually run.

## Verification status

On 2026-09-13 the local resolver could not resolve `api-dev.vox.delivery`. No DNS record, HTTPS deployment, signed provisioning or physical-device ceremony has been completed by this change. The root website was not modified. The combined service remains an independent work in progress; local client configuration must not be read as deployment readiness.
