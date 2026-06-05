#!/usr/bin/env bash
# Task A5, ADR-7, ADR-P3 — Download, verify, and extract the official AWS session-manager-plugin.
#
# This script is invoked by the Xcode pre-build phase (Task A6). It:
#   1. Checks if the plugin binary is already cached with the correct checksum → skips download.
#   2. Downloads the official macOS arm64 .pkg from AWS's S3 distribution endpoint.
#   3. Verifies the .pkg SHA-256 checksum (NEVER skipped — ADR-7 supply-chain integrity).
#   4. Extracts the binary using pkgutil --expand + cpio (does NOT run the .pkg installer).
#   5. Verifies the extracted binary SHA-256.
#   6. Caches the binary + LICENSE to .build/plugin/.
#
# URL source: Homebrew cask definition for session-manager-plugin (authoritative AWS distribution).
# Checksums: computed from the official AWS package downloaded 2026-06-05 and cross-verified
#            against the Homebrew-installed binary (identical SHA-256).

set -euo pipefail

PLUGIN_VERSION="1.2.814.0"
PLUGIN_URL="https://session-manager-downloads.s3.amazonaws.com/plugin/${PLUGIN_VERSION}/mac_arm64/session-manager-plugin.pkg"

# SHA-256 of the .pkg file (outer package)
EXPECTED_PKG_SHA256="7fa5a121af05c4429c5ed2853eb8c5eb8a94ba11cb42a7194728614e4db4726b"
# SHA-256 of the extracted session-manager-plugin binary
EXPECTED_BIN_SHA256="fcef1e8ab4be3a9b23579bdb1bf018edeaf0e361259e5473f8c3012a9439de1f"

CACHE_DIR="${SRCROOT:-.}/.build/plugin"
PLUGIN_BINARY="${CACHE_DIR}/session-manager-plugin"
PLUGIN_LICENSE="${CACHE_DIR}/LICENSE"

# ── Fast path: skip if cached binary matches expected checksum ──────────────
if [[ -f "${PLUGIN_BINARY}" && -f "${PLUGIN_LICENSE}" ]]; then
    ACTUAL_SHA256=$(shasum -a 256 "${PLUGIN_BINARY}" | cut -d' ' -f1)
    if [[ "${ACTUAL_SHA256}" == "${EXPECTED_BIN_SHA256}" ]]; then
        echo "✓ session-manager-plugin ${PLUGIN_VERSION} already cached and verified."
        exit 0
    fi
    echo "⚠ Cached binary checksum mismatch — re-downloading."
fi

echo "Downloading session-manager-plugin ${PLUGIN_VERSION}…"

# ── Download to temp dir ────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

PKG_PATH="${WORK_DIR}/session-manager-plugin.pkg"
curl -fsSL -o "${PKG_PATH}" "${PLUGIN_URL}"

# ── Verify .pkg checksum ───────────────────────────────────────────────────
ACTUAL_PKG_SHA256=$(shasum -a 256 "${PKG_PATH}" | cut -d' ' -f1)
if [[ "${ACTUAL_PKG_SHA256}" != "${EXPECTED_PKG_SHA256}" ]]; then
    echo "ERROR: Package checksum verification FAILED." >&2
    echo "  Expected: ${EXPECTED_PKG_SHA256}" >&2
    echo "  Actual:   ${ACTUAL_PKG_SHA256}" >&2
    echo "" >&2
    echo "  The AWS package may have been updated. Verify the new checksum from an" >&2
    echo "  authoritative source, then update EXPECTED_PKG_SHA256 and EXPECTED_BIN_SHA256" >&2
    echo "  in this script (scripts/fetch-plugin.sh)." >&2
    exit 1
fi
echo "✓ Package checksum verified."

# ── Extract without running the installer (pkgutil --expand + cpio) ─────────
EXPANDED_DIR="${WORK_DIR}/expanded"
pkgutil --expand "${PKG_PATH}" "${EXPANDED_DIR}"

PAYLOAD_DIR="${WORK_DIR}/payload"
mkdir -p "${PAYLOAD_DIR}"
(cd "${PAYLOAD_DIR}" && cpio -idmu < "${EXPANDED_DIR}/Payload" 2>/dev/null)

# ── Locate binary and license within the extracted payload ──────────────────
EXTRACTED_BINARY="${PAYLOAD_DIR}/usr/local/sessionmanagerplugin/bin/session-manager-plugin"
EXTRACTED_LICENSE="${PAYLOAD_DIR}/usr/local/sessionmanagerplugin/LICENSE"

if [[ ! -f "${EXTRACTED_BINARY}" ]]; then
    echo "ERROR: session-manager-plugin binary not found in extracted package at:" >&2
    echo "  ${EXTRACTED_BINARY}" >&2
    echo "  The .pkg structure may have changed. Inspect manually with:" >&2
    echo "    pkgutil --expand <pkg> expanded && find expanded -type f" >&2
    exit 1
fi

if [[ ! -f "${EXTRACTED_LICENSE}" ]]; then
    echo "ERROR: LICENSE file not found in extracted package." >&2
    exit 1
fi

# ── Verify extracted binary checksum ────────────────────────────────────────
ACTUAL_BIN_SHA256=$(shasum -a 256 "${EXTRACTED_BINARY}" | cut -d' ' -f1)
if [[ "${ACTUAL_BIN_SHA256}" != "${EXPECTED_BIN_SHA256}" ]]; then
    echo "ERROR: Binary checksum verification FAILED." >&2
    echo "  Expected: ${EXPECTED_BIN_SHA256}" >&2
    echo "  Actual:   ${ACTUAL_BIN_SHA256}" >&2
    exit 1
fi
echo "✓ Binary checksum verified."

# ── Cache the verified artifacts ────────────────────────────────────────────
mkdir -p "${CACHE_DIR}"
cp "${EXTRACTED_BINARY}" "${PLUGIN_BINARY}"
chmod +x "${PLUGIN_BINARY}"
cp "${EXTRACTED_LICENSE}" "${PLUGIN_LICENSE}"

echo "✓ session-manager-plugin ${PLUGIN_VERSION} downloaded, verified, and cached at ${CACHE_DIR}."
