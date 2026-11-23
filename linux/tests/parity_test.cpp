// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The Linux shell's macOS parity drive-through (T58, AC-29), driven by contracts/macos-parity.json:
// every macOS control has its Linux control, sends its helper command after macOS's confirmation,
// is offered and enabled when macOS offers and enables it, and a control that interrupts running
// work cancels that command, following up once when the command finished first.

#include "fakes.h"
#include "shell_controller.h"
#include "tray.h"

#include <QAction>
#include <QApplication>
#include <QDirIterator>
#include <QFile>
#include <QJsonArray>
#include <QMenu>
#include <QTest>

using namespace ssmconnect;
using namespace ssmconnect::testing;

namespace {

class RecordingPlatform : public ShellPlatform {
public:
    QStringList calls;
    bool answer = true;
    int choice = 0;
    QString dcvViewerPath() const override { return QStringLiteral("/usr/bin/dcvviewer"); }
    void openUrl(const QString &url) override { calls << "open " + url; }
    void start(const QString &path, const QStringList &arguments) override { calls << "start " + path + ' ' + arguments.join(' '); }
    void setClipboard(const QString &text) override { calls << "clipboard " + text; }
    void notify(const QString &title, const QString &) override { calls << "notify " + title; }
    void showError(const QString &action, const QString &message) override { calls << QStringLiteral("error %1: %2").arg(action, message); }
    bool confirm(const QString &title, const QString &) override {
        calls << "confirm " + title;
        return answer;
    }
    int choose(const QString &title, const QString &, const QStringList &) override {
        calls << "choose " + title;
        return answer ? choice : -1;
    }
    QString chooseProfileFile() override { return QStringLiteral("/home/u/workstation.json"); }
    QString chooseFolder(const QString &) override { return QStringLiteral("/home/u/zen-profile"); }
    QString chooseSaveFile(const QString &) override { return QStringLiteral("/home/u/export.yaml"); }
    void reveal(const QString &path) override { calls << "reveal " + path; }
};

struct Entry {
    QString id, surface, command, cancelWorkflow, otherwise, offeredWhen, enabledWhen;
    QStringList commands;
    bool confirmation = false;
    QString confirmWhen;
    bool partOf = false;
};

QList<Entry> inventory() {
    QFile file(QStringLiteral(SSM_PARITY_INVENTORY));
    if (!file.open(QIODevice::ReadOnly)) qFatal("cannot read %s", SSM_PARITY_INVENTORY);
    QList<Entry> entries;
    for (const QJsonValue &value : QJsonDocument::fromJson(file.readAll()).object().value("entries").toArray()) {
        const QJsonObject object = value.toObject();
        const QJsonObject helper = object.value("helper").toObject();
        Entry entry;
        entry.id = object.value("id").toString();
        entry.surface = object.value("linux").toString().section(':', 0, 0);
        entry.command = helper.value("command").toString();
        for (const QJsonValue &command : helper.value("commands").toArray()) entry.commands << command.toString();
        entry.cancelWorkflow = helper.value("cancel").toObject().value("workflow").toString();
        entry.otherwise = helper.value("cancel").toObject().value("otherwise").toString();
        entry.partOf = helper.contains("part_of");
        entry.confirmation = object.contains("confirmation");
        entry.confirmWhen = object.value("confirmation").toObject().value("when").toString();
        entry.offeredWhen = object.value("offered_when").toString();
        entry.enabledWhen = object.value("enabled_when").toString();
        entries << entry;
    }
    return entries;
}

/// The inventory's rule syntax, evaluated independently of the shell.
bool truthy(const QString &value) { return !value.isEmpty() && value != "false" && value != "0"; }

bool clause(const QString &text, const QVariantMap &values) {
    QString c = text.trimmed();
    if (c.startsWith('!') && !c.contains('=')) return !truthy(values.value(c.mid(1)).toString());
    if (c.contains("!=")) {
        const QString key = c.section("!=", 0, 0), wanted = c.section("!=", 1);
        return !wanted.split('|').contains(values.value(key).toString());
    }
    if (c.contains('>')) return values.value(c.section('>', 0, 0)).toString().toInt() > c.section('>', 1).toInt();
    if (c.contains('=')) return c.section('=', 1).split('|').contains(values.value(c.section('=', 0, 0)).toString());
    return truthy(values.value(c).toString());
}

bool rule(const QString &text, const QVariantMap &values) {
    if (text.trimmed().isEmpty()) return true;
    for (const QString &alternative : text.split(" or ")) {
        bool all = true;
        for (const QString &part : alternative.split(" & ")) all = all && clause(part, values);
        if (all) return true;
    }
    return false;
}

/// Representative states: the helper's details, plus the shell context of the selected profile
/// and of a per-item control.
QList<QPair<QString, QVariantMap>> states() {
    const QVariantMap base{
        {"profiles", "2"}, {"authorization.status", "ready"}, {"desktop.state", "disconnected"}, {"desktop.maskedPassword", ""},
        {"editor.enabled", "true"}, {"editor.active", "false"}, {"editor.state", "idle"}, {"editor.setupInstalled", "true"},
        {"editor.replacement", ""}, {"web.enabled", "true"}, {"web.state", "Off"}, {"web.socks", "true"}, {"web.pac", "false"},
        {"web.browserMode", "separate"}, {"web.openingBrowser", "false"}, {"web.pendingChanges", "false"}, {"web.replacement", ""},
        {"selected", "true"}, {"selected.attached", "true"}, {"selected.pending", "false"}, {"item.active", "false"},
        {"item.openPath", "/"}, {"item.attached", "true"}, {"item.browserMode", "existing"}};
    QVariantMap connecting = base;
    connecting.insert("desktop.state", "tunneling");
    connecting.insert("authorization.status", "signInRequired");
    QVariantMap connected = base;
    for (auto [k, v] : std::initializer_list<std::pair<const char *, const char *>>{
             {"desktop.state", "connected"}, {"desktop.maskedPassword", "••••••"}, {"editor.active", "true"}, {"editor.state", "active"},
             {"web.state", "On"}, {"web.pac", "true"}, {"selected.pending", "true"}, {"web.browserMode", "existing"}})
        connected.insert(k, v);
    QVariantMap recovering = connected;
    for (auto [k, v] : std::initializer_list<std::pair<const char *, const char *>>{
             {"editor.state", "recovering"}, {"editor.replacement", R"({"id":"r1"})"}, {"web.replacement", R"({"id":"w1"})"},
             {"web.pendingChanges", "true"}, {"authorization.status", "unavailable"}, {"profiles", "0"}})
        recovering.insert(k, v);
    return {{"disconnected", base}, {"connecting", connecting}, {"connected", connected}, {"recovering", recovering}};
}

QJsonObject resultDone() { return QJsonObject{{"type", "result"}, {"outcome", "completed"}, {"value", QJsonObject{}}}; }

struct Rig {
    ManualClock clock;
    FakeSpawner spawner;
    std::unique_ptr<HelperHost> host;
    RecordingPlatform platform;
    std::unique_ptr<ShellController> controller;
    FakeHelper *helper = nullptr;

