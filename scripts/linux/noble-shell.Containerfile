# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Ubuntu 24.04 with the C++ and Qt 6 toolchain for the Linux shell under linux/, the QML modules
# its tests load, and the Debian packaging tools. Ubuntu 24.04 ships Qt 6.4, the oldest Qt the
# shell supports.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        g++ cmake ninja-build qt6-base-dev qt6-declarative-dev libgl-dev dpkg-dev binutils xz-utils file \
        qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
        qml6-module-qtquick-templates qml6-module-qtquick-window qml6-module-qtqml-workerscript \
        qt6-qpa-plugins ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
