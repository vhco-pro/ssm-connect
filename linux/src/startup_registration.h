// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include <QObject>
#include <QString>

namespace ssmconnect {

/// Starting the shell at sign-in, through an XDG autostart entry in the user's config folder:
/// per user, no elevation, and removed with the file.
class StartupRegistration : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ isEnabled NOTIFY enabledChanged)
public:
    /// `configHome` defaults to `$XDG_CONFIG_HOME`, or `~/.config`.
    explicit StartupRegistration(QString configHome = {}, QObject *parent = nullptr);
    bool isEnabled() const;
    Q_INVOKABLE void setEnabled(bool enabled, const QString &executable);

signals:
    void enabledChanged();

private:
    QString entry() const;
    QString configHome_;
};

} // namespace ssmconnect
