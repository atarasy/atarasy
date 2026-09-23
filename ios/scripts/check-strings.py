#!/usr/bin/env python3
"""Check that every member-facing string the compiler extracted has an English and a Japanese entry.

Vault `80` D-5 made Japanese the member's first language. A literal added to a screen and not to
`Resources/ja.lproj/Localizable.strings` shows in English on a Japanese phone and nothing else
notices, so this compares the compiler's own list (`SWIFT_EMIT_LOC_STRINGS`, the `.stringsdata`
files a build leaves in derived data) with both tables.

    python3 ios/scripts/check-strings.py <derived-data-dir>

The synthetic prototype (App.swift) and the UI-test fixtures are not member-facing and are skipped.
Exit status 1 names every missing or stale key.
"""
import glob, json, os, re, sys

def table(path):
    text = open(path, encoding="utf-8").read()
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M))

def keys(derived, product):
    found = {}
    for f in glob.glob(os.path.join(derived, "Build/Intermediates.noindex", product + ".build", "*", "*", "Objects-normal", "*", "*.stringsdata")) + \
             glob.glob(os.path.join(derived, "Build/Intermediates.noindex", product + ".build", "*", "Objects-normal", "*", "*.stringsdata")):
        data = json.load(open(f))
        source = os.path.basename(data.get("source", ""))
        for rows in data.get("tables", {}).values():
            for row in rows:
                found.setdefault(row["key"].replace("\\", "\\\\").replace('"', '\\"'), set()).add(source)
    return {k for k, v in found.items() if not all(s == "App.swift" or "Fixture" in s or "Showcase" in s for s in v)}

def main():
    derived = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    failed = False
    for product, resources in [("AtarasyPrototype", "../AtarasyPrototype/Resources"), ("AtarasyCore", "../AtarasyCore/Sources/AtarasyCore/Resources")]:
        wanted = keys(derived, product)
        if not wanted:
            print(f"{product}: no .stringsdata found under {derived}; build first"); failed = True; continue
        for lang in ("en", "ja"):
            have = table(os.path.join(here, resources, lang + ".lproj", "Localizable.strings"))
            missing, stale = sorted(wanted - set(have)), sorted(set(have) - wanted) if product == "AtarasyPrototype" else []
            for k in missing: print(f"{product} {lang}: missing {k}")
            for k in stale: print(f"{product} {lang}: not used {k}")
            if lang == "ja":
                for k in sorted(wanted & set(have)):
                    if have[k] == k and k not in ("Atarasy",) and re.search(r"[A-Za-z]{3}", k): print(f"{product} ja: untranslated {k}"); failed = True
            failed |= bool(missing or stale)
        print(f"{product}: {len(wanted)} keys checked")
    sys.exit(1 if failed else 0)

main()
