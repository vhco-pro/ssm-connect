#!/usr/bin/env zsh
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Runs the documented macOS flows on SSM Connect's AWS client against AWS, on a Mac where SSM
# Connect is installed, running and configured. It uses the installed app's profiles and its
# Session Manager plugin, reuses or silently refreshes the SSO session, and never starts a
# stopped workstation or opens DCV Viewer, a browser or VS Code:
#
#   - LiveClientFlowsTests: a desktop connect (sign-in, workstation, SSM, StartSession, the
#     plugin tunnel, DCV credentials and readiness) and web forwards (key push, SSH over SSM
#     with SOCKS and local forwards), each stopped again;
#   - the editor channel probe: SSH command channels through the editor proxy and a lease the
#     running app owns, with authorization refreshed across them.
#
#   scripts/live-macos-flows.sh [profile name]
#
# With SSM_LIVE_INTERACTIVE=1 the first step signs in with a device code and writes its
# verification URL to $SSM_LIVE_URL_FILE (default .build/live-flows/signin-url, user-only) for
# another device to approve, instead of opening a browser on the Mac.
#
# Transcripts go to .build/live-flows/. Nothing secret is printed.
set -euo pipefail

root="${0:A:h:h}"
cd "$root/SSMConnectKit"
logs="$root/.build/live-flows"
mkdir -p "$logs"
[[ -n "${1:-}" ]] && export SSM_LIVE_PROFILE="$1"
export SSM_LIVE_URL_FILE="${SSM_LIVE_URL_FILE:-$logs/signin-url}"
rm -f "$SSM_LIVE_URL_FILE"
export SSM_LIVE_PLUGIN="${SSM_LIVE_PLUGIN:-/Applications/SSMConnect.app/Contents/Helpers/session-manager-plugin}"

swift build --product ssm-connect-proxy > "$logs/build.log" 2>&1
result=0
SSM_LIVE_FLOWS=1 swift test --filter "LiveClientFlowsTests/signIn" > "$logs/signin.log" 2>&1 || result=1
SSM_LIVE_FLOWS=1 swift test --skip "LiveClientFlowsTests/signIn" --filter LiveClientFlowsTests > "$logs/flows.log" 2>&1 || result=1
SSM_REMOTE_TRANSPORT_PROBE=1 SSM_REMOTE_PROBE_OWNER_BUNDLE=pro.vhco.ssm-connect \
    swift test --filter realSSHCommandChannelsRefreshAuthorization > "$logs/editor.log" 2>&1 || result=1
for log in signin flows editor; do
    echo "== $log"
    sed 's/\x1b\[[0-9;]*m//g' "$logs/$log.log" | grep -E "Live |✔ Test|✘|recorded an issue|Owned concurrent|Test run with" | head -30
done
exit $result
