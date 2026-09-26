#!/usr/bin/env bash
set -euo pipefail

products_dir="DerivedData/Build/Products/Release-iphoneos"
app_path="${products_dir}/VOICE.app"

if [[ ! -d "${app_path}" ]]; then
  echo "Expected app bundle not found: ${app_path}" >&2
  find DerivedData/Build/Products -maxdepth 3 -print >&2 || true
  exit 1
fi

executable="${app_path}/VOICE"
if [[ ! -f "${executable}" ]]; then
  echo "Expected app executable not found: ${executable}" >&2
  exit 1
fi

file "${executable}" | tee executable-file.txt
lipo -info "${executable}" | tee executable-arch.txt
if ! lipo -archs "${executable}" | tr ' ' '\n' | grep -qx 'arm64'; then
  echo "The unsigned iPhoneOS app must contain an arm64 executable." >&2
  exit 1
fi

rm -rf ipa Payload VOICE-unsigned.ipa
mkdir -p ipa/Payload
ditto "${app_path}" ipa/Payload/VOICE.app
(
  cd ipa
  ditto -c -k --sequesterRsrc --keepParent Payload ../VOICE-unsigned.ipa
)

unzip -l VOICE-unsigned.ipa | tee ipa-contents.txt
