#!/usr/bin/env bash
# Builds the T4 feasibility helper on Linux from the app's current portable sources.
# Usage: spikes/helper-feasibility/run.sh   (run from anywhere; needs a Swift 6.4 toolchain)
# The binary is statically linked against the Swift runtime, so it runs on the host even
# when built in the official Swift container.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
reused="$here/Sources/HelperSpike/Reused"
rm -rf "$reused" && mkdir -p "$reused"
for file in SSMSessionResponse.swift AWSRegion.swift IdentityMapper.swift; do
    cp "$root/SSMConnectKit/Sources/SSMConnectDomain/$file" "$reused/"
done
cd "$here"
swift build -c release --static-swift-stdlib "$@"
echo "built: $(swift build -c release --static-swift-stdlib --show-bin-path)/HelperSpike"
