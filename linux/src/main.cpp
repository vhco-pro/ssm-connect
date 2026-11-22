// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The SSM Connect Linux shell: a tray icon whose menu sends each action to the private helper,
// which owns every connection rule. One shell per user session; the helper runs in its own
// transient systemd user service bound to the shell's scope.
#include "helper_host.h"
#include "linux_shell_platform.h"
#include "shell_controller.h"
#include "single_instance.h"
#include "startup_registration.h"
#include "systemd_containment.h"
#include "tray.h"

#include <QApplication>
#include <QDir>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>

using namespace ssmconnect;

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("SSM Connect"));
    app.setDesktopFileName(QStringLiteral("ssm-connect"));
    app.setQuitOnLastWindowClosed(false);

    auto instance = SingleInstance::tryAcquire(QStringLiteral("pro.vhco.SSMConnect"));
    if (!instance) return 0; // the running shell was asked to show its settings

    const QString scope = ensureOwnScope();
    // The helper is installed beside the shell's private files, not on PATH.
    const QString helper = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("../libexec/ssm-connect/SSMConnectHelper"));
    SystemdHelperSpawner spawner(QDir::cleanPath(helper), scope, {});
    SystemClock clock;
    HelperHost host(spawner, QStringLiteral(SSM_CONNECT_BUILD), HelperHostLimits{}, clock);

    Tray *tray = nullptr;
    LinuxShellPlatform platform([&](const QString &title, const QString &body) { if (tray) tray->showMessage(title, body, false); },
                                [&](const QString &action, const QString &message) { if (tray) tray->showMessage(action, message, true); });
    ShellController controller(host, platform);
    StartupRegistration startup;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("shell", &controller);
    engine.rootContext()->setContextProperty("startup", &startup);
    engine.rootContext()->setContextProperty("executablePath", QCoreApplication::applicationFilePath());

    auto showSettings = [&] {
        for (QObject *root : engine.rootObjects()) {
            if (auto *window = qobject_cast<QQuickWindow *>(root)) {
                window->show();
                window->raise();
                window->requestActivate();
                return;
            }
        }
        engine.load(QUrl(QStringLiteral("qrc:/qml/Settings.qml")));
    };
    auto quit = [&] { host.shutdown(std::chrono::seconds(5), [] { QCoreApplication::quit(); }); };
    Tray trayIcon(controller, showSettings, [&] { host.retry(); }, quit);
    tray = &trayIcon;
    auto updateTray = [&] {
        const bool ready = host.status() == HelperHostStatus::Ready;
        const QString state = ready ? controller.states().value("desktop", "Disconnected").toString() : QStringLiteral("Error");
        const bool signInRequired = controller.states().value("authorization").toString() == "signInRequired";
        const QString text = !ready ? (host.statusMessage().isEmpty() ? QStringLiteral("Starting…") : host.statusMessage())
                                    : signInRequired ? QStringLiteral("Sign in required") : state;
        trayIcon.update(state, QStringLiteral("SSM Connect: ") + text);
    };
    QObject::connect(&controller, &ShellController::stateChanged, &app, updateTray);
    QObject::connect(&host, &HelperHost::statusChanged, &app, updateTray);
    QObject::connect(instance.get(), &SingleInstance::activated, &app, showSettings);
    host.start();
    return app.exec();
}
