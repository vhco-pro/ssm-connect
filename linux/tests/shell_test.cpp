// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The Qt shell's drive-through (T25, AC-11, AC-14): every tray action and every settings action
// reaches the helper as its command, and the helper's requests reach Linux through the shell's
// platform port. Runs with the offscreen platform against an in-process helper.

#include "fakes.h"
#include "shell_controller.h"
#include "startup_registration.h"
#include "tray.h"

#include <QAction>
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMenu>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

using namespace ssmconnect;
using namespace ssmconnect::testing;

namespace {

class RecordingPlatform : public ShellPlatform {
public:
    QStringList calls;
    QString dcvViewerPath() const override { return QStringLiteral("/usr/bin/dcvviewer"); }
    void openUrl(const QString &url) override { calls << "open " + url; }
    void start(const QString &path, const QStringList &arguments) override {
        calls << QStringLiteral("start %1 %2").arg(QFileInfo(path).fileName(), arguments.join(' '));
    }
    void startBrowser(const QString &browser, const QString &mode, const QString &profile, int socksPort) override {
        Q_UNUSED(profile);
        calls << QStringLiteral("browser %1 %2 %3").arg(browser, mode).arg(socksPort);
    }
    void setClipboard(const QString &text) override { calls << "clipboard " + text; }
    void notify(const QString &title, const QString &body) override {
        Q_UNUSED(body);
        calls << "notify " + title;
    }
    void showError(const QString &action, const QString &message) override { calls << QStringLiteral("error %1: %2").arg(action, message); }
    QString chooseProfileFile() override { return QStringLiteral("/home/u/workstation.ssmconnect"); }
};

QJsonObject respond(const QString &name) {
    if (name == "listProfiles") {
        return completed({{"profiles", R"([{"id":"55555555-5555-4555-8555-555555555555","name":"Workstation","ssoRegion":"eu-west-1"}])"},
                          {"active", ""}});
    }
    return completed();
}

/// Finds an item by objectName in the visual tree: items a Repeater creates have a visual
/// parent but no QObject parent, so findChild does not reach them.
QQuickItem *findItem(QQuickItem *item, const QString &name) {
    if (!item) return nullptr;
    if (item->objectName() == name) return item;
    for (QQuickItem *child : item->childItems())
        if (QQuickItem *found = findItem(child, name)) return found;
    return nullptr;
}

QQuickItem *findItem(QObject *root, const QString &name) {
    auto *window = qobject_cast<QQuickWindow *>(root);
    return findItem(window ? window->contentItem() : qobject_cast<QQuickItem *>(root), name);
}

} // namespace

