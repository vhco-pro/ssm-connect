// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// Tests for the Linux helper host (T23, AC-18, AC-27). The first suite drives the host's rules with
// a fake spawner and a manual clock, as the Windows host's tests do: the handshake, the build
// refusal, heartbeats, the one automatic restart and its re-arm, "core stopped" for in-flight
// commands, cancellation and shutdown. The second suite runs against the user's systemd instance:
// the helper as the main process of a transient user service bound to the shell's scope, a scope
// created when the shell has none, stopping and waiting for an empty unit, the unit ending with its
// shell even when the helper is stopped, single instance, and user applications in their own
// transient scopes. It is skipped where no systemd user instance is reachable.

#include <algorithm>
#include "fakes.h"
#include "helper_host.h"
#include "single_instance.h"
#include "systemd_containment.h"
#include "user_applications.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QSignalSpy>
#include <QTest>
#include <QUuid>

#include <csignal>
#include <map>
#include <memory>
#include <vector>

using namespace ssmconnect;
using namespace std::chrono_literals;

using namespace ssmconnect::testing;

class HelperHostTest : public QObject {
    Q_OBJECT

private slots:
    void handshakeCompletesAndCommandsGetOneTerminalResult() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) {
            helper.onCommand = [](const QString &) { return completed({{"state", "connected"}}); };
        };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        auto *command = host.send("connect", {});
        QTRY_VERIFY(command->isFinished());
        QCOMPARE(command->result().outcome, HelperOutcome::Completed);
        QCOMPARE(command->result().value.value("state").toString(), QStringLiteral("connected"));
        const QJsonObject hello = spawner.started.at(0)->receivedFrames.front();
        QCOMPARE(hello.value("type").toString(), QStringLiteral("hello"));
        QCOMPARE(hello.value("build").toString(), Build);
        QCOMPARE(hello.value("protocolVersion").toInt(), 1);
    }

    void aBuildMismatchShowsTheUpdatedMessageAndStartsNoReplacement() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.helperBuild = "build-2"; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Updated);
        QCOMPARE(host.statusMessage(), QStringLiteral("SSM Connect was updated; restart it."));
        QTest::qWait(100);
        QCOMPARE(spawner.started.size(), size_t(1));
    }

    void aFirstHelperThatNeverHandshakesLeadsToUnavailableWithoutARestart() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.handshakes = false; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_VERIFY(!spawner.started.empty() && !spawner.started[0]->receivedFrames.empty());
        clock.advance(11s);
        QTRY_COMPARE(host.status(), HelperHostStatus::Unavailable);
        QCOMPARE(host.statusMessage(), QStringLiteral("SSM Connect core unavailable"));
        QCOMPARE(spawner.log, QStringList({"start 1", "terminate 1", "empty 1"}));
    }

    // A connection the spawner frees once its unit is empty can be followed by one at the same
    // address; the host must treat it as a new helper, with its own handshake limit.
    void aNewHelperAtAFreedHelpersAddressGetsItsOwnHandshake() {
        struct ReusingSpawner : FakeSpawner {
            FakeHelper *freed = nullptr;
            HelperConnection *start() override {
                if (!freed) return FakeSpawner::start();
                FakeHelper *helper = std::exchange(freed, nullptr);
                helper->hasExited = false;
                helper->receivedFrames.clear();
                configure(*helper);
                started.push_back(helper);
                log << QStringLiteral("start %1").arg(started.size());
                return helper;
            }
            void terminateAndWaitEmpty(HelperConnection *connection, std::function<void()> done) override {
                FakeSpawner::terminateAndWaitEmpty(connection, std::move(done));
                freed = static_cast<FakeHelper *>(connection);
            }
        };
        ManualClock clock;
        ReusingSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.handshakes = false; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_VERIFY(!spawner.started.empty() && !spawner.started[0]->receivedFrames.empty());
        clock.advance(11s);
        QTRY_COMPARE(host.status(), HelperHostStatus::Unavailable);
        host.retry();
        QCOMPARE(spawner.started.size(), size_t(2));
        QCOMPARE(spawner.started[1], spawner.started[0]);
        clock.advance(11s);
        QTRY_COMPARE(host.status(), HelperHostStatus::Unavailable);
        spawner.configure = [](FakeHelper &helper) { helper.handshakes = true; };
        host.retry();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
    }

    void oneAutomaticRestartEmptiesTheOldUnitFirstThenRetryStartsAnother() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        spawner.started[0]->exit();
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
        QCOMPARE(spawner.log, QStringList({"start 1", "terminate 1", "empty 1", "start 2"}));
        spawner.started[1]->exit();
        QTRY_COMPARE(host.status(), HelperHostStatus::Unavailable);
        QTest::qWait(100);
        QCOMPARE(spawner.started.size(), size_t(2));
        host.retry();
        QTRY_VERIFY(spawner.started.size() == 3 && host.status() == HelperHostStatus::Ready);
    }

    void tenHealthyMinutesReArmTheAutomaticRestart() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        spawner.started[0]->exit();
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
        QCOMPARE(host.automaticRestartsAvailable(), 0);
        for (int i = 0; i < 41; ++i) clock.advance(15s);
        QTRY_COMPARE(host.automaticRestartsAvailable(), 1);
    }

    void aMissedHeartbeatCountsAsStopped() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [&](FakeHelper &helper) { helper.answersHeartbeats = spawner.started.size() > 0; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        clock.advance(15s);
        clock.advance(15s);
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
        QCOMPARE(spawner.log.mid(0, 3), QStringList({"start 1", "terminate 1", "empty 1"}));
    }

    void anInFlightCommandFailsWithCoreStoppedAndIsNeverResent() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        auto *command = host.send("connect", {});
        QTRY_COMPARE(spawner.started[0]->commands(), QStringList({"connect"}));
        spawner.started[0]->exit();
        QTRY_VERIFY(command->isFinished());
        QCOMPARE(command->result().outcome, HelperOutcome::CoreStopped);
        QCOMPARE(command->result().message, QStringLiteral("core stopped"));
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
        QTest::qWait(100);
        QVERIFY(spawner.started[1]->commands().isEmpty());
    }

    void aConfirmedCancelEndsTheCommandAsCancelled() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        auto *command = host.send("connect", {});
        QTRY_COMPARE(spawner.started[0]->commands(), QStringList({"connect"}));
        command->cancel();
        QTRY_VERIFY(command->isFinished());
        QCOMPARE(command->result().outcome, HelperOutcome::Cancelled);
        QCOMPARE(spawner.started.size(), size_t(1));
    }

    void aCancelNotConfirmedWithinTenSecondsReplacesTheHelper() {
        ManualClock clock;
        FakeSpawner spawner;
        spawner.configure = [](FakeHelper &helper) { helper.confirmsCancel = false; };
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        auto *command = host.send("connect", {});
        QTRY_COMPARE(spawner.started[0]->commands(), QStringList({"connect"}));
        command->cancel();
        QTRY_VERIFY(spawner.started[0]->receivedType("cancel"));
        clock.advance(9s);
        QVERIFY(!command->isFinished());
        clock.advance(2s);
        QTRY_VERIFY(command->isFinished());
        QCOMPARE(command->result().outcome, HelperOutcome::CoreStopped);
        QTRY_VERIFY(spawner.started.size() == 2 && host.status() == HelperHostStatus::Ready);
    }

    void shutdownAsksTheHelperToEndThenEmptiesItsUnitAndStartsNoReplacement() {
        ManualClock clock;
        FakeSpawner spawner;
        HelperHost host(spawner, Build, limits(), clock);
        host.start();
        QTRY_COMPARE(host.status(), HelperHostStatus::Ready);
        bool done = false;
        host.shutdown(5s, [&] { done = true; });
        QTRY_VERIFY(done);
        QVERIFY(spawner.started[0]->receivedType("shutdown"));
        QCOMPARE(host.status(), HelperHostStatus::Stopped);
        host.retry();
        QTest::qWait(100);
        QCOMPARE(spawner.log, QStringList({"start 1", "terminate 1", "empty 1"}));
    }
};

