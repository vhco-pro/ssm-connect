# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Fedora 43 with swift.org's Swift 6.4.2, for the Linux tests (test-in-containers.sh). Fedora's own
# swift-lang package is older than the toolchain the package is tested with, and swift.org's newest
# Fedora build of 6.4.2 is the Fedora 41 one, which runs on Fedora 43's userland. The download is
# checked against swift.org's signing keys before it is unpacked.
FROM registry.fedoraproject.org/fedora:43
ARG SWIFT_VERSION=6.4.2
ARG SWIFT_PLATFORM=fedora41
RUN dnf install -y binutils gcc git unzip gnupg2 libcurl-devel libedit-devel libicu-devel sqlite-devel \
        libuuid-devel libxml2-devel python3 libstdc++-devel libstdc++-static openssh-clients \
    && dnf clean all
RUN set -eu; \
    base="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM}/swift-${SWIFT_VERSION}-RELEASE"; \
    file="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}.tar.gz"; \
    curl -fsSL -o /tmp/swift.tgz "$base/$file"; \
    curl -fsSL -o /tmp/swift.tgz.sig "$base/$file.sig"; \
    curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --batch --import -; \
    gpg --batch --verify /tmp/swift.tgz.sig /tmp/swift.tgz; \
    tar -xzf /tmp/swift.tgz --directory / --strip-components=1; \
    rm -f /tmp/swift.tgz /tmp/swift.tgz.sig; \
    swift --version
