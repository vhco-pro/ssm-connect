// A small process for the native containment tests, run outside the test binary:
//   scope_probe ensure-scope         prints the unit it runs in after ensureOwnScope()
//   scope_probe shell <helper>       acts as a shell: starts <helper> bound to its own scope,
//                                    prints "<unit> <helper pid>", then waits to be killed
#include "systemd_containment.h"
#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextStream>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    const QStringList arguments = app.arguments();
    QTextStream out(stdout);
    if (arguments.value(1) == "ensure-scope") {
        const QString scope = ssmconnect::ensureOwnScope();
        out << scope << ' ' << ssmconnect::currentUnit() << Qt::endl;
        return scope.isEmpty() ? 1 : 0;
    }
    if (arguments.value(1) == "shell") {
        const QString scope = ssmconnect::ensureOwnScope();
        auto *spawner = new ssmconnect::SystemdHelperSpawner(arguments.value(2), scope, {}, &app);
        auto *connection = spawner->start();
        QObject::connect(connection, &ssmconnect::HelperConnection::received, &app, [&](const QByteArray &line) {
            const QJsonObject frame = QJsonDocument::fromJson(line).object();
            if (frame.value("name") == "started") {
                out << spawner->unitFor(connection) << ' ' << frame.value("fields").toObject().value("helper").toString() << Qt::endl;
            }
        });
        return app.exec();
    }
    return 2;
}
