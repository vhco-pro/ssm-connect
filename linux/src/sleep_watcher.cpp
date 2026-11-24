// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "sleep_watcher.h"

namespace ssmconnect {

SleepWatcher::SleepWatcher(QDBusConnection bus, const QString &service, QObject *parent) : QObject(parent) {
    watching_ = bus.connect(service, QStringLiteral("/org/freedesktop/login1"), QStringLiteral("org.freedesktop.login1.Manager"),
                            QStringLiteral("PrepareForSleep"), this, SLOT(prepareForSleep(bool)));
}

void SleepWatcher::prepareForSleep(bool starting) {
    // logind sends true before the system sleeps and false once it has woken.
    if (!starting) emit resumed();
}

} // namespace ssmconnect
