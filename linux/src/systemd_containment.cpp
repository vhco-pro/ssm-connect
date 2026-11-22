// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "systemd_containment.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QProcess>
#include <QThread>
#include <QTimer>
#include <QUuid>

#include <csignal>
#include <sys/prctl.h>
#include <unistd.h>

namespace ssmconnect {

namespace {

QString uuid() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }

/// Runs a systemd tool to completion and returns its standard output, or nothing on failure.
QString run(const QString &program, const QStringList &arguments, int timeoutMs = 15000) {
    QProcess process;
    process.start(program, arguments);
    if (!process.waitForFinished(timeoutMs) || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) return {};
    return QString::fromUtf8(process.readAllStandardOutput()).trimmed();
}

/// A helper running under `systemd-run --pipe`: frames go to its standard input and come back,
/// one per line, from its standard output. It ends when systemd-run reports the service gone.
class PipeConnection : public HelperConnection {
public:
    explicit PipeConnection(QProcess *process) : process_(process) {
        process_->setParent(this);
        connect(process_, &QProcess::readyReadStandardOutput, this, [this] { drain(); });
        connect(process_, &QProcess::finished, this, [this] { end(); });
        connect(process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart) end();
        });
    }

    void send(const QByteArray &line) override {
        if (process_->state() == QProcess::Running) process_->write(line + '\n');
    }

    void end() {
        if (ended_) return;
        ended_ = true;
        drain();
        emit exited();
    }

private:
    void drain() {
        buffer_ += process_->readAllStandardOutput();
        qsizetype newline;
        while ((newline = buffer_.indexOf('\n')) >= 0) {
            const QByteArray line = buffer_.left(newline).trimmed();
            buffer_.remove(0, newline + 1);
            // The protocol's frame limit: a longer line is not a frame.
            if (!line.isEmpty() && line.size() <= 1024 * 1024) emit received(line);
        }
        if (buffer_.size() > 1024 * 1024) buffer_.clear();
    }

    QProcess *process_;
    QByteArray buffer_;
    bool ended_ = false;
};

} // namespace

QString currentUnit() {
    QFile cgroup(QStringLiteral("/proc/self/cgroup"));
    if (!cgroup.open(QIODevice::ReadOnly)) return {};
    // cgroup v2: a single "0::/user.slice/.../<unit>" line.
    return QString::fromUtf8(cgroup.readAll()).trimmed().section('/', -1);
}

QString ensureOwnScope() {
    const QString unit = currentUnit();
    if (unit.endsWith(QStringLiteral(".scope"))) return unit;
    const QString scope = QStringLiteral("app-ssm-connect-%1.scope").arg(uuid());
    // Manager.StartTransientUnit(name, mode, properties a(sv), aux a(sa(sv))) with this process.
    const QString job = run(QStringLiteral("busctl"),
                            {"--user", "call", "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
                             "org.freedesktop.systemd1.Manager", "StartTransientUnit", "ssa(sv)a(sa(sv))", scope, "fail",
                             "2", "PIDs", "au", "1", QString::number(getpid()), "Description", "s", "SSM Connect", "0"});
    if (job.isEmpty()) return {};
    // systemd moves the process when the job runs, which is immediate for a scope.
    QElapsedTimer waited;
    waited.start();
    while (currentUnit() != scope && waited.elapsed() < 5000) QThread::msleep(20);
    return currentUnit() == scope ? scope : QString();
}

SystemdHelperSpawner::SystemdHelperSpawner(QString helperPath, QString shellScope, QStringList arguments, QObject *parent)
    : QObject(parent), helperPath_(std::move(helperPath)), shellScope_(std::move(shellScope)), arguments_(std::move(arguments)) {}

HelperConnection *SystemdHelperSpawner::start() {
    const QString unit = QStringLiteral("ssm-connect-helper-%1.service").arg(uuid());
    auto *process = new QProcess;
    // Diagnostics go to the shell's own standard error, never into the protocol stream.
    process->setProcessChannelMode(QProcess::ForwardedErrorChannel);
    // systemd-run stays in the shell's scope while it waits for the service. It must end with the
    // shell, or a killed shell's scope would never empty and a hung helper would outlive it.
    process->setChildProcessModifier([] { prctl(PR_SET_PDEATHSIG, SIGKILL); });
    QStringList arguments{"--user", "--pipe", "--quiet", "--collect", "--unit=" + unit,
                          "--description=SSM Connect helper",
                          "--property=BindsTo=" + shellScope_, "--property=After=" + shellScope_,
                          // A hung helper gets SIGTERM, then SIGKILL five seconds later.
                          "--property=TimeoutStopSec=5", "--", helperPath_};
    arguments += arguments_;
    auto *connection = new PipeConnection(process);
    connection->setParent(this);
    units_.insert(connection, unit);
    process->start(QStringLiteral("systemd-run"), arguments);
    return connection;
}

void SystemdHelperSpawner::terminateAndWaitEmpty(HelperConnection *connection, std::function<void()> done) {
    const QString unit = units_.value(connection);
    auto *stop = new QProcess(this);
    // systemctl stop waits for the stop job: SIGTERM to every process in the unit, SIGKILL after
    // TimeoutStopSec. The unit then reports inactive, or is gone once collected.
    connect(stop, &QProcess::finished, this, [this, stop, unit, connection, done = std::move(done)] {
        stop->deleteLater();
        auto *poll = new QTimer(this);
        poll->setInterval(100);
        auto check = [this, poll, unit, connection, done] {
            const QString state = run(QStringLiteral("systemctl"), {"--user", "show", unit, "--property=ActiveState", "--value"}, 5000);
            if (!state.isEmpty() && state != "inactive" && state != "failed") return;
            poll->stop();
            poll->deleteLater();
            static_cast<PipeConnection *>(connection)->end();
            units_.remove(connection);
            connection->deleteLater();
            done();
        };
        connect(poll, &QTimer::timeout, this, check);
        poll->start();
    });
    stop->start(QStringLiteral("systemctl"), {"--user", "stop", unit});
}

} // namespace ssmconnect
