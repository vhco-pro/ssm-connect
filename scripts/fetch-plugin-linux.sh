#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Downloads, verifies and extracts the official AWS Session Manager plugin for Linux x86-64, the
# counterpart of fetch-plugin.sh (macOS) and fetch-plugin.ps1 (Windows), under the same rule: the
# download and the extracted binary are checked against pinned SHA-256s, and a mismatch is fatal.
# The Ubuntu package's binary is a static Go executable, bundled in both the .rpm and the .deb.
#
#   scripts/fetch-plugin-linux.sh [destination]    # prints the destination on its last line
#
# The destination (default .build/plugin/linux) holds bin/session-manager-plugin and the LICENSE,
# NOTICE and THIRD-PARTY files the Apache License 2.0 requires to travel with it. Needs curl, ar
# and tar.
set -euo pipefail

PLUGIN_VERSION="1.2.835.0"
PLUGIN_URL="https://session-manager-downloads.s3.amazonaws.com/plugin/${PLUGIN_VERSION}/ubuntu_64bit/session-manager-plugin.deb"
EXPECTED_DEB_SHA256="7c6dcad12518571cc7959a713e6a8ae1bdf6ed66fd9bee37dc189e39ca58ae03"
EXPECTED_BIN_SHA256="f6002be08e5c57dc97eb9a0ef819d54f4c9a4a724c5818cec7d4baeaadfe4cbd"

root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$root/.build/plugin/linux}"
binary="$destination/bin/session-manager-plugin"

if [[ -f "$binary" ]] && [[ "$(sha256sum "$binary" | cut -d' ' -f1)" == "$EXPECTED_BIN_SHA256" ]]; then
    echo "session-manager-plugin ${PLUGIN_VERSION} already cached and verified." >&2
    echo "$destination"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/plugin.deb" "$PLUGIN_URL"
actual="$(sha256sum "$work/plugin.deb" | cut -d' ' -f1)"
[[ "$actual" == "$EXPECTED_DEB_SHA256" ]] || { echo "Package verification failed: expected $EXPECTED_DEB_SHA256, got $actual" >&2; exit 1; }
(cd "$work" && ar x plugin.deb && mkdir data && tar -xf data.tar.* -C data)
source="$work/data/usr/local/sessionmanagerplugin"
actual="$(sha256sum "$source/bin/session-manager-plugin" | cut -d' ' -f1)"
[[ "$actual" == "$EXPECTED_BIN_SHA256" ]] || { echo "Binary verification failed: expected $EXPECTED_BIN_SHA256, got $actual" >&2; exit 1; }
for notice in LICENSE NOTICE THIRD-PARTY; do
    [[ -f "$source/$notice" ]] || { echo "The package is missing $notice, which redistribution requires." >&2; exit 1; }
done
mkdir -p "$destination/bin"
install -m 0755 "$source/bin/session-manager-plugin" "$binary"
install -m 0644 "$source/LICENSE" "$source/NOTICE" "$source/THIRD-PARTY" "$destination/"
echo "Verified session-manager-plugin ${PLUGIN_VERSION} into $destination" >&2
echo "$destination"
