#!/usr/bin/env python3
"""Writes App/NotHelix/Localizable.xcstrings from scripts/translations_gl.py.

To find new untranslated strings after changing the UI:
  xcodebuild -exportLocalizations -project NotHelix.xcodeproj -localizationPath /tmp/loc -exportLanguage gl
  python3 scripts/build_strings.py --check "/tmp/loc/gl.xcloc/Localized Contents/gl.xliff"
"""
import html, json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from translations_gl import GL

if len(sys.argv) > 2 and sys.argv[1] == "--check":
    x = open(sys.argv[2], encoding="utf-8").read()
    keys = {html.unescape(s) for s in re.findall(r"<source>(.*?)</source>", x, re.S)}
    missing = sorted(k for k in keys if k not in GL)
    print("\n".join(missing) if missing else "All strings translated.")
    sys.exit(1 if missing else 0)

strings = {}
for key in sorted(GL):
    if key.startswith("CFBundle"):
        continue
    strings[key] = {
        "extractionState": "manual",
        "localizations": {"gl": {"stringUnit": {"state": "translated", "value": GL[key]}}},
    }
out = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
path = os.path.join(here, "..", "App", "NotHelix", "Localizable.xcstrings")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2, sort_keys=True)
print(f"Wrote {len(strings)} strings to {os.path.normpath(path)}")
