#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Inspects the Linux packages and installs them on clean Fedora 43 and Ubuntu 24.04 containers
# (the AC-21 and AC-24 package checks; native desktop acceptance is separate):
#
#   - no maintainer scripts, and every bundled executable, desktop entry, icon and notice present;
#   - the helper and proxy carry the build marker and the bundled plugin's SHA-256, and the helper
#     reports the build;
#   - the package installs over an older one with its dependencies resolved by the distribution,
#     no library is missing, and the shell starts and keeps running on a session bus;
#   - uninstalling removes the program files and keeps the user's settings.
#
#   packaging/linux/test-packages.sh <rpm> <deb> <build> <prior-rpm> <prior-deb>
set -euo pipefail

rpm_file="$(realpath "$1")"; deb_file="$(realpath "$2")"; build="$3"
prior_rpm="$(realpath "$4")"; prior_deb="$(realpath "$5")"

# The checks both distributions share, run as root in the container after the upgrade.
read -r -d '' installed_checks <<'CHECKS' || true
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
for file in /usr/bin/ssm-connect /usr/libexec/ssm-connect/SSMConnectHelper /usr/libexec/ssm-connect/ssm-connect-proxy \
            /usr/libexec/ssm-connect/session-manager-plugin /usr/share/applications/ssm-connect.desktop \
            /usr/share/icons/hicolor/256x256/apps/ssm-connect.png "$LICENSES/LICENSE" "$LICENSES/ThirdPartyNotices.txt" \
            "$LICENSES/session-manager-plugin/LICENSE" "$LICENSES/session-manager-plugin/NOTICE" "$LICENSES/session-manager-plugin/THIRD-PARTY"; do
    check "installed $file" "[ -e '$file' ]"
done
for component in "Swift runtime" ICU SwiftCrypto Yams LibYAML "Session Manager plugin"; do
    check "the notices cover $component" "grep -q '$component' '$LICENSES/ThirdPartyNotices.txt'"
done
plugin_hash=$(sha256sum /usr/libexec/ssm-connect/session-manager-plugin | cut -d' ' -f1)
for executable in SSMConnectHelper ssm-connect-proxy; do
    check "$executable carries the build marker for $BUILD" "grep -aqF 'ssm-connect-build:$BUILD;' /usr/libexec/ssm-connect/$executable"
    check "$executable records the bundled plugin's SHA-256" "grep -aqF '$plugin_hash' /usr/libexec/ssm-connect/$executable"
done
check "the helper starts and reports build $BUILD" "[ \"\$(/usr/libexec/ssm-connect/SSMConnectHelper --build)\" = '$BUILD' ]"
check "the editor proxy starts (usage, exit 1)" "/usr/libexec/ssm-connect/ssm-connect-proxy >/dev/null 2>&1; [ \$? -eq 1 ]"
for executable in /usr/bin/ssm-connect /usr/libexec/ssm-connect/SSMConnectHelper /usr/libexec/ssm-connect/ssm-connect-proxy; do
    check "no library missing for $executable" "[ -x $executable ] && ! ldd $executable 2>&1 | grep -q 'not found'"
done
check "the desktop entry is valid" "! command -v desktop-file-validate >/dev/null || desktop-file-validate /usr/share/applications/ssm-connect.desktop"
# A tray app has no window: started means still running after a few seconds, on a session bus.
check "the shell starts and keeps running" "dbus-run-session -- env QT_QPA_PLATFORM=offscreen timeout 8 ssm-connect >/tmp/shell.log 2>&1; [ \$? -eq 124 ]"
exit $fail
CHECKS

run() {
    local name="$1" image="$2" licenses="$3" script="$4"
    echo "== $name"
    docker run --rm -e BUILD="$build" -e LICENSES="$licenses" -e CHECKS="$installed_checks" \
        -v "$rpm_file":/pkg/new.rpm:ro -v "$deb_file":/pkg/new.deb:ro \
        -v "$prior_rpm":/pkg/prior.rpm:ro -v "$prior_deb":/pkg/prior.deb:ro "$image" bash -c "$script"
}

status=0
run "Fedora 43: .rpm" registry.fedoraproject.org/fedora:43 /usr/share/licenses/ssm-connect '
    set -e
    scripts=$(rpm -qp --scripts /pkg/new.rpm)
    [ -z "$scripts" ] && echo "ok   the package has no scriptlets" || { echo "FAIL scriptlets: $scripts"; exit 1; }
    # The container image installs no documentation; a desktop install does.
    sed -i "/^tsflags=nodocs/d" /etc/dnf/dnf.conf
    dnf install -y -q dbus-daemon desktop-file-utils >/dev/null
    dnf install -y -q /pkg/prior.rpm >/dev/null && echo "ok   the older package installs"
    mkdir -p /root/.config/ssm-connect && echo "{}" > /root/.config/ssm-connect/settings.json
    dnf install -y -q /pkg/new.rpm >/dev/null && echo "ok   the package upgrades over it ($(rpm -q ssm-connect))"
    bash -c "$CHECKS"
    dnf remove -y -q ssm-connect >/dev/null
    [ ! -e /usr/libexec/ssm-connect ] && [ ! -e /usr/bin/ssm-connect ] && echo "ok   uninstalling removes the program files"
    [ -f /root/.config/ssm-connect/settings.json ] && echo "ok   uninstalling keeps the user settings"' || status=1
run "Ubuntu 24.04: .deb" ubuntu:24.04 /usr/share/doc/ssm-connect '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # The container image is minimized and drops /usr/share/doc; a desktop install keeps it.
    rm -f /etc/dpkg/dpkg.cfg.d/excludes
    mkdir -p /tmp/deb && dpkg-deb -e /pkg/new.deb /tmp/deb
    extra=$(ls /tmp/deb | grep -vxE "control|md5sums" || true)
    [ -z "$extra" ] && echo "ok   the package has no maintainer scripts" || { echo "FAIL maintainer scripts: $extra"; exit 1; }
    apt-get update -qq >/dev/null
    apt-get install -y -qq dbus desktop-file-utils >/dev/null
    apt-get install -y -qq /pkg/prior.deb >/dev/null && echo "ok   the older package installs"
    mkdir -p /root/.config/ssm-connect && echo "{}" > /root/.config/ssm-connect/settings.json
    apt-get install -y -qq /pkg/new.deb >/dev/null && echo "ok   the package upgrades over it ($(dpkg-query -W ssm-connect))"
    bash -c "$CHECKS"
    apt-get remove -y -qq ssm-connect >/dev/null
    [ ! -e /usr/libexec/ssm-connect ] && [ ! -e /usr/bin/ssm-connect ] && echo "ok   uninstalling removes the program files"
    [ -f /root/.config/ssm-connect/settings.json ] && echo "ok   uninstalling keeps the user settings"' || status=1
[ "$status" = 0 ] && echo "Every package check passed." || echo "Package checks failed."
exit $status
