// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The Qt shell's drive-through (T25, AC-11, AC-14): every tray action and every settings action
// reaches the helper as its command, and the helper's requests reach Linux through the shell's
// platform port. Runs with the offscreen platform against an in-process helper.

#include "fakes.h"
#include "linux_shell_platform.h"
#include "shell_controller.h"
#include "startup_registration.h"
#include "tray.h"

#include <QAccessible>
#include <algorithm>
#include <functional>
#include <QAction>
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMenu>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
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
    void setClipboard(const QString &text) override { calls << "clipboard " + text; }
    void reveal(const QString &path) override { calls << "reveal " + path; }
    QString lastBody;
    void notify(const QString &title, const QString &body) override {
        lastBody = body;
        calls << "notify " + title;
    }
    void showError(const QString &action, const QString &message) override { calls << QStringLiteral("error %1: %2").arg(action, message); }
    bool confirmAnswer = false;
    bool confirm(const QString &title, const QString &message) override {
        Q_UNUSED(message);
        calls << "confirm " + title;
        return confirmAnswer;
    }
    QString chooseProfileFile() override { return QStringLiteral("/home/u/workstation.ssmconnect"); }
    int choose(const QString &title, const QString &message, const QStringList &options) override {
        calls << QStringLiteral("choose %1: %2 [%3]").arg(title, message, options.join(','));
        return 0;
    }
};

