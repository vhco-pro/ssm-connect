// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include <chrono>
#include <functional>
#include <map>

namespace ssmconnect {

/// Time for the host's limits, injectable so tests can move it by hand.
class HostClock {
public:
    virtual ~HostClock() = default;
    virtual qint64 nowMs() const = 0;
    /// Runs `action` once after `delay` on the event loop; returns an ID for cancel().
    virtual int schedule(std::chrono::milliseconds delay, std::function<void()> action) = 0;
    virtual void cancel(int id) = 0;
};

/// The real clock: monotonic time and Qt single-shot timers.
class SystemClock : public HostClock {
public:
    qint64 nowMs() const override;
    int schedule(std::chrono::milliseconds delay, std::function<void()> action) override;
    void cancel(int id) override;

private:
    int next = 1;
    std::map<int, QObject *> timers;
};

/// One running helper as the host sees it: frames out, frames in, and its end. The spawner that
/// created it owns it.
class HelperConnection : public QObject {
    Q_OBJECT
public:
    /// Writes one frame, a compact JSON object without its newline.
    virtual void send(const QByteArray &line) = 0;
signals:
    /// One frame the helper wrote.
    void received(const QByteArray &line);
    /// The helper ended; every frame it wrote has been received.
    void exited();
};

/// Starts helpers, each in its own container, and ends a container completely.
class HelperSpawner {
public:
    virtual ~HelperSpawner() = default;
    virtual HelperConnection *start() = 0;
    /// Ends every process in the helper's container and calls `done` once none remain.
    virtual void terminateAndWaitEmpty(HelperConnection *connection, std::function<void()> done) = 0;
};

struct HelperHostLimits {
    std::chrono::milliseconds handshake{std::chrono::seconds(10)};
    std::chrono::milliseconds heartbeat{std::chrono::seconds(15)};
    std::chrono::milliseconds cancelConfirmation{std::chrono::seconds(10)};
    std::chrono::milliseconds healthyRearm{std::chrono::minutes(10)};
};

enum class HelperHostStatus { Starting, Ready, Unavailable, Updated, Stopped };
enum class HelperOutcome { Completed, Failed, Cancelled, Rejected, CoreStopped };

struct HelperResult {
    HelperOutcome outcome = HelperOutcome::Failed;
    QString code;
    QString message;
    QVariantMap value;
};

class HelperHost;

/// A command sent to the helper: finished once, with its one terminal result.
class HelperCommand : public QObject {
    Q_OBJECT
public:
    bool isFinished() const { return finished_; }
    const HelperResult &result() const { return result_; }
    /// Asks the helper to cancel; a cancel it does not confirm in time replaces the helper.
    void cancel();
signals:
    void finished();

private:
    friend class HelperHost;
    HelperCommand(HelperHost *host, QString id) : host_(host), id_(std::move(id)) {}
    void finish(HelperResult result);
    HelperHost *host_;
    QString id_;
    bool finished_ = false;
    HelperResult result_;
};

/// The shell side of the helper protocol, with the same rules as the Windows host. It starts one
/// helper at a time in its own container, completes the build handshake within the handshake
/// limit, sends a heartbeat each interval and counts an unanswered one as a stop, and replaces a
/// helper that stopped once automatically: the old container is terminated and empty before the
/// replacement starts. The allowance returns after the replacement has run healthy for the re-arm
/// period, or when the user retries. Without an allowance, or when the first helper never
/// completes its handshake, the host shows "SSM Connect core unavailable" until Retry. In-flight
/// commands fail with "core stopped" when their helper stops and are never sent again. A helper of
/// another build is refused at handshake, and the host then asks the user to restart.
class HelperHost : public QObject {
    Q_OBJECT
public:
    static const QString UnavailableMessage;
    static const QString UpdatedMessage;

    HelperHost(HelperSpawner &spawner, QString build, HelperHostLimits limits, HostClock &clock, QObject *parent = nullptr);

    HelperHostStatus status() const { return status_; }
    QString statusMessage() const { return statusMessage_; }
    int automaticRestartsAvailable() const { return restartsAvailable_; }

    void start();
    /// Starts one new helper under the same rules, restoring the automatic restart.
    void retry();
    /// Sends a command; the returned command, owned by the host, finishes with one result.
    HelperCommand *send(const QString &name, const QVariantMap &arguments);
    /// Ends the helper for good: asks it to shut down, waits up to `grace` for it to exit, then
    /// ends its container and calls `done`. No replacement starts afterwards.
    void shutdown(std::chrono::milliseconds grace, std::function<void()> done);

signals:
    void statusChanged();
    void eventReceived(const QJsonObject &frame);

private:
    friend class HelperCommand;
    struct Pending {
        HelperCommand *command;
        HelperConnection *connection;
    };

    void launch();
    void handle(HelperConnection *connection, const QByteArray &line);
    void heartbeat(HelperConnection *connection);
    void cancel(const QString &id);
    void complete(const QString &id, HelperResult result);
    void stop(HelperConnection *connection);
    void write(HelperConnection *connection, const QJsonObject &frame);
    void setStatus(HelperHostStatus status, QString message);

    HelperSpawner &spawner_;
    QString build_;
    HelperHostLimits limits_;
    HostClock &clock_;
    HelperHostStatus status_ = HelperHostStatus::Starting;
    QString statusMessage_;
    int restartsAvailable_ = 1;
    HelperConnection *current_ = nullptr;
    QSet<HelperConnection *> stopped_;
    QSet<HelperConnection *> handshaken_;
    QSet<HelperConnection *> awaitingHandshake_;
    std::map<QString, Pending> pending_;
    int handshakeTimer_ = 0;
    int heartbeatTimer_ = 0;
    int heartbeatSent_ = 0;
    int heartbeatAnswered_ = 0;
    qint64 healthySince_ = 0;
    qint64 nextCommand_ = 0;
    bool shuttingDown_ = false;
    std::function<void()> shutdownDone_;
};

} // namespace ssmconnect
