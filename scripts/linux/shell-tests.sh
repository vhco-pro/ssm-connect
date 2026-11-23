#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Builds the Linux shell under linux/ in the Fedora 43 build image (fedora43-shell.Containerfile,
# built on first use) and runs its tests on this machine, where the native containment tests reach
# the user's systemd instance. The binaries link the Qt 6 the host desktop already has. Build
# output goes to ${SSM_SHELL_BUILD:-/tmp/ssm-linux-shell-build}; the transcript is test.log there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source="$(cd "$here/../../linux" && pwd)"
build="${SSM_SHELL_BUILD:-/tmp/ssm-linux-shell-build}"
image=ssm-connect-shell:fedora43
mkdir -p "$build"

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build -t "$image" -f "$here/fedora43-shell.Containerfile" "$here" >&2
fi

# The build directory is mounted at the same path inside and outside, so the test binary's
# compiled-in paths to its helper programs resolve on the host as well.
contracts="$(cd "$here/../../contracts" && pwd)"
docker run --rm --user "$(id -u):$(id -g)" -v "$source":/src:ro -v "$build":"$build" -v "$contracts":"$contracts":ro "$image" \
  bash -c "cmake -S /src -B '$build' -G Ninja -DCMAKE_BUILD_TYPE=Debug -DSSM_PARITY_INVENTORY='$contracts/macos-parity.json' >/dev/null && cmake --build '$build'"

status=0
: > "$build/test.log"
for test in helper_host_test shell_test parity_test; do
  "$build/$test" "$@" 2>&1 | tee -a "$build/test.log" || status=1
done
exit $status
