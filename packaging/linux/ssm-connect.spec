# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# The Fedora package, built by packaging/linux/build-packages.sh from a payload it has already
# built and stamped: the Qt shell, the Swift helper and editor proxy (static Swift runtime), the
# Session Manager plugin, the desktop entry, the icon and the notices. It has no scriptlets:
# Fedora's file triggers refresh the desktop database and the icon cache.

%global debug_package %{nil}
%global _build_id_links none
# The Swift executables carry their build ID and the plugin's hash, checked byte for byte before
# each launch; keep every bundled executable exactly as built.
%global __os_install_post %{nil}

Name:           ssm-connect
Version:        %{ssm_version}
Release:        1%{?dist}
Summary:        Connect to EC2 workstations through AWS Systems Manager
License:        Apache-2.0
URL:            https://github.com/vhco-pro/ssm-connect
ExclusiveArch:  x86_64

# Loaded at run time, so not found by the automatic dependency scan.
Requires:       qt6-qtdeclarative
Requires:       systemd
Requires:       util-linux
Recommends:     openssh-clients
Recommends:     xdg-utils

%description
SSM Connect opens an Amazon DCV session, a VS Code remote workspace or web forwards to an EC2
workstation over AWS Systems Manager, with no inbound security-group rules, signed in with your
own AWS IAM Identity Center identity.

%install
cp -a %{payload}/. %{buildroot}/

%files
%{_bindir}/ssm-connect
%dir %{_libexecdir}/ssm-connect
%{_libexecdir}/ssm-connect/SSMConnectHelper
%{_libexecdir}/ssm-connect/ssm-connect-proxy
%{_libexecdir}/ssm-connect/session-manager-plugin
%{_datadir}/applications/ssm-connect.desktop
%{_datadir}/icons/hicolor/256x256/apps/ssm-connect.png
%license %{_datadir}/licenses/ssm-connect/LICENSE
%license %{_datadir}/licenses/ssm-connect/ThirdPartyNotices.txt
%license %{_datadir}/licenses/ssm-connect/session-manager-plugin
