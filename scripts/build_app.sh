#!/usr/bin/env bash
# Builds dist/COGL-F1.app and optionally a signed disk image.
#   scripts/build_app.sh          # release build of the app bundle
#   scripts/build_app.sh --dmg    # also create dist/COGL-F1-<version>.dmg
#
# Signing: SIGN_IDENTITY picks the certificate. By default the first "Developer ID Application"
# identity is used, else "Apple Development", else an ad-hoc signature.
# Notarization (Developer ID only): set NOTARY_PROFILE to a profile created with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/COGL-F1.app"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/engine/coglf1_engine/__init__.py")"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY="$(grep -o '"Developer ID Application: [^"]*"' <<<"$IDS" | head -1 | tr -d '"' || true)"
  [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="$(grep -o '"Apple Development: [^"]*"' <<<"$IDS" | head -1 | tr -d '"' || true)"
  [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="-"
fi

echo "==> Building Swift app (release)"
(cd "$ROOT/app" && swift build -c release --arch arm64)
BIN="$ROOT/app/.build/release/COGLF1"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" "$APP/Contents/Resources/samples"
cp "$BIN" "$APP/Contents/MacOS/COGL-F1"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$ROOT/engine/coglf1_engine" "$APP/Contents/Resources/engine/"
cp "$ROOT/engine/requirements.txt" "$APP/Contents/Resources/engine/"
cp "$ROOT"/samples/*.csv "$ROOT"/samples/*.xlsx "$APP/Contents/Resources/samples/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/"

echo "==> Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>COGL-F1</string>
  <key>CFBundleDisplayName</key><string>COGL-F1</string>
  <key>CFBundleIdentifier</key><string>com.cogl.f1</string>
  <key>CFBundleExecutable</key><string>COGL-F1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Ubaydulloh Pulat. Apache-2.0.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Ad-hoc signing (no signing certificate found)"
  codesign --force --sign - "$APP"
else
  echo "==> Signing with: $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [[ "${1:-}" == "--dmg" ]]; then
  DMG="$ROOT/dist/COGL-F1-${VERSION}.dmg"
  echo "==> Creating $DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "COGL-F1 ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  fi
  if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    echo "==> Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  shasum -a 256 "$DMG" | tee "$DMG.sha256"
fi

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
