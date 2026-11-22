// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include <QDBusConnection>
#include <QObject>

#include <memory>

namespace ssmconnect {

/// One shell per user session, through a well-known name on the session bus. The first shell owns
/// the name; a second launch fails to take it, asks the owner to activate (show itself), and exits.
/// Each instance uses its own bus connection, so two in one process behave as two processes would.
class SingleInstance : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "pro.vhco.SSMConnect.Shell")
public:
    /// The owner of `name`, or nullptr when another instance already owns it (that instance has
    /// then been asked to activate).
    static std::unique_ptr<SingleInstance> tryAcquire(const QString &name);
    ~SingleInstance() override;

public slots:
    /// Called by a second launch over D-Bus.
    Q_SCRIPTABLE void Activate();

signals:
    void activated();

private:
    SingleInstance(QDBusConnection connection, QString name);
    QDBusConnection connection_;
    QString name_;
};

} // namespace ssmconnect