    explicit Rig(std::function<std::optional<QJsonObject>(const QString &)> onCommand = [](const QString &) { return resultDone(); }) {
        spawner.configure = [onCommand](FakeHelper &h) { h.onCommand = onCommand; };
        host = std::make_unique<HelperHost>(spawner, Build, limits(), clock);
        host->start();
        QTRY_COMPARE(host->status(), HelperHostStatus::Ready);
        helper = spawner.started[0];
        controller = std::make_unique<ShellController>(*host, platform);
    }

    void details(const QVariantMap &values) {
        QJsonObject fields;
        for (auto it = values.begin(); it != values.end(); ++it)
            if (!it.key().startsWith("selected") && !it.key().startsWith("item.")) fields.insert(it.key(), it.value().toString());
        helper->deliver({{"type", "event"}, {"sequence", ++sequence}, {"workflow", "details"}, {"name", "details"}, {"fields", fields}});
        QTRY_COMPARE(controller->details().value("desktop.state").toString(), values.value("desktop.state").toString());
    }

    QStringList commandsAfter(qsizetype start) const {
        QStringList names;
        for (size_t i = start; i < helper->receivedFrames.size(); ++i)
            if (helper->receivedFrames[i].value("type") == "command") names << helper->receivedFrames[i].value("name").toString();
        return names;
    }

