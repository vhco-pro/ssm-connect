// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "single_instance.h"

#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QUuid>

namespace ssmconnect {

std::unique_ptr<SingleInstance> SingleInstance::tryAcquire(const QString &name) {
    const QString connectionName = QStringLiteral("ssm-connect-instance-%1").arg(QUuid::createUuid().toString(QUuid::Id128));
    QDBusConnection connection = QDBusConnection::connectToBus(QDBusConnection::SessionBus, connectionName);
    if (!connection.isConnected()) return nullptr;
    const auto reply = connection.interface()->registerService(name, QDBusConnectionInterface::DontQueueService,
                                                               QDBusConnectionInterface::DontAllowReplacement);
    if (reply.isValid() && reply.value() == QDBusConnectionInterface::ServiceRegistered) {
        std::unique_ptr<SingleInstance> instance(new SingleInstance(connection, name));
        connection.registerObject(QStringLiteral("/"), instance.get(), QDBusConnection::ExportScriptableSlots);
        return instance;
    }
    connection.call(QDBusMessage::createMethodCall(name, QStringLiteral("/"), QStringLiteral("pro.vhco.SSMConnect.Shell"),
                                                   QStringLiteral("Activate")),
                    QDBus::Block, 5000);
    QDBusConnection::disconnectFromBus(connectionName);
    return nullptr;
}

SingleInstance::SingleInstance(QDBusConnection connection, QString name)
    : connection_(std::move(connection)), name_(std::move(name)) {}

SingleInstance::~SingleInstance() {
    connection_.unregisterObject(QStringLiteral("/"));
    connection_.interface()->unregisterService(name_);
    QDBusConnection::disconnectFromBus(connection_.name());
}

void SingleInstance::Activate() { emit activated(); }

} // namespace ssmconnect
