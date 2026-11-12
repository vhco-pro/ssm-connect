#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="${1:?Usage: bash spikes/swift-portability/run.sh OUTPUT_DIRECTORY}"
mkdir -p -- "$OUTPUT"
OUTPUT="$(cd -- "$OUTPUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -r -- "$WORK"' EXIT

swift --version | tee "$OUTPUT/swift-version.txt"
CORE=failed
SDK=failed
EXE=""
if [[ "${OSTYPE}" == msys* || "${OSTYPE}" == cygwin* ]]; then
    EXE=".exe"
fi

if swiftc \
    "$ROOT/SSMConnectKit/Sources/SSMConnectKit/Models/AWSRegion.swift" \
    "$ROOT/SSMConnectKit/Sources/SSMConnectKit/Services/AWSConfigParser.swift" \
    "$ROOT/spikes/swift-portability/main.swift" \
    -o "$WORK/core-probe$EXE" >"$OUTPUT/core-build.log" 2>&1; then
    if "$WORK/core-probe$EXE" \
        <"$ROOT/spikes/swift-portability/requests.jsonl" \
        >"$OUTPUT/core-responses.jsonl" 2>"$OUTPUT/core-runtime.log" &&
        jq -e -s '
            length == 8 and
            all(.[]; .version == 1) and
            .[0].event == "ready" and
            .[1].event == "region" and .[1].valid == true and
            .[2].event == "region" and .[2].valid == false and
            .[3].event == "profile" and .[3].resourceRegion == "eu-west-1" and
            .[4].error == "unknown command" and
            .[5].error == "unsupported protocol version" and
            .[6].error == "invalid request" and
            .[7].event == "stopped"
        ' "$OUTPUT/core-responses.jsonl"; then
        CORE=passed
    else
        cat "$OUTPUT/core-runtime.log" "$OUTPUT/core-responses.jsonl"
    fi
else
    cat "$OUTPUT/core-build.log"
fi

cp -R "$ROOT/spikes/swift-portability/SDKProbe" "$WORK/sdk"
cp "$ROOT/SSMConnectKit/Package.resolved" "$WORK/sdk/Package.resolved"
if swift build --package-path "$WORK/sdk" --force-resolved-versions --jobs 2 \
    >"$OUTPUT/sdk-build.log" 2>&1; then
    if swift run --package-path "$WORK/sdk" --skip-build SDKProbe \
        >"$OUTPUT/sdk-runtime.log" 2>&1 &&
        grep -Fxq 'SDK modules linked: 6; YAML schemaVersion: 2' "$OUTPUT/sdk-runtime.log"; then
        SDK=passed
    else
        cat "$OUTPUT/sdk-runtime.log"
    fi
else
    cat "$OUTPUT/sdk-build.log"
fi

jq -n \
    --arg platform "$(uname -s)" \
    --arg commit "$(git -C "$ROOT" rev-parse HEAD)" \
    --arg core "$CORE" \
    --arg sdk "$SDK" \
    '{platform: $platform, commit: $commit, portableCoreAndHelper: $core, lockedSDKAndYAML: $sdk}' \
    | tee "$OUTPUT/result.json"

[[ "$CORE" == passed && "$SDK" == passed ]]
