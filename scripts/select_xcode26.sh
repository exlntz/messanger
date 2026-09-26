#!/usr/bin/env bash
set -euo pipefail

# GitHub documents macos-26 as generally available for hosted runners.
# The workflow still verifies the installed toolchain instead of relying on the default symlink.
mapfile -t candidates < <(find /Applications -maxdepth 1 \( -type d -o -type l \) -name 'Xcode_26*.app' | sort)

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No Xcode 26 installation found under /Applications/Xcode_26*.app" >&2
  find /Applications -maxdepth 1 \( -type d -o -type l \) -name 'Xcode*.app' | sort >&2 || true
  exit 1
fi

xcode_app="${candidates[-1]}"
echo "Using ${xcode_app}"
sudo xcode-select -s "${xcode_app}/Contents/Developer"

{
  echo "Selected Xcode: ${xcode_app}"
  xcodebuild -version
  swift --version
} | tee xcode-version.txt
