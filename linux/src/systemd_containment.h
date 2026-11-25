// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include "helper_host.h"

#include <QHash>
#include <QStringList>

class QProcess;

namespace ssmconnect {

/// The systemd unit this process runs in, from its cgroup path.
QString currentUnit();

/// The shell's own systemd scope. KDE and GNOME start each application in a scope; a shell started
/// outside one (from a service, a terminal multiplexer's service or a script) moves itself into a
/// new transient `app-ssm-connect-<uuid>.scope`. Returns the scope's name, or an empty string when
/// no systemd user instance is reachable.
QString ensureOwnScope();

/// Starts each helper as the main process of its own transient systemd user service,
/// `ssm-connect-helper-<uuid>.service`, with `BindsTo=` and `After=` on the shell's scope, so the
/// helper's unit stops when the shell's scope does, even when the helper is hung. The helper's
/// standard input and output are the shell's pipes (`systemd-run --pipe`); there is no socket or
/// other endpoint. Stopping the unit ends every process in it, plugin and SSH descendants included.
class SystemdHelperSpawner : public QObject, public HelperSpawner {
    Q_OBJECT
public:
    SystemdHelperSpawner(QString helperPath, QString shellScope, QStringList arguments, QObject *parent = nullptr);

    HelperConnection *start() override;
    void terminateAndWaitEmpty(HelperConnection *connection, std::function<void()> done) override;

    /// The helper unit of a connection this spawner started.
    QString unitFor(HelperConnection *connection) const { return units_.value(connection); }

private:
    QString helperPath_;
    QString shellScope_;
    QStringList arguments_;
    QHash<HelperConnection *, QString> units_;
};

} // namespace ssmconnect
