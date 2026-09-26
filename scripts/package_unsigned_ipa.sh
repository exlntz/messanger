#!/usr/bin/env bash
set -euo pipefail

app_path="DerivedData/Build/Products/Release-iphoneos/VOICE.app"
executable="${app_path}/VOICE"
if [[ ! -f "${executable}" ]]; then
    echo "Expected iPhoneOS executable not found: ${executable}" >&2
    exit 1
fi

file "${executable}" | tee executable-file.txt
lipo -info "${executable}" | tee executable-arch.txt
if ! lipo -archs "${executable}" | tr ' ' '\n' | grep -qx 'arm64'; then
    echo "The unsigned iPhoneOS app must contain an arm64 executable." >&2
    exit 1
fi

python3 - "${app_path}" <<'PY'
import pathlib
import plistlib
import sys
app = pathlib.Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert info.get('CFBundleIdentifier') == 'com.exlntz.voice', 'Invalid bundle identifier'
assert info.get('CFBundleExecutable') == 'VOICE', 'Invalid executable metadata'
assert info.get('CFBundleShortVersionString') == '0.1.0', 'Missing app version'
assert info.get('NSMicrophoneUsageDescription'), 'Missing microphone privacy description'
assert 'audio' in info.get('UIBackgroundModes', []), 'Missing audio background mode'
assert info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Not an iPhoneOS device build'
assert (app / 'Assets.car').is_file(), 'Asset catalog was not compiled'
assert info.get('CFBundleIcons'), 'Missing app icon metadata'
print('Validated bundle metadata, microphone permission, icons, and device platform.')
PY

rm -rf ipa VOICE-unsigned.ipa
mkdir -p ipa/Payload
ditto "${app_path}" ipa/Payload/VOICE.app
(
    cd ipa
    ditto -c -k --sequesterRsrc --keepParent Payload ../VOICE-unsigned.ipa
)
unzip -t VOICE-unsigned.ipa >ipa-contents.txt
shasum -a 256 VOICE-unsigned.ipa | tee VOICE-unsigned.ipa.sha256