namespace {

/// Runs systemctl --user and returns its standard output.
QString systemctl(const QStringList &arguments) {
    QProcess process;
    process.start("systemctl", QStringList{"--user"} + arguments);
    process.waitForFinished(15000);
    return QString::fromUtf8(process.readAllStandardOutput()).trimmed();
}

QString unitProperty(const QString &unit, const QString &name) {
    return systemctl({"show", unit, "--property=" + name, "--value"});
}

bool unitGone(const QString &unit) {
    const QString state = unitProperty(unit, "ActiveState");
    return state.isEmpty() || state == "inactive" || state == "failed";
}

bool processAlive(qint64 pid) {
    return pid > 0 && ::kill(pid_t(pid), 0) == 0;
}

QString unitOf(qint64 pid) {
    QFile cgroup(QStringLiteral("/proc/%1/cgroup").arg(pid));
    if (!cgroup.open(QIODevice::ReadOnly)) return {};
    return QString::fromUtf8(cgroup.readAll()).trimmed().section('/', -1);
}

bool systemdUserAvailable() {
    QProcess process;
    process.start("systemctl", {"--user", "is-system-running"});
    process.waitForFinished(5000);
    const QString state = QString::fromUtf8(process.readAllStandardOutput()).trimmed();
    return state == "running" || state == "degraded";
}

} // namespace

