#!/usr/bin/env bash
# Builds JobHunter.app from the Swift package (release, ad-hoc signed).
#
#   scripts/build-app.sh                 # -> build/JobHunter.app
#   scripts/build-app.sh --install       # additionally copies it to ~/Applications
#   VERSION=1.1 scripts/build-app.sh
#
# Uses $DEVELOPER_DIR if set, otherwise Xcode at /Volumes/Daten/Applications/Xcode.app
# (falls back to the active xcode-select toolchain).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Volumes/Daten/Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Volumes/Daten/Applications/Xcode.app/Contents/Developer
fi

VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$ROOT/build/JobHunter.app"

echo "==> swift build (release)"
swift build -c release --product JobHunter
BIN="$(swift build -c release --product JobHunter --show-bin-path)/JobHunter"

if [[ ! -f Support/AppIcon.icns ]]; then
  echo "==> rendering app icon"
  swift scripts/make_icon.swift Support/AppIcon.icns
fi

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JobHunter"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign (ad-hoc)"
# Hardened runtime needs the apple-events entitlement to drive Apple Mail.
codesign --force --sign - --options runtime --timestamp=none --entitlements Support/JobHunter.entitlements "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/JobHunter.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "==> installed to ~/Applications/JobHunter.app"
fi

echo "done: $APP"
