#!/usr/bin/env zsh
# run.sh — regenerate the Xcode project, build, and launch SSM Connect.
#
# Usage:
#   ./scripts/run.sh           # incremental build, then launch
#   ./scripts/run.sh --clean   # wipe build products first (full rebuild)
#   ./scripts/run.sh --test    # run the unit tests instead of launching
#
# The app is menu-bar only (LSUIElement) — look for the monitor icon in the
# top-right menu bar after it launches; there is no Dock icon.

set -euo pipefail

# Resolve repo root (this script lives in <root>/scripts/).
ROOT="${0:A:h:h}"
cd "$ROOT"

PROJECT="SSMConnect.xcodeproj"
SCHEME="SSMConnect"
DERIVED=".build/DerivedData"
APP="$DERIVED/Build/Products/Debug/SSMConnect.app"
DESTINATION='platform=macOS,arch=arm64'

mode="run"
clean=0
for arg in "$@"; do
  case "$arg" in
    --clean) clean=1 ;;
    --test)  mode="test" ;;
    --run)   mode="run" ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Quit any running instance so the rebuilt binary launches cleanly.
pkill -f "SSMConnect.app/Contents/MacOS/SSMConnect" 2>/dev/null || true

if (( clean )); then
  echo "==> Cleaning build products"
  rm -rf "$DERIVED/Build/Products" "$DERIVED/Build/Intermediates.noindex"
fi

echo "==> Generating Xcode project from project.yml"
xcodegen generate

if [[ "$mode" == "test" ]]; then
  # Unit tests live in the SSMConnectKit package and run via SwiftPM (like `go test`).
  echo "==> Running tests (swift test in SSMConnectKit)"
  exec swift test --package-path SSMConnectKit
fi

echo "==> Building (first build compiles the AWS SDK — be patient)"
# -skipPackagePluginValidation is required: aws-sdk-swift (smithy-swift) ships a
# SwiftPM build-tool plugin that headless xcodebuild otherwise refuses to run.
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -quiet

echo "==> Launching $APP"
open "$APP"
echo "==> Launched. Look for the monitor icon in the menu bar (top-right)."
