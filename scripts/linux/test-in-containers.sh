#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Runs the Linux test suites of SSMConnectKit on Ubuntu 24.04 (the official swift:6.4.2-noble
# image) and Fedora 43 (fedora43.Containerfile beside this script, built on first use), as the
# current user (the host's passwd and group are mounted read-only, since ssh-keygen needs an entry for
# the uid), with a build cache per distribution under ${SSM_LINUX_CACHE:-/tmp/ssm-linux-build}.
#
#   scripts/linux/test-in-containers.sh                 # both distributions, the default suites
#   scripts/linux/test-in-containers.sh noble 'SSMConnectLinuxTests'
#
# The first argument picks the distribution (noble, fedora43 or all); the second is a swift test
# --filter. Versions come only from Package.resolved, which a Linux resolution would otherwise
# rewrite without the macOS-only pins. Each distribution's transcript is kept in the cache directory as test-<distro>.log.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# The repository is mounted whole: the helper tests read the parity inventory under contracts/.
repo="$(cd "$here/../.." && pwd)"
cache="${SSM_LINUX_CACHE:-/tmp/ssm-linux-build}"
which="${1:-all}"
filter="${2:-SSMConnectLinuxTests|SSMConnectWorkflowTests|SSMConnectHelperTests|SSMConnectAWSTests}"

image_for() {
  case "$1" in
    noble) echo "swift:6.4.2-noble" ;;
    fedora43)
      if ! docker image inspect ssm-connect-swift:6.4.2-fedora43 >/dev/null 2>&1; then
        docker build -t ssm-connect-swift:6.4.2-fedora43 -f "$here/fedora43.Containerfile" "$here" >&2
      fi
      echo "ssm-connect-swift:6.4.2-fedora43" ;;
    *) echo "unknown distribution $1" >&2; exit 2 ;;
  esac
}

run() {
  local distro="$1" image log
  image="$(image_for "$distro")"
  mkdir -p "$cache/$distro"
  log="$cache/test-$distro.log"
  echo "== $distro ($image): swift test --filter '$filter'"
  set +e
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/home -e NO_COLOR=1 \
    -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
    -v "$repo":/repo -v "$cache/$distro":/build -w /repo/SSMConnectKit "$image" \
    bash -c 'mkdir -p /tmp/home && cat /etc/os-release | grep PRETTY_NAME && swift --version 2>&1 | head -1 &&
             swift test --build-system native --scratch-path /build --only-use-versions-from-resolved-file --filter "$0"' "$filter" > "$log" 2>&1
  local status=$?
  set -e
  grep -E "PRETTY_NAME|Swift version|error:|Test run with|✘|recorded an issue" "$log" | grep -v "skipping cache" | head -40
  echo "== $distro exit $status (transcript $log)"
  return $status
}

status=0
for distro in noble fedora43; do
  if [ "$which" = all ] || [ "$which" = "$distro" ]; then run "$distro" || status=1; fi
done
exit $status