class ShellTest : public QObject {
    Q_OBJECT

private slots:
    void everyTrayAndSettingsActionReachesTheHelperAsItsCommand() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.onCommand = [](const QString &name) { return respond(name); }; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);

        // The tray menu: trigger every action item.
        Tray tray(controller, [] {}, [] {}, [] {});
        for (QAction *action : tray.menu()->actions())
            if (action->data().isValid()) action->trigger();
        const QStringList menuCommands{"signIn", "connect", "disconnect", "stopWorkstation", "openEditor",
                                       "startWebForwards", "stopWebForwards", "openBrowser"};
        for (const QString &command : menuCommands) QTRY_VERIFY2(spawner.started[0]->commands().contains(command), qPrintable(command));

        // The settings window: load profiles, select one, edit and save, use it, import a file,
        // set up VS Code. Each button's command arrives before the next is pressed.
        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty("shell", &controller);
        engine.load(QUrl(QStringLiteral("qrc:/qml/Settings.qml")));
        QVERIFY(!engine.rootObjects().isEmpty());
        QObject *window = engine.rootObjects().first();
        QTRY_COMPARE(controller.profiles().size(), qsizetype(1));
        auto *list = findItem(window, "profiles");
        QVERIFY(list);
        list->setProperty("currentIndex", 0);
        QTRY_VERIFY(findItem(window, "name"));
        QTRY_COMPARE(findItem(window, "name")->property("text").toString(), QStringLiteral("Workstation"));
        findItem(window, "roleName")->setProperty("text", "Admin");
        const std::vector<std::pair<QString, QString>> buttons{
            {"save", "saveProfile"}, {"use", "setActiveProfile"}, {"import", "importProfile"}, {"editorSetup", "installEditorSetup"}};
        for (const auto &[button, command] : buttons) {
            auto *item = findItem(window, button);
            QVERIFY2(item, qPrintable(button));
            QVERIFY(QMetaObject::invokeMethod(item, "clicked"));
            QTRY_VERIFY2(spawner.started[0]->commands().contains(command), qPrintable(command));
            if (button == "save") {
                QTRY_COMPARE(spawner.started[0]->commands().count("listProfiles"), 2);
                QCOMPARE(list->property("currentIndex").toInt(), 0);
            }
        }
        const QJsonObject saved = [&] {
            for (const auto &frame : spawner.started[0]->receivedFrames)
                if (frame.value("name") == "saveProfile") return frame;
            return QJsonObject{};
        }();
        const QJsonObject profile = QJsonDocument::fromJson(saved.value("arguments").toObject().value("profile").toString().toUtf8()).object();
        QCOMPARE(profile.value("id").toString(), QStringLiteral("55555555-5555-4555-8555-555555555555"));
        QCOMPARE(profile.value("roleName").toString(), QStringLiteral("Admin"));
        for (const auto &frame : spawner.started[0]->receivedFrames) {
            if (frame.value("name") == "setActiveProfile")
                QCOMPARE(frame.value("arguments").toObject().value("id").toString(), QStringLiteral("55555555-5555-4555-8555-555555555555"));
            if (frame.value("name") == "importProfile")
                QCOMPARE(frame.value("arguments").toObject().value("path").toString(), QStringLiteral("/home/u/workstation.ssmconnect"));
        }
        for (const QString &call : platform.calls) QVERIFY2(!call.startsWith("error"), qPrintable(call));
    }

    void helperRequestsReachLinuxThroughTheShell() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        FakeHelper &helper = *spawner.started[0];
        emitEvent(helper, "shell", "openURL", {{"url", "https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD"}});
        emitEvent(helper, "shell", "launchApplication",
                  {{"kind", "vsCode"}, {"path", "/usr/bin/code"}, {"arguments", QStringLiteral("--folder-uri%1vscode-remote://ssh-remote+ws/home").arg(QChar(0x1F))}});
        emitEvent(helper, "shell", "launchApplication", {{"kind", "dcvViewer"}, {"file", "/run/user/1000/ws.dcv"}});
        emitEvent(helper, "shell", "launchApplication", {{"kind", "browser"}, {"browser", "chrome"}, {"mode", "separate"}, {"profile", "p"}, {"socksPort", "1080"}});
        emitEvent(helper, "shell", "setClipboard", {{"text", "password"}});
        emitEvent(helper, "shell", "notify", {{"title", "Connected"}, {"body", "Workstation"}});
        emitEvent(helper, "desktop", "state", {{"state", "Connected"}});
        QTRY_COMPARE(platform.calls.size(), qsizetype(6));
        QCOMPARE(platform.calls, QStringList({"open https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD",
                                              "start code --folder-uri vscode-remote://ssh-remote+ws/home",
                                              "start dcvviewer /run/user/1000/ws.dcv", "browser chrome separate 1080",
                                              "clipboard password", "notify Connected"}));
        QTRY_COMPARE(controller.states().value("desktop").toString(), QStringLiteral("Connected"));
    }

    void aStoppedHelperClearsTheWorkflowStatesTheShellShows() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        QSignalSpy changed(&controller, &ShellController::stateChanged);
        emitEvent(*spawner.started[0], "desktop", "state", {{"state", "tunneling"}});
        QTRY_COMPARE(controller.states().value("desktop").toString(), QStringLiteral("tunneling"));
        const int before = changed.count();
        spawner.started[0]->exit();
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
        // The replacement helper holds no connection, so nothing the old one reported is shown.
        QVERIFY(controller.states().isEmpty());
        QVERIFY(changed.count() > before);
    }

    void startingAtSignInIsAnXdgAutostartEntry() {
        QTemporaryDir config;
        StartupRegistration startup(config.path());
        QVERIFY(!startup.isEnabled());
        startup.setEnabled(true, "/usr/bin/ssm-connect");
        QVERIFY(startup.isEnabled());
        QFile entry(config.path() + "/autostart/ssm-connect.desktop");
        QVERIFY(entry.open(QIODevice::ReadOnly));
        const QString text = QString::fromUtf8(entry.readAll());
        QVERIFY(text.contains("Type=Application"));
        QVERIFY(text.contains("Exec=/usr/bin/ssm-connect"));
        startup.setEnabled(false, {});
        QVERIFY(!startup.isEnabled());
    }
};

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QApplication app(argc, argv);
    ShellTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "shell_test.moc"
