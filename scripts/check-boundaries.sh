#!/usr/bin/env bash
# Checks the shared core's platform boundary (cross-platform-client spec, AC-11).
#
# SSMConnectDomain and SSMConnectWorkflow hold the rules every desktop client shares, so
# their sources must not import a macOS framework (AppKit, SwiftUI, Darwin,
# ServiceManagement, UserNotifications) or an AWS SDK module (aws-sdk-swift, smithy-swift
# or aws-crt-swift). Platform code reaches them through ports implemented in the platform
# targets. A missing target is a failure too: the check proves nothing about a target that
# does not exist.
#
# Usage: scripts/check-boundaries.sh   (run from anywhere; exits 1 on any violation)

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
targets=(SSMConnectDomain SSMConnectWorkflow)
platform='AppKit|SwiftUI|Darwin|ServiceManagement|UserNotifications'
sdk='AWS[A-Za-z0-9_]*|ClientRuntime|Smithy[A-Za-z0-9_]*|AwsCommonRuntimeKit'
# An import line in any form: attributes, `import struct M.T`, submodules.
pattern="^[[:space:]]*(@[A-Za-z_]+([(][^)]*[)])?[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func|actor)[[:space:]]+)?(${platform}|${sdk})([.[:space:]]|$)"

status=0
for target in "${targets[@]}"; do
    dir="$root/SSMConnectKit/Sources/$target"
    if [[ ! -d "$dir" ]]; then
        echo "boundary: target $target does not exist ($dir)"
        status=1
        continue
    fi
    if matches=$(grep -rnE --include='*.swift' "$pattern" "$dir"); then
        echo "boundary: $target imports a platform or AWS SDK module:"
        echo "$matches" | sed "s|$root/||"
        status=1
    else
        echo "boundary: $target ok"
    fi
done
exit $status