class SystemdContainmentTest : public QObject {
    Q_OBJECT

private slots:
    void init() {
        if (!systemdUserAvailable()) QSKIP("no systemd user instance is reachable");
    }

    void theHelperIsTheMainProcessOfATransientServiceBoundToTheShellScope() {
        const QString scope = ensureOwnScope();
        QVERIFY2(scope.endsWith(".scope"), qPrintable(scope));
        SystemdHelperSpawner spawner(FAKE_HELPER_PATH, scope, {});
        auto *connection = spawner.start();
        QSignalSpy started(connection, &HelperConnection::received);
        QVERIFY(started.wait(10000));
        const qint64 helper = QJsonDocument::fromJson(started.at(0).at(0).toByteArray()).object()
                                  .value("fields").toObject().value("helper").toString().toLongLong();
        const QString unit = spawner.unitFor(connection);
        QVERIFY2(unit.startsWith("ssm-connect-helper-") && unit.endsWith(".service"), qPrintable(unit));
        QCOMPARE(unitProperty(unit, "ActiveState"), QStringLiteral("active"));
        QCOMPARE(unitProperty(unit, "MainPID").toLongLong(), helper);
        QVERIFY(unitProperty(unit, "BindsTo").split(' ').contains(scope));
        QVERIFY(unitProperty(unit, "After").split(' ').contains(scope));
        QCOMPARE(unitOf(helper), unit);
        connection->send(R"({"type":"hello","build":"test-build","protocolVersion":1})");
        QVERIFY(started.wait(10000));
        QCOMPARE(QJsonDocument::fromJson(started.last().at(0).toByteArray()).object().value("type").toString(), QStringLiteral("welcome"));
        bool empty = false;
        spawner.terminateAndWaitEmpty(connection, [&] { empty = true; });
        QTRY_VERIFY_WITH_TIMEOUT(empty, 15000);
        QVERIFY(unitGone(unit));
        QVERIFY(!processAlive(helper));
    }

    // The host writes its hello as soon as it has started the helper, before the process is running.
    void aHelloSentRightAfterStartReachesTheHelper() {
        SystemdHelperSpawner spawner(FAKE_HELPER_PATH, ensureOwnScope(), {});
        auto *connection = spawner.start();
        QSignalSpy received(connection, &HelperConnection::received);
        connection->send(R"({"type":"hello","build":"test-build","protocolVersion":1})");
        QTRY_VERIFY_WITH_TIMEOUT(std::any_of(received.cbegin(), received.cend(), [](const QList<QVariant> &frame) {
            return QJsonDocument::fromJson(frame.at(0).toByteArray()).object().value("type").toString() == "welcome";
        }), 10000);
        bool empty = false;
        spawner.terminateAndWaitEmpty(connection, [&] { empty = true; });
        QTRY_VERIFY_WITH_TIMEOUT(empty, 15000);
    }

