// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "helper_host.h"

#include <QElapsedTimer>
#include <QJsonDocument>
#include <QTimer>

namespace ssmconnect {

const QString HelperHost::UnavailableMessage = QStringLiteral("SSM Connect core unavailable");
const QString HelperHost::UpdatedMessage = QStringLiteral("SSM Connect was updated; restart it.");

// MARK: SystemClock

qint64 SystemClock::nowMs() const {
    static QElapsedTimer started = [] {
        QElapsedTimer timer;
        timer.start();
        return timer;
    }();
    return started.elapsed();
}

int SystemClock::schedule(std::chrono::milliseconds delay, std::function<void()> action) {
    const int id = next++;
    auto *timer = new QTimer;
    timer->setSingleShot(true);
    QObject::connect(timer, &QTimer::timeout, timer, [this, id, timer, action = std::move(action)] {
        timers.erase(id);
        timer->deleteLater();
        action();
    });
    timers[id] = timer;
    timer->start(delay);
    return id;
}

void SystemClock::cancel(int id) {
    auto found = timers.find(id);
    if (found == timers.end()) return;
    found->second->deleteLater();
    timers.erase(found);
}

// MARK: HelperCommand

void HelperCommand::cancel() {
    if (!finished_) host_->cancel(id_);
}

void HelperCommand::finish(HelperResult result) {
    if (finished_) return;
    finished_ = true;
    result_ = std::move(result);
    emit finished();
}

// MARK: HelperHost

HelperHost::HelperHost(HelperSpawner &spawner, QString build, HelperHostLimits limits, HostClock &clock, QObject *parent)
    : QObject(parent), spawner_(spawner), build_(std::move(build)), limits_(limits), clock_(clock) {}

void HelperHost::start() { launch(); }

void HelperHost::retry() {
    if (shuttingDown_ || status_ == HelperHostStatus::Ready || status_ == HelperHostStatus::Updated) return;
    restartsAvailable_ = 1;
    launch();
}

void HelperHost::launch() {
    setStatus(HelperHostStatus::Starting, {});
    HelperConnection *connection = spawner_.start();
    current_ = connection;
    heartbeatSent_ = 0;
    heartbeatAnswered_ = 0;
    awaitingHandshake_.insert(connection);
    connect(connection, &HelperConnection::received, this, [this, connection](const QByteArray &line) { handle(connection, line); });
    connect(connection, &HelperConnection::exited, this, [this, connection] { stop(connection); });
    // The handshake limit runs from before the hello is written.
    clock_.cancel(handshakeTimer_);
    handshakeTimer_ = clock_.schedule(limits_.handshake, [this, connection] {
        if (awaitingHandshake_.contains(connection)) stop(connection);
    });
    write(connection, {{"type", "hello"}, {"build", build_}, {"protocolVersion", 1}});
}

void HelperHost::handle(HelperConnection *connection, const QByteArray &line) {
    const QJsonObject frame = QJsonDocument::fromJson(line).object();
    const QString type = frame.value("type").toString();
    if (type == "welcome" || type == "refused") {
        if (!awaitingHandshake_.remove(connection)) return;
        if (connection == current_) clock_.cancel(handshakeTimer_);
        if (current_ != connection || stopped_.contains(connection)) return;
        if (type == "welcome") {
            handshaken_.insert(connection);
            healthySince_ = clock_.nowMs();
            setStatus(HelperHostStatus::Ready, {});
            clock_.cancel(heartbeatTimer_);
            heartbeatTimer_ = clock_.schedule(limits_.heartbeat, [this, connection] { heartbeat(connection); });
        } else if (frame.value("reason").toString() == "differentBuild") {
            setStatus(HelperHostStatus::Updated, UpdatedMessage);
            stop(connection);
        } else {
            stop(connection);
        }
    } else if (type == "heartbeat") {
        if (current_ == connection && frame.value("sequence").toInt() == heartbeatSent_) heartbeatAnswered_ = heartbeatSent_;
    } else if (type == "rejected") {
        const QJsonObject error = frame.value("error").toObject();
        complete(frame.value("id").toString(),
                 {HelperOutcome::Rejected, error.value("code").toString(), error.value("message").toString(), {}});
    } else if (type == "result") {
        QVariantMap value;
        const QJsonObject values = frame.value("value").toObject();
        for (auto it = values.begin(); it != values.end(); ++it) value.insert(it.key(), it.value().toString());
        const QString outcome = frame.value("outcome").toString();
        const QJsonObject error = frame.value("error").toObject();
        HelperResult result{outcome == "completed" ? HelperOutcome::Completed
                            : outcome == "cancelled" ? HelperOutcome::Cancelled
                                                     : HelperOutcome::Failed,
                            error.value("code").toString(), error.value("message").toString(), value};
        complete(frame.value("id").toString(), result);
    } else if (type == "event") {
        emit eventReceived(frame);
    }
}

void HelperHost::heartbeat(HelperConnection *connection) {
    heartbeatTimer_ = 0;
    if (current_ != connection || status_ != HelperHostStatus::Ready) return;
    const bool missed = heartbeatSent_ != heartbeatAnswered_;
    if (!missed && restartsAvailable_ == 0 && clock_.nowMs() - healthySince_ >= limits_.healthyRearm.count())
        restartsAvailable_ = 1;
    if (missed) {
        stop(connection);
        return;
    }
    write(connection, {{"type", "heartbeat"}, {"sequence", ++heartbeatSent_}});
    heartbeatTimer_ = clock_.schedule(limits_.heartbeat, [this, connection] { heartbeat(connection); });
}

HelperCommand *HelperHost::send(const QString &name, const QVariantMap &arguments) {
    const QString id = QStringLiteral("c%1").arg(++nextCommand_);
    auto *command = new HelperCommand(this, id);
    command->setParent(this);
    if (status_ != HelperHostStatus::Ready || !current_) {
        command->finish({HelperOutcome::Rejected, "unavailable",
                         statusMessage_.isEmpty() ? UnavailableMessage : statusMessage_, {}});
        return command;
    }
    pending_[id] = {command, current_};
    QJsonObject argumentObject;
    for (auto it = arguments.begin(); it != arguments.end(); ++it) argumentObject.insert(it.key(), it.value().toString());
    write(current_, {{"type", "command"}, {"id", id}, {"name", name}, {"arguments", argumentObject}});
    return command;
}

void HelperHost::cancel(const QString &id) {
    auto found = pending_.find(id);
    if (found == pending_.end()) return;
    HelperConnection *connection = found->second.connection;
    write(connection, {{"type", "cancel"}, {"id", id}});
    clock_.schedule(limits_.cancelConfirmation, [this, id, connection] {
        if (pending_.count(id)) stop(connection);
    });
}

void HelperHost::complete(const QString &id, HelperResult result) {
    auto found = pending_.find(id);
    if (found == pending_.end()) return;
    HelperCommand *command = found->second.command;
    pending_.erase(found);
    command->finish(std::move(result));
}

void HelperHost::stop(HelperConnection *connection) {
    if (stopped_.contains(connection)) return;
    stopped_.insert(connection);
    awaitingHandshake_.remove(connection);
    std::vector<HelperCommand *> failed;
    for (auto it = pending_.begin(); it != pending_.end();) {
        if (it->second.connection == connection) {
            failed.push_back(it->second.command);
            it = pending_.erase(it);
        } else {
            ++it;
        }
    }
    const bool isCurrent = current_ == connection;
    if (isCurrent) {
        clock_.cancel(heartbeatTimer_);
        clock_.cancel(handshakeTimer_);
        heartbeatTimer_ = handshakeTimer_ = 0;
    }
    // Only a helper that completed its handshake earns the automatic replacement: a first helper,
    // or a replacement, that never handshakes leads straight to "unavailable".
    const bool restart = isCurrent && !shuttingDown_ && status_ != HelperHostStatus::Updated && restartsAvailable_ > 0
                         && handshaken_.contains(connection);
    if (restart) --restartsAvailable_;
    if (isCurrent && status_ != HelperHostStatus::Updated)
        setStatus(shuttingDown_ ? HelperHostStatus::Stopped : HelperHostStatus::Starting, {});
    for (HelperCommand *command : failed)
        command->finish({HelperOutcome::CoreStopped, "coreStopped", "core stopped", {}});
    spawner_.terminateAndWaitEmpty(connection, [this, connection, restart] {
        // The spawner frees the connection once its unit is empty, and a later helper can be given
        // the same address: forget this one so that helper is not taken for it.
        stopped_.remove(connection);
        handshaken_.remove(connection);
        awaitingHandshake_.remove(connection);
        if (current_ != connection) return;
        if (shuttingDown_) {
            if (auto done = std::exchange(shutdownDone_, nullptr)) done();
            return;
        }
        if (restart) launch();
        else if (status_ != HelperHostStatus::Updated) setStatus(HelperHostStatus::Unavailable, UnavailableMessage);
    });
}

void HelperHost::shutdown(std::chrono::milliseconds grace, std::function<void()> done) {
    shuttingDown_ = true;
    clock_.cancel(heartbeatTimer_);
    heartbeatTimer_ = 0;
    HelperConnection *connection = current_;
    if (!connection || stopped_.contains(connection)) {
        if (status_ != HelperHostStatus::Updated) setStatus(HelperHostStatus::Stopped, {});
        done();
        return;
    }
    shutdownDone_ = std::move(done);
    write(connection, {{"type", "shutdown"}});
    // The helper's exit stops it at once; otherwise the grace period does.
    clock_.schedule(grace, [this, connection] { stop(connection); });
}

void HelperHost::write(HelperConnection *connection, const QJsonObject &frame) {
    connection->send(QJsonDocument(frame).toJson(QJsonDocument::Compact));
}

void HelperHost::setStatus(HelperHostStatus status, QString message) {
    status_ = status;
    statusMessage_ = std::move(message);
    emit statusChanged();
}

} // namespace ssmconnect
