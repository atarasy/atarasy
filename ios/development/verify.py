#!/usr/bin/env python3
"""Compare built configuration and optional exported signing entitlements."""
import argparse
import json
import plistlib
from pathlib import Path


def verify(app, signed=None, profile=None):
    # One identity per directory: development/ beside this script, or production/.
    root = (profile or Path(__file__).resolve().parent).resolve()
    identity = json.loads((root / 'identity.json').read_text())
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    expected = {
        'AtarasyMemberEnvironment': identity['environment'],
        'AtarasyMemberOrigin': identity['origin'],
        'CFBundleIdentifier': identity['bundleID'],
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Built {key} does not match the {identity["environment"]} identity')
    entitlement = 'com.apple.developer.associated-domains'
    domains = ['webcredentials:' + identity['rpID']]
    [entitlements_file] = root.glob('*.entitlements')
    configured = plistlib.loads(entitlements_file.read_bytes())
    if configured.get(entitlement) != domains:
        raise ValueError('Configured associated domain mismatch')
    aasa = json.loads((root / '.well-known/apple-app-site-association').read_text())
    app_id = identity['candidateApplicationIdentifierPrefix'] + '.' + identity['bundleID']
    if aasa != {'webcredentials': {'apps': [app_id]}}:
        raise ValueError('AASA candidate identifier mismatch')
    if signed:
        entitlements = plistlib.loads(signed.read_bytes())
        for key, value in {
            'application-identifier': app_id,
            'com.apple.developer.team-identifier': identity['teamID'],
            entitlement: domains,
        }.items():
            if entitlements.get(key) != value:
                raise ValueError(f'Signed {key} mismatch')
    return {'builtConfigurationMatches': True,
            'exportedSigningEntitlementsMatch': bool(signed),
            'domainAssociationVerified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--signed-entitlements', type=Path)
    parser.add_argument('--profile-dir', type=Path, help='identity directory, default: the one beside this script')
    args = parser.parse_args()
    print(json.dumps(verify(args.app, args.signed_entitlements, args.profile_dir), indent=2))
