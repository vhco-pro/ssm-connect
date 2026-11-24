#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Builds the Linux release: SSMConnect-<version>-fedora43-x86_64.rpm and
# SSMConnect-<version>-ubuntu24.04-amd64.deb, each with a SHA-256 file. The release workflow's
# Linux job runs it, and it runs the same way on any Linux machine with Docker. It:
#
# 1. fetches the Session Manager plugin and checks its pinned hashes;
# 2. stamps the build ID and the plugin's SHA-256 into a copy of the Swift package and builds the
#    helper and editor proxy on each distribution with the static Swift runtime, so no Swift
#    package is needed;
# 3. builds the Qt shell on each distribution, against its own Qt, with the same build ID, and
#    runs the shell's tests there (offscreen; the systemd tests skip without a user instance);
# 4. packages each payload, with no maintainer scripts (the distributions' own triggers refresh
#    the desktop database and icon cache), and a lower-versioned copy for the upgrade test.
#
#   packaging/linux/build-packages.sh <version> [build] [output]
#
# Output defaults to dist/; the lower-versioned copies go to .build/linux-release/prior. The
# file release-outputs-linux.txt in the output lists the results as key=value lines.
set -euo pipefail

version="${1:?usage: build-packages.sh <version> [build] [output]}"
build="${2:-$version}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$(mkdir -p "${3:-$root/dist}" && cd "${3:-$root/dist}" && pwd)"
work="$root/.build/linux-release"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "Expected a semantic version, got '$version'." >&2; exit 1; }
# RPM and Debian versions sort a prerelease below its release with a tilde. RPM accepts no hyphen
# in Version, so the prerelease's own hyphens, as in a branch label, become dots.
package_version="${version/-/\~}"
package_version="${package_version//-/.}"
# Prints the package version and stops, for the release checks.
[ "${SSM_PRINT_PACKAGE_VERSION:-}" = 1 ] && { echo "$package_version"; exit 0; }
user=(--user "$(id -u):$(id -g)" -e HOME=/tmp/home)

image() {
    local tag="$1" file="$2"
    docker image inspect "$tag" >/dev/null 2>&1 || docker build -t "$tag" -f "$root/scripts/linux/$file" "$root/scripts/linux" >&2
}
image ssm-connect-shell:fedora43 fedora43-shell.Containerfile
image ssm-connect-shell:noble noble-shell.Containerfile

rm -rf "$work"
mkdir -p "$work"

# 1. The plugin.
docker run --rm "${user[@]}" -v "$root":/repo:ro -v "$work":/work ssm-connect-shell:noble \
    bash -c 'mkdir -p /tmp/home && /repo/scripts/fetch-plugin-linux.sh /work/plugin >/dev/null'
plugin_hash="$(sha256sum "$work/plugin/bin/session-manager-plugin" | cut -d' ' -f1)"

# 2. The helper and proxy, from a stamped copy of the package.
mkdir -p "$work/kit"
(cd "$root" && tar --exclude=.build --exclude='SSMConnectKit/Tests/SSMConnectKitTests' -cf - SSMConnectKit) | tar -xf - -C "$work/kit"
installed="$work/kit/SSMConnectKit/Sources/SSMConnectWorkflow/InstalledBuild.swift"
sed -i "s|package static let marker = \"ssm-connect-build:dev;\"|package static let marker = \"ssm-connect-build:$build;\"|;
        s|package static let pluginSHA256: String? = nil|package static let pluginSHA256: String? = \"$plugin_hash\"|" "$installed"
grep -qF "ssm-connect-build:$build;" "$installed" && grep -qF "$plugin_hash" "$installed" \
    || { echo "Could not stamp the build and plugin hash into $installed." >&2; exit 1; }