    int sequence = 0;
};

const QVariantMap Arguments{{"id", "55555555-5555-4555-8555-555555555555"}, {"name", "Dashboard"}, {"path", "/home/u/workstation.json"}};

} // namespace

class ParityTest : public QObject {
    Q_OBJECT

private slots:
    void everyMacOSControlHasItsLinuxControl() {
        Rig rig;
        Tray tray(*rig.controller, [] {}, [] {}, [] {});
        QString qml;
        QDirIterator files(QStringLiteral(":/qml"), QDirIterator::Subdirectories);
        while (files.hasNext()) {
            QFile file(files.next());
            if (file.open(QIODevice::ReadOnly)) qml += QString::fromUtf8(file.readAll());
        }
        for (const Entry &entry : inventory()) {
            if (entry.partOf) continue;
            QVERIFY2(rig.controller->control(entry.id), qPrintable("no Linux control " + entry.id));
            if (entry.surface == "Confirmation dialog") {
                continue; // served by the platform's own dialogs (confirm, choose, showError)
            } else if (entry.surface == "Tray menu") {
                QVERIFY2(tray.menu()->findChild<QAction *>(entry.id), qPrintable("no tray item " + entry.id));
            } else {
                QVERIFY2(qml.contains('"' + entry.id + '"'), qPrintable("no QML control " + entry.id));
            }
        }
    }

    void everyCommandControlSendsItsCommandAfterMacOSConfirmation() {
        for (const Entry &entry : inventory()) {
            const QString expected = !entry.command.isEmpty() ? entry.command : !entry.otherwise.isEmpty() ? entry.otherwise : QString();
            if (expected.isEmpty() && entry.commands.isEmpty()) continue;
            QVariantMap state;
            for (const auto &[name, values] : states())
                if (rule(entry.offeredWhen, values) && rule(entry.enabledWhen, values)) { state = values; break; }
            QVERIFY2(!state.isEmpty(), qPrintable("no state offers " + entry.id));
            for (bool answer : {true, false}) {
                Rig rig;
                rig.details(state);
                rig.platform.answer = answer;
                const qsizetype start = qsizetype(rig.helper->receivedFrames.size());
                rig.controller->trigger(entry.id, Arguments, state);
                QTest::qWait(20);
                const QStringList sent = rig.commandsAfter(start);
                const bool asked = !rig.platform.calls.filter(QRegularExpression("^(confirm|choose) ")).isEmpty();
                const bool sentExpected = entry.commands.isEmpty() ? sent.contains(expected)
                                                                   : std::any_of(entry.commands.begin(), entry.commands.end(),
                                                                                 [&](const QString &c) { return sent.contains(c); });
                if (answer) QVERIFY2(sentExpected, qPrintable(entry.id + " sent " + sent.join(',')));
                if (entry.confirmation && rule(entry.confirmWhen, state)) {
                    QVERIFY2(asked || !answer, qPrintable(entry.id + " sent without macOS's confirmation"));
                    if (!answer && asked) QVERIFY2(!sentExpected, qPrintable(entry.id + " sent after its confirmation was declined"));
                }
            }
        }
    }

    void availabilityFollowsMacOS() {
        for (const auto &[name, values] : states()) {
            Rig rig;
            rig.details(values);
            for (const Entry &entry : inventory()) {
                if (entry.partOf) continue;
                const bool offered = rule(entry.offeredWhen, values);
                const bool enabled = offered && rule(entry.enabledWhen, values);
                QVERIFY2(rig.controller->isOffered(entry.id, values) == offered, qPrintable(entry.id + " offered in " + name));
                QVERIFY2(rig.controller->isEnabled(entry.id, values) == enabled, qPrintable(entry.id + " enabled in " + name));
                if (!enabled && (!entry.command.isEmpty() || !entry.otherwise.isEmpty() || !entry.commands.isEmpty())) {
                    const qsizetype start = qsizetype(rig.helper->receivedFrames.size());
                    rig.controller->trigger(entry.id, Arguments, values);
                    QTest::qWait(5);
                    QVERIFY2(rig.commandsAfter(start).isEmpty(), qPrintable(entry.id + " sent while unavailable in " + name));
                }
            }
        }
    }

