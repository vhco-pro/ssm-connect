// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include <QDBusConnection>
#include <QObject>

namespace ssmconnect {

/// Reports the end of a system sleep from logind's PrepareForSleep(false) signal, which the shell
/// passes to the helper as `systemWake` so it can check its connections (AC-18).
class SleepWatcher : public QObject {
    Q_OBJECT
public:
    /// Watches `service` on `bus`: logind on the system bus in the app, a fake on the session bus in tests.
    explicit SleepWatcher(QDBusConnection bus = QDBusConnection::systemBus(),
                          const QString &service = QStringLiteral("org.freedesktop.login1"), QObject *parent = nullptr);
    /// Whether the bus accepted the signal subscription.
    bool isWatching() const { return watching_; }

signals:
    void resumed();

private slots:
    void prepareForSleep(bool starting);

private:
    bool watching_ = false;
};

} // namespace ssmconnect
