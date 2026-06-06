#!/usr/bin/env zsh
# release.sh — build a signed Release SSM Connect.app and package it for the Homebrew cask (I4).
#
#   ./scripts/release.sh            # clean Release build -> dist/SSMConnect-<version>.zip + .sha256
#
# Output: dist/SSMConnect-<version>.zip (the .app, code-signed & re-sealed by the build's
# Embed & re-sign phase) and its SHA-256. Upload the zip as the GitHub release asset; put the
# version + sha256 into the cask (Casks/ssm-connect.rb).
#
# The build is ad-hoc signed and NOT notarized (NF-06): the cask documents the one-time Gatekeeper
# approval. See README for the notarization upgrade path.

set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

PROJECT="SSMConnect.xcodeproj"
SCHEME="SSMConnect"
DERIVED=".build/DerivedData"
APP_NAME="SSMConnect.app"
RELEASE_APP="$DERIVED/Build/Products/Release/$APP_NAME"
DIST="dist"

VERSION=$(plutil -extract CFBundleShortVersionString raw -o - SSMConnect/Info.plist)
ZIP="$DIST/SSMConnect-${VERSION}.zip"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Clean Release build (signed + re-sealed by the Embed & re-sign phase)"
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -quiet

echo "==> Verifying signature"
codesign --verify --deep --strict "$RELEASE_APP"

echo "==> Packaging $ZIP (ditto preserves the bundle + code signature)"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"

echo ""
echo "==> Done."
echo "    version: $VERSION"
echo "    zip:     $ZIP"
echo "    sha256:  $SHA"