    void cancelControlsCancelTheRunningCommandOfTheirWorkflow() {
        const QMap<QString, QString> running{{"desktop", "reconnect"}, {"editor", "reconnectWorkspace"}, {"web", "startWebForwards"}};
        for (const Entry &entry : inventory()) {
            if (entry.cancelWorkflow.isEmpty()) continue;
            QVariantMap state;
            for (const auto &[name, values] : states())
                if (rule(entry.offeredWhen, values) && rule(entry.enabledWhen, values)) { state = values; break; }
            QVERIFY2(!state.isEmpty(), qPrintable("no state offers " + entry.id));
            Rig rig([](const QString &name) -> std::optional<QJsonObject> {
                if (name == "reconnect" || name == "reconnectWorkspace" || name == "startWebForwards" || name == "connect") return std::nullopt;
                return resultDone();
            });
            rig.details(state);
            rig.platform.answer = true;
            HelperCommand *work = rig.controller->runCommand(running.value(entry.cancelWorkflow));
            QVERIFY(work && !work->isFinished());
            const qsizetype start = qsizetype(rig.helper->receivedFrames.size());
            rig.controller->trigger(entry.id, Arguments, state);
            QTRY_VERIFY2(work->isFinished(), qPrintable(entry.id + " did not cancel " + running.value(entry.cancelWorkflow)));
            QStringList cancelled;
            for (size_t i = start; i < rig.helper->receivedFrames.size(); ++i)
                if (rig.helper->receivedFrames[i].value("type") == "cancel") cancelled << rig.helper->receivedFrames[i].value("id").toString();
            QCOMPARE(cancelled.size(), 1);
            QCOMPARE(work->result().outcome, HelperOutcome::Cancelled);
            const bool otherworkCommands = !rig.commandsAfter(start).contains(entry.otherwise)
                                           || entry.otherwise == "stopRemoteAccess" || entry.otherwise == "restoreEditorSetup";
            QVERIFY2(otherworkCommands, qPrintable(entry.id + " sent its no-command form while a command ran"));
        }
    }

    void aCancelThatArrivesAfterTheCommandFinishedIsFollowedOnce() {
        Rig rig([](const QString &name) -> std::optional<QJsonObject> {
            if (name == "openEditor") return std::nullopt;
            return resultDone();
        });
        rig.helper->confirmsCancel = false;
        QVariantMap state = states()[3].second; // a replacement waits for review
        rig.details(state);
        HelperCommand *open = rig.controller->runCommand("openEditor");
        QVERIFY(open && !open->isFinished());
        QString openID;
        for (const auto &frame : rig.helper->receivedFrames)
            if (frame.value("type") == "command" && frame.value("name") == "openEditor") openID = frame.value("id").toString();
        rig.controller->trigger("menucontent-button-cancel-replacement-recovery", {}, state);
        QTRY_VERIFY(!rig.helper->receivedFrames.empty() && rig.helper->receivedFrames.back().value("type") == "cancel");
        // The helper had already finished Open VS Code: its result arrives as completed.
        rig.helper->deliver({{"type", "result"}, {"id", openID}, {"outcome", "completed"}, {"value", QJsonObject{}}});
        QTRY_VERIFY(open->isFinished());
        QTRY_COMPARE(rig.helper->commands().count("cancelEditorRecovery"), qsizetype(1));
        QTest::qWait(50);
        QCOMPARE(rig.helper->commands().count("cancelEditorRecovery"), qsizetype(1));
        QCOMPARE(rig.helper->commands().count("openEditor"), qsizetype(1));
        QCOMPARE(rig.helper->commands().count("connect"), qsizetype(0));
    }
};

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QApplication app(argc, argv);
    ParityTest test;
    return QTest::qExec(&test, argc, argv);
}

#include "parity_test.moc"
