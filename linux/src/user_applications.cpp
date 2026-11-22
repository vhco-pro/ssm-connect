// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "user_applications.h"

#include <QProcess>
#include <QUuid>

namespace ssmconnect {

UserApplications::Launched UserApplications::launch(const QString &program, const QStringList &arguments) {
    const QString unit = QStringLiteral("app-ssm-connect-%1.scope").arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
    // systemd-run --scope registers the scope and then executes the program in place, so the
    // detached process is the application itself.
    qint64 pid = 0;
    const bool started = QProcess::startDetached(
        QStringLiteral("systemd-run"),
        QStringList{"--user", "--scope", "--quiet", "--collect", "--unit=" + unit, "--description=" + program, "--", program}
            + arguments,
        QString(), &pid);
    return started ? Launched{pid, unit} : Launched{0, unit};
}

} // namespace ssmconnect