# Each distribution's helper and proxy are built on it: the static Swift runtime still links the
# system's libcurl, whose symbol versions differ between Fedora and Ubuntu.
swift_build() {
    local tag="$1" name="$2"
    docker run --rm "${user[@]}" -v "$work":/work "$tag" bash -c "
        set -e; mkdir -p /tmp/home
        for product in SSMConnectHelper ssm-connect-proxy; do
            swift build -c release --static-swift-stdlib --only-use-versions-from-resolved-file \
                --package-path /work/kit/SSMConnectKit --scratch-path /work/swift-build-$name --product \$product
        done
        mkdir -p /work/swift-$name && cp /work/swift-build-$name/release/SSMConnectHelper /work/swift-build-$name/release/ssm-connect-proxy /work/swift-$name/"
}
docker image inspect ssm-connect-swift:6.4.2-fedora43 >/dev/null 2>&1 \
    || docker build -t ssm-connect-swift:6.4.2-fedora43 -f "$root/scripts/linux/fedora43.Containerfile" "$root/scripts/linux" >&2
swift_build ssm-connect-swift:6.4.2-fedora43 fedora43
swift_build swift:6.4.2-noble noble

# The notices for what the packages bundle. Qt comes from the distribution and is not bundled.
notices="$work/ThirdPartyNotices.txt"
{
    echo "SSM Connect $version for Linux: third-party notices"
    echo
    echo "SSM Connect is licensed under the Apache License 2.0 (LICENSE). Its helper and editor proxy"
    echo "include the components below. The AWS Session Manager plugin (session-manager-plugin) is"
    echo "redistributed under the Apache License 2.0; its LICENSE, NOTICE and THIRD-PARTY files are in"
    echo "the session-manager-plugin folder. The shell uses the distribution's Qt 6 libraries, which"
    echo "are not part of this package."
    section() {
        printf '\n%s\n%s\n%s\n' "$(printf '=%.0s' {1..78})" "$1" "$(printf '=%.0s' {1..78})"
        shift
        for file in "$@"; do [[ -f "$file" ]] || { echo "Missing notice input $file." >&2; exit 1; }; echo; cat "$file"; done
    }
    section "Swift runtime, Foundation and libdispatch (Apache License 2.0 with Runtime Library Exception)" "$root/packaging/windows/notices/Swift-LICENSE.txt"
    section "ICU, used by Foundation (Unicode License V3 and ICU licenses)" "$root/packaging/windows/notices/ICU-LICENSE.txt"
    section "SwiftCrypto, with the BoringSSL and XKCP code it vendors (Apache License 2.0)" "$work/swift-build-noble/checkouts/swift-crypto/LICENSE.txt" "$work/swift-build-noble/checkouts/swift-crypto/NOTICE.txt"
    section "Yams (MIT)" "$work/swift-build-noble/checkouts/Yams/LICENSE"
    section "LibYAML, vendored by Yams (MIT)" "$root/packaging/windows/notices/libyaml-LICENSE.txt"
} > "$notices"

# 3. The shell on each distribution, tested there.
shell() {
    local tag="$1" directory="$2"
    docker run --rm "${user[@]}" -e QT_QPA_PLATFORM=offscreen -v "$root/linux":/src:ro -v "$root/contracts":/contracts:ro -v "$work":/work "$tag" bash -c "
        set -e; mkdir -p /tmp/home
        cmake -S /src -B /work/$directory -G Ninja -DCMAKE_BUILD_TYPE=Release -DSSM_CONNECT_BUILD='$build' -DSSM_PARITY_INVENTORY=/contracts/macos-parity.json >/dev/null
        cmake --build /work/$directory
        /work/$directory/helper_host_test
        /work/$directory/shell_test
        /work/$directory/parity_test"
}
shell ssm-connect-shell:fedora43 shell-fedora43
shell ssm-connect-shell:noble shell-noble