    void aShellOutsideAScopeCreatesItsOwnScope() {
        QProcess probe;
        probe.start("systemd-run", {"--user", "--wait", "--pipe", "--quiet", "--collect", SCOPE_PROBE_PATH, "ensure-scope"});
        QVERIFY(probe.waitForFinished(30000));
        const QStringList words = QString::fromUtf8(probe.readAllStandardOutput()).trimmed().split(' ');
        QCOMPARE(probe.exitCode(), 0);
        QCOMPARE(words.size(), qsizetype(2));
        QVERIFY2(words[0].startsWith("app-ssm-connect-") && words[0].endsWith(".scope"), qPrintable(words[0]));
        QCOMPARE(words[1], words[0]);
    }

    void stoppingTheUnitEndsEveryDescendantBeforeItReportsEmpty() {
        SystemdHelperSpawner spawner(FAKE_HELPER_PATH, ensureOwnScope(), {"--spawn-child"});
        auto *connection = spawner.start();
        QSignalSpy started(connection, &HelperConnection::received);
        QVERIFY(started.wait(10000));
        const QJsonObject fields = QJsonDocument::fromJson(started.at(0).at(0).toByteArray()).object().value("fields").toObject();
        const qint64 child = fields.value("pid").toString().toLongLong();
        const qint64 helper = fields.value("helper").toString().toLongLong();
        QVERIFY(processAlive(child));
        QCOMPARE(unitOf(child), spawner.unitFor(connection));
        bool empty = false;
        spawner.terminateAndWaitEmpty(connection, [&] { empty = true; });
        QTRY_VERIFY_WITH_TIMEOUT(empty, 15000);
        QVERIFY(!processAlive(child));
        QVERIFY(!processAlive(helper));
    }

    void killingTheShellEndsItsHelperUnitEvenWhenTheHelperIsStopped() {
        const QString shellScope = QStringLiteral("ssm-connect-test-shell-%1").arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
        QProcess shell;
        shell.start("systemd-run", {"--user", "--scope", "--quiet", "--unit=" + shellScope, SCOPE_PROBE_PATH, "shell", FAKE_HELPER_PATH});
        QVERIFY(shell.waitForReadyRead(15000));
        const QStringList words = QString::fromUtf8(shell.readLine()).trimmed().split(' ');
        QCOMPARE(words.size(), qsizetype(2));
        const QString unit = words[0];
        const qint64 helper = words[1].toLongLong();
        QVERIFY(unitProperty(unit, "BindsTo").split(' ').contains(shellScope + ".scope"));
        QVERIFY(::kill(pid_t(helper), SIGSTOP) == 0);
        shell.kill();
        shell.waitForFinished(5000);
        QTRY_VERIFY_WITH_TIMEOUT(unitGone(unit) && !processAlive(helper), 10000);
    }

    void aSecondInstanceActivatesTheFirst() {
        const QString name = QStringLiteral("pro.vhco.SSMConnectTest.i%1").arg(QUuid::createUuid().toString(QUuid::Id128));
        auto first = SingleInstance::tryAcquire(name);
        QVERIFY(first);
        QSignalSpy activated(first.get(), &SingleInstance::activated);
        auto second = SingleInstance::tryAcquire(name);
        QVERIFY(!second);
        QVERIFY(activated.wait(5000));
    }

    void userApplicationsRunInTheirOwnTransientScopes() {
        const auto launched = UserApplications::launch("sleep", {"30"});
        QVERIFY2(launched.pid > 0, qPrintable(launched.unit));
        QVERIFY2(launched.unit.startsWith("app-ssm-connect-") && launched.unit.endsWith(".scope"), qPrintable(launched.unit));
        QTRY_COMPARE_WITH_TIMEOUT(unitOf(launched.pid), launched.unit, 10000);
        // Outside any helper unit: stopping every helper unit leaves it running.
        QVERIFY(!unitOf(launched.pid).startsWith("ssm-connect-helper-"));
        ::kill(pid_t(launched.pid), SIGTERM);
    }
};

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    int status = 0;
    HelperHostTest host;
    status |= QTest::qExec(&host, argc, argv);
    SystemdContainmentTest containment;
    status |= QTest::qExec(&containment, argc, argv);
    return status;
}

#include "helper_host_test.moc"
