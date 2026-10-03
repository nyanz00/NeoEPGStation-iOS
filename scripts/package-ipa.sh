#!/usr/bin/env bash
set -euo pipefail
app='build/device/Build/Products/Release-iphoneos/NeoEPGStation.app'
test -f "$app/main.jsbundle"
test -d "$app/Frameworks/VLCKit.framework"
test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")" = '18.0'
mkdir -p dist/Payload
ditto "$app" dist/Payload/NeoEPGStation.app
# Ad-hoc signing is for LiveContainer import, not App Store distribution.
codesign --force --deep --sign - dist/Payload/NeoEPGStation.app
codesign --verify --deep --strict dist/Payload/NeoEPGStation.app
ditto -c -k --keepParent dist/Payload dist/NeoEPGStation.ipa
shasum -a 256 dist/NeoEPGStation.ipa > dist/NeoEPGStation.ipa.sha256
python3 - <<'PY'
import json, os, plistlib
from pathlib import Path
info = plistlib.loads(Path('dist/Payload/NeoEPGStation.app/Info.plist').read_bytes())
Path('dist/build-info.json').write_text(json.dumps({
    'commit': os.environ.get('GITHUB_SHA'), 'run': os.environ.get('GITHUB_RUN_ID'),
    'minimumOS': info['MinimumOSVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'reactNative': '0.87.1', 'vlckit': '4.0.0a25 / 20260929-1631',
    'signing': 'ad-hoc for LiveContainer'
}, indent=2) + '\n')
PY