# The payload both packages share, with the distribution's shell and license folder.
stage() {
    local payload="$1" distribution="$2" licenses="$3"
    install -D -m 0755 "$work/shell-$distribution/ssm-connect" "$payload/usr/bin/ssm-connect"
    for executable in "$work/swift-$distribution/SSMConnectHelper" "$work/swift-$distribution/ssm-connect-proxy" "$work/plugin/bin/session-manager-plugin"; do
        install -D -m 0755 "$executable" "$payload/usr/libexec/ssm-connect/$(basename "$executable")"
    done
    install -D -m 0644 "$root/packaging/linux/ssm-connect.desktop" "$payload/usr/share/applications/ssm-connect.desktop"
    install -D -m 0644 "$root/packaging/linux/ssm-connect.png" "$payload/usr/share/icons/hicolor/256x256/apps/ssm-connect.png"
    install -D -m 0644 "$root/LICENSE" "$payload/$licenses/LICENSE"
    install -D -m 0644 "$notices" "$payload/$licenses/ThirdPartyNotices.txt"
    for notice in LICENSE NOTICE THIRD-PARTY; do
        install -D -m 0644 "$work/plugin/$notice" "$payload/$licenses/session-manager-plugin/$notice"
    done
}
stage "$work/payload-rpm" fedora43 usr/share/licenses/ssm-connect
stage "$work/payload-deb" noble usr/share/doc/ssm-connect
install -m 0644 "$root/LICENSE" "$work/payload-deb/usr/share/doc/ssm-connect/copyright"

# 4. The packages.
package_rpm() {
    local rpm_version="$1" destination="$2"
    docker run --rm "${user[@]}" -v "$root":/repo:ro -v "$work":/work ssm-connect-shell:fedora43 bash -c "
        set -e; mkdir -p /tmp/home
        rpmbuild -bb --quiet --define '_topdir /work/rpmbuild' --define 'ssm_version $rpm_version' \
            --define 'payload /work/payload-rpm' /repo/packaging/linux/ssm-connect.spec"
    mv "$work"/rpmbuild/RPMS/x86_64/ssm-connect-*.rpm "$destination"
}
package_deb() {
    local deb_version="$1" destination="$2"
    docker run --rm "${user[@]}" -v "$work":/work ssm-connect-shell:noble bash -c "
        set -e; mkdir -p /tmp/home /work/debsrc/debian
        printf 'Source: ssm-connect\n\nPackage: ssm-connect\nArchitecture: amd64\n' > /work/debsrc/debian/control
        cd /work/debsrc
        shlibs=\$(dpkg-shlibdeps -O -e/work/payload-deb/usr/bin/ssm-connect -e/work/payload-deb/usr/libexec/ssm-connect/SSMConnectHelper \
                  -e/work/payload-deb/usr/libexec/ssm-connect/ssm-connect-proxy 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
        mkdir -p /work/payload-deb/DEBIAN
        cat > /work/payload-deb/DEBIAN/control <<CONTROL
Package: ssm-connect
Version: $deb_version-1
Architecture: amd64
Maintainer: SSM Connect maintainers <ssm-connect@users.noreply.github.com>
Depends: \$shlibs, qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-layouts, qml6-module-qtquick-templates, qml6-module-qtquick-window, qml6-module-qtqml-workerscript, systemd, util-linux
Recommends: openssh-client, xdg-utils
Section: net
Priority: optional
Homepage: https://github.com/vhco-pro/ssm-connect
Description: Connect to EC2 workstations through AWS Systems Manager
 SSM Connect opens an Amazon DCV session, a VS Code remote workspace or web forwards to an EC2
 workstation over AWS Systems Manager, with no inbound security-group rules, signed in with your
 own AWS IAM Identity Center identity.
CONTROL
        dpkg-deb --root-owner-group --build /work/payload-deb /work/package.deb >/dev/null
        rm -rf /work/payload-deb/DEBIAN"
    mv "$work/package.deb" "$destination"
}

rpm_file="$output/SSMConnect-$version-fedora43-x86_64.rpm"
deb_file="$output/SSMConnect-$version-ubuntu24.04-amd64.deb"
package_rpm "$package_version" "$rpm_file"
package_deb "$package_version" "$deb_file"
mkdir -p "$work/prior"
package_rpm "0.0.0~prior" "$work/prior/prior.rpm"
package_deb "0.0.0~prior" "$work/prior/prior.deb"

for file in "$rpm_file" "$deb_file"; do
    (cd "$(dirname "$file")" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")
done
{
    echo "rpm=$rpm_file"
    echo "deb=$deb_file"
    echo "build=$build"
    echo "prior_rpm=$work/prior/prior.rpm"
    echo "prior_deb=$work/prior/prior.deb"
} > "$output/release-outputs-linux.txt"
cat "$output/release-outputs-linux.txt"
