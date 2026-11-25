// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include <QString>
#include <QStringList>

namespace ssmconnect {

/// Applications that hold the user's work (VS Code, DCV Viewer, browsers) start at the helper's
/// request, each in its own transient systemd user scope, `app-ssm-connect-<uuid>.scope`, never in
/// the helper's unit, so they survive a helper or shell failure.
struct UserApplications {
    struct Launched {
        qint64 pid = 0;
        QString unit;
    };
    static Launched launch(const QString &program, const QStringList &arguments);
};

} // namespace ssmconnect
