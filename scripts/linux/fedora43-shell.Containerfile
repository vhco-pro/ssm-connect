# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Fedora 43 with the C++ and Qt 6 toolchain for the Linux shell under linux/ (the helper host and
# the Qt shell) and the RPM tools for its package. The binaries it builds link the same Qt 6.10 as
# the Fedora 43 desktop they run on.
FROM registry.fedoraproject.org/fedora:43
RUN dnf install -y gcc-c++ cmake ninja-build qt6-qtbase-devel qt6-qtdeclarative-devel rpm-build \
    && dnf clean all