QJsonObject respond(const QString &name) {
    if (name == "reviewFileChanges") {
        return completed({{"pending", "true"},
                          {"document", R"({"accountId":"111122223333","roleName":"Admin","resourceRegion":"eu-central-1","instanceTagKey":"Name","instanceTagValue":"ws"})"}});
    }
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
    void trayAndSettingsControlsReachTheHelper() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.onCommand = [](const QString &name) { return respond(name); }; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        spawner.started[0]->deliver({{"type", "event"}, {"sequence", 1}, {"workflow", "details"}, {"name", "details"},
                                     {"fields", QJsonObject{{"profiles", "1"}, {"desktop.state", "disconnected"}}}});
        QTRY_COMPARE(controller.details().value("desktop.state").toString(), QStringLiteral("disconnected"));

        // The tray: its items are the macOS menu's controls, shown and enabled as macOS shows them.
        Tray tray(controller, [] {}, [] {}, [] {});
        bool aboutShown = false;
        connect(&controller, &ShellController::showAboutRequested, this, [&] { aboutShown = true; });
        auto *connectItem = tray.menu()->findChild<QAction *>("menucontent-button-machine-actiontitle");
        QVERIFY(connectItem && connectItem->isVisible() && connectItem->isEnabled());
        QCOMPARE(connectItem->text(), QStringLiteral("Connect"));
        QVERIFY(!tray.menu()->findChild<QAction *>("menucontent-button-disconnect")->isVisible());
        connectItem->trigger();
        QTRY_VERIFY(spawner.started[0]->commands().contains("connect"));
        tray.menu()->findChild<QAction *>("menucontent-button-show-log")->trigger();
        QTRY_VERIFY(spawner.started[0]->commands().contains("getLog"));
        tray.menu()->findChild<QAction *>("menucontent-button-about")->trigger();
        QVERIFY(aboutShown);

        // The settings window: select the profile, duplicate it, edit it, and change a setting.
        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty("shell", &controller);
        engine.load(QUrl(QStringLiteral("qrc:/qml/Settings.qml")));
        QVERIFY(!engine.rootObjects().isEmpty());
        QObject *window = engine.rootObjects().first();
        QTRY_COMPARE(controller.profiles().size(), qsizetype(1));
        auto *list = findItem(window, "profiles");
        QVERIFY(list);
        // A profile row is selected through its accessible press action, as a screen reader does.
        QAccessible::setActive(true);
        QTRY_VERIFY(findItem(window, "profile-row"));
        QAccessibleInterface *row = QAccessible::queryAccessibleInterface(findItem(window, "profile-row"));
        QVERIFY(row && row->actionInterface());
        QVERIFY(row->text(QAccessible::Name).contains(QStringLiteral("Workstation")));
        row->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
        QTRY_COMPARE(list->property("currentIndex").toInt(), 0);
        auto *clipboard = QAccessible::queryAccessibleInterface(findItem(window, "settings-clipboard-auto-clear"));
        QVERIFY(clipboard && !clipboard->text(QAccessible::Name).isEmpty());
        auto *remove = findItem(window, "settings-button-delete-the-selected-profile");
        QVERIFY(remove);
        QTRY_VERIFY(!remove->property("enabled").toBool()); // the last profile cannot be deleted, as on macOS
        auto *duplicate = findItem(window, "settings-button-duplicate-the-selected-profile");
        QTRY_VERIFY(duplicate && duplicate->property("enabled").toBool());
        QVERIFY(QMetaObject::invokeMethod(duplicate, "clicked"));
        QTRY_VERIFY(spawner.started[0]->commands().contains("duplicateProfile"));
        QVariantMap edited;
        connect(&controller, &ShellController::editProfileRequested, this, [&](const QVariantMap &profile) { edited = profile; });
        QVERIFY(QMetaObject::invokeMethod(findItem(window, "settings-button-edit"), "clicked"));
        QTRY_COMPARE(edited.value("id").toString(), QStringLiteral("55555555-5555-4555-8555-555555555555"));
        auto *reconnect = findItem(window, "settings-toggle-reconnect-automatically-if-the-tunnel-drops");
        QVERIFY(reconnect);
        QVERIFY(QMetaObject::invokeMethod(reconnect, "toggled"));
        QTRY_VERIFY(spawner.started[0]->commands().contains("saveSettings"));
        // A screen reader toggles a setting with the box's Toggle action, which saves it as a click does.
        QAccessibleInterface *onLaunch = QAccessible::queryAccessibleInterface(findItem(window, "settings-toggle-connect-automatically-on-launch"));
        QVERIFY(onLaunch && onLaunch->actionInterface());
        onLaunch->actionInterface()->doAction(QAccessibleActionInterface::toggleAction());
        QTRY_VERIFY(std::any_of(spawner.started[0]->receivedFrames.begin(), spawner.started[0]->receivedFrames.end(), [](const QJsonObject &frame) {
            return frame.value("name") == "saveSettings" && frame.value("arguments").toObject().value("connectOnLaunch") == "true";
        }));
        QVERIFY(std::any_of(spawner.started[0]->receivedFrames.begin(), spawner.started[0]->receivedFrames.end(), [](const QJsonObject &frame) {
            return frame.value("name") == "saveSettings" && frame.value("arguments").toObject().contains("autoReconnect");
        }));
        for (const auto &frame : spawner.started[0]->receivedFrames) {
            if (frame.value("name") == "duplicateProfile")
                QCOMPARE(frame.value("arguments").toObject().value("id").toString(), QStringLiteral("55555555-5555-4555-8555-555555555555"));

        }
    }

    void everyWindowLoadsWithoutQmlErrors() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.onCommand = [](const QString &name) { return respond(name); }; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        const QStringList windows{QStringLiteral("Settings"), QStringLiteral("Editor"), QStringLiteral("Log"), QStringLiteral("About")};
        for (const QString &name : windows) {
            QQmlApplicationEngine engine;
            QStringList warnings;
            connect(&engine, &QQmlApplicationEngine::warnings, this, [&](const QList<QQmlError> &errors) {
                for (const QQmlError &error : errors) warnings << error.toString();
            });
            engine.rootContext()->setContextProperty("shell", &controller);
            engine.load(QUrl(QStringLiteral("qrc:/qml/%1.qml").arg(name)));
            QVERIFY2(!engine.rootObjects().isEmpty(), qPrintable(name + ": " + warnings.join("; ")));
            QTest::qWait(20);
            QVERIFY2(warnings.isEmpty(), qPrintable(name + ": " + warnings.join("; ")));
            if (name != QStringLiteral("Editor")) continue;
            // Every field a screen reader reaches says what it is, with every optional section shown.
            QObject *editor = engine.rootObjects().first();
            editor->setProperty("draft", QVariantMap{
                {"name", "Workstation"}, {"connectMode", "multiUser"}, {"remoteDevelopment", QVariantMap{{"enabled", true}}},
                {"webForwards", QVariantMap{{"enabled", true}, {"socksPort", 1080}, {"browserMode", "existing"},
                                            {"proxySuffixes", QVariantList{".internal"}},
                                            {"localForwards", QVariantList{QVariantMap{{"name", "Dashboard"}, {"localPort", 8080},
                                                                                       {"remoteHost", "127.0.0.1"}, {"remotePort", 80}}}}}}});
            QTest::qWait(50);
            QAccessible::setActive(true);
            QStringList unnamed;
            std::function<void(QQuickItem *)> visit = [&](QQuickItem *item) {
                const QString type = QString::fromLatin1(item->metaObject()->className());
                if (item->isVisible() && item->objectName().startsWith(QStringLiteral("profileeditor-"))
                    && (type.contains("TextField") || type.contains("ComboBox") || type.contains("SpinBox"))) {
                    QAccessibleInterface *a11y = QAccessible::queryAccessibleInterface(item);
                    if (!a11y || (a11y->text(QAccessible::Name).isEmpty() && a11y->text(QAccessible::Description).isEmpty()))
                        unnamed << item->objectName();
                }
                for (QQuickItem *child : item->childItems()) visit(child);
            };
            visit(qobject_cast<QQuickWindow *>(editor)->contentItem());
            QVERIFY2(unnamed.isEmpty(), qPrintable("fields without an accessible name: " + unnamed.join(", ")));
        }
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
        emitEvent(helper, "shell", "launchApplication",
                  {{"kind", "browser"}, {"path", "/opt/google/chrome/chrome"}, {"arguments", QStringLiteral("--user-data-dir=/s/p%1--proxy-pac-url=data:x").arg(QChar(0x1F))}});
        emitEvent(helper, "shell", "setClipboard", {{"text", "password"}});
        emitEvent(helper, "shell", "notify", {{"title", "Connected"}, {"body", "Workstation"}});
        emitEvent(helper, "shell", "reveal", {{"path", "/home/m/.config/ssm-connect/proxy.pac"}});
        emitEvent(helper, "desktop", "state", {{"state", "Connected"}});
        QTRY_COMPARE(platform.calls.size(), qsizetype(7));
        QCOMPARE(platform.calls, QStringList({"open https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD",
                                              "start code --folder-uri vscode-remote://ssh-remote+ws/home",
                                              "start dcvviewer /run/user/1000/ws.dcv", "start chrome --user-data-dir=/s/p --proxy-pac-url=data:x",
                                              "clipboard password", "notify Connected", "reveal /home/m/.config/ssm-connect/proxy.pac"}));
        QTRY_COMPARE(controller.states().value("desktop").toString(), QStringLiteral("Connected"));
    }

    // The sign-in page and documentation are https; Open <forward> opens the forward's local page
    // over http on the loopback address. Nothing else is opened.
    void theShellOpensHttpsAndLocalForwardPagesOnly() {
        QVERIFY(LinuxShellPlatform::opens("https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD"));
        QVERIFY(LinuxShellPlatform::opens("http://127.0.0.1:4466/"));
        QVERIFY(LinuxShellPlatform::opens("http://localhost:8080/dashboard"));
        QVERIFY(LinuxShellPlatform::opens("http://[::1]:4466/"));
        QVERIFY(!LinuxShellPlatform::opens("http://example.com/"));
        QVERIFY(!LinuxShellPlatform::opens("http://127.0.0.1.example.com/"));
        QVERIFY(!LinuxShellPlatform::opens("file:///etc/passwd"));
        QVERIFY(!LinuxShellPlatform::opens("javascript:alert(1)"));
    }

    // The helper sends its details only after a first command, so the shell asks for its profiles
    // whenever a helper becomes ready; until the details arrive, only the controls the shell serves
    // itself are offered, and a replacement helper starts from no details.
    void aReadyHelperIsAskedForItsDetailsAndNothingNeedingItIsOfferedBefore() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.onCommand = [](const QString &name) { return respond(name); }; };
        HelperHost host(spawner, Build, limits(), clock);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        const QString web = QStringLiteral("menucontent-button-webforwards-state-on-webforwards-state-starting-tur");
        QVERIFY(!controller.isOffered(web));
        QVERIFY(!controller.isOffered("menucontent-button-machine-actiontitle"));
        QVERIFY(controller.isOffered("menu-settings") && controller.isOffered("menucontent-button-quit"));
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        QTRY_VERIFY(spawner.started[0]->commands().contains("listProfiles"));
        emitEvent(*spawner.started[0], "details", "details", {{"profiles", "1"}, {"desktop.state", "disconnected"}, {"web.enabled", "false"}, {"web.state", "Off"}});
        QTRY_VERIFY(controller.isOffered("menucontent-button-machine-actiontitle"));
        QVERIFY(!controller.isOffered(web));
        spawner.started[0]->exit();
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
        QVERIFY(!controller.isOffered("menucontent-button-machine-actiontitle"));
        QTRY_VERIFY(spawner.started[1]->commands().contains("listProfiles"));
    }

    // Reload / Review Changes, as on macOS: outside changes to an attached file are shown with a
    // preview and Keep Pending, and the profiles reload so Apply External Changes reads them as pending.
    void reviewingOutsideChangesShowsThemAndReloadsTheProfiles() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.onCommand = [](const QString &name) { return respond(name); }; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        emitEvent(*spawner.started[0], "details", "details", {{"profiles", "1"}, {"desktop.state", "disconnected"}});
        QTRY_VERIFY(!controller.details().isEmpty());
        QTRY_VERIFY(spawner.started[0]->commands().contains("listProfiles"));
        const qsizetype listed = spawner.started[0]->commands().count("listProfiles");
        controller.trigger("settings-button-reload-review-changes", {{"id", "55555555-5555-4555-8555-555555555555"}}, {{"selected.attached", "true"}});
        QTRY_VERIFY(spawner.started[0]->commands().count("listProfiles") > listed);
        const QStringList shown = platform.calls.filter(QStringLiteral("choose Review external profile changes"));
        QCOMPARE(shown.size(), qsizetype(1));
        QVERIFY(shown[0].contains(QStringLiteral("Account: 111122223333, role: Admin")));
        QVERIFY(shown[0].contains(QStringLiteral("target: Name=ws")));
        QVERIFY(shown[0].endsWith(QStringLiteral("[Keep Pending]")));
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

    void signInRequiredNotifiesOnceAndNamesTheMenuItem() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        FakeHelper &helper = *spawner.started[0];
        emitEvent(helper, "authorization", "state", {{"state", "refreshing"}});
        emitEvent(helper, "authorization", "state", {{"state", "signInRequired"}});
        emitEvent(helper, "authorization", "state", {{"state", "signInRequired"}});
        QTRY_COMPARE(controller.states().value("authorization").toString(), QStringLiteral("signInRequired"));
        emitEvent(helper, "authorization", "state", {{"state", "ready"}});
        QTRY_COMPARE(controller.states().value("authorization").toString(), QStringLiteral("ready"));
        QCOMPARE(platform.calls.filter(QStringLiteral("notify")), QStringList({QStringLiteral("notify Sign in required")}));
        QVERIFY(platform.lastBody.contains(QStringLiteral("Sign In with SSO")));
    }

    void aDisconnectDuringConnectCancelsTheConnect() {
        // The helper refuses a second desktop command while Connect runs, so Disconnect then cancels
        // the Connect, as Disconnect while connecting does on macOS; the helper's cancel ends what
        // the Connect started.
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) {
            helper.onCommand = [](const QString &name) -> std::optional<QJsonObject> {
                if (name == "connect") return std::nullopt;
                return respond(name);
            };
        };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        ShellController controller(host, platform);
        const auto action = [](const QString &command) {
            for (const ShellAction &candidate : ShellController::menuActions())
                if (candidate.command == command) return candidate;
            return ShellAction{};
        };
        HelperCommand *connecting = controller.run(action("connect"));
        QTRY_VERIFY(spawner.started[0]->commands().contains("connect"));
        controller.run(action("disconnect"));
        QTRY_VERIFY(connecting->isFinished());
        QCOMPARE(connecting->result().outcome, HelperOutcome::Cancelled);
        QString connectID;
        QStringList cancelled;
        for (const auto &frame : spawner.started[0]->receivedFrames) {
            if (frame.value("type") == "command" && frame.value("name") == "connect") connectID = frame.value("id").toString();
            if (frame.value("type") == "cancel") cancelled << frame.value("id").toString();
        }
        QCOMPARE(cancelled, QStringList({connectID}));
        QVERIFY(!spawner.started[0]->commands().contains("disconnect"));
        QVERIFY2(platform.calls.filter(QStringLiteral("error")).isEmpty(), qPrintable(platform.calls.join("; ")));

        // With no Connect running, Disconnect is the helper's disconnect command.
        controller.run(action("disconnect"));
        QTRY_VERIFY(spawner.started[0]->commands().contains("disconnect"));
    }

    void savingAnAttachedFileAsksForConsentAndOffersTheFilesVersionOnAConflict() {
        ManualClock clock;
        FakeSpawner spawner;
        int saves = 0;
        spawner.configure = [&saves](FakeHelper &helper) {
            helper.onCommand = [&saves](const QString &name) -> std::optional<QJsonObject> {
                auto failed = [](const QString &code) {
                    return QJsonObject{{"type", "result"}, {"outcome", "failed"}, {"error", QJsonObject{{"code", code}, {"message", code}}}};
                };
                if (name == "saveProfile") {
                    ++saves;
                    if (saves == 1) return failed("formattingConsentRequired");
                    if (saves == 2) return completed();
                    return failed("fileConflict");
                }
                if (name == "listProfiles") return completed({{"profiles", "[]"}, {"active", ""}});
                return completed();
            };
        };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        RecordingPlatform platform;
        platform.confirmAnswer = true;
        ShellController controller(host, platform);
        const QVariantMap profile{{"id", "55555555-5555-4555-8555-555555555555"}, {"name", "Workstation"}};
        controller.saveProfile(profile);
        QTRY_COMPARE(saves, 2);
        controller.saveProfile(profile);
        QTRY_VERIFY(spawner.started[0]->commands().contains("applyFileChanges"));
        QStringList sent;
        QStringList accepted;
        QString appliedID;
        for (const auto &frame : spawner.started[0]->receivedFrames) {
            if (frame.value("type") != "command") continue;
            const QString name = frame.value("name").toString();
            if (name == "listProfiles") continue;
            sent << name;
            if (name == "saveProfile") accepted << frame.value("arguments").toObject().value("acceptFormatting").toString();
            if (name == "applyFileChanges") appliedID = frame.value("arguments").toObject().value("id").toString();
        }
        QCOMPARE(sent, QStringList({"saveProfile", "saveProfile", "saveProfile", "applyFileChanges"}));
        QCOMPARE(accepted, QStringList({"", "true", ""}));
        QCOMPARE(appliedID, QStringLiteral("55555555-5555-4555-8555-555555555555"));
        QCOMPARE(platform.calls.filter(QStringLiteral("confirm")).size(), qsizetype(2));
        for (const QString &call : platform.calls) QVERIFY2(!call.startsWith("error"), qPrintable(call));
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
