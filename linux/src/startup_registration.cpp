// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "startup_registration.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

namespace ssmconnect {

StartupRegistration::StartupRegistration(QString configHome, QObject *parent)
    : QObject(parent),
      configHome_(configHome.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) : std::move(configHome)) {}

QString StartupRegistration::entry() const { return QDir(configHome_).filePath(QStringLiteral("autostart/ssm-connect.desktop")); }

bool StartupRegistration::isEnabled() const { return QFile::exists(entry()); }

void StartupRegistration::setEnabled(bool enabled, const QString &executable) {
    if (enabled) {
        QDir().mkpath(QFileInfo(entry()).path());
        QFile file(entry());
        if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            file.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=SSM Connect\nExec=%1\nIcon=ssm-connect\n"
                                      "X-GNOME-Autostart-enabled=true\nNoDisplay=false\n")
                           .arg(executable)
                           .toUtf8());
        }
    } else {
        QFile::remove(entry());
    }
    emit enabledChanged();
}

} // namespace ssmconnect
