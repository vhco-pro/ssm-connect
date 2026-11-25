// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// Test doubles shared by the helper host and shell tests: a manual clock, an in-process helper
// that speaks the protocol, and a spawner that records container operations.
#pragma once

#include "helper_host.h"

#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>

#include <map>
#include <optional>
#include <vector>

using namespace std::chrono_literals;

namespace ssmconnect::testing {

inline const QString Build = QStringLiteral("build-1");

inline HelperHostLimits limits() {
    return HelperHostLimits{10s, 15s, 10s, 10min};
}

/// A clock whose time moves only when a test advances it.
class ManualClock : public HostClock {
public:
    qint64 nowMs() const override { return now; }
    int schedule(std::chrono::milliseconds delay, std::function<void()> action) override {
        int id = next++;
        timers[id] = {now + delay.count(), std::move(action)};
        return id;
    }
    void cancel(int id) override { timers.erase(id); }
    void advance(std::chrono::milliseconds by) {
        const qint64 target = now + by.count();
        while (true) {
            auto due = timers.end();
            for (auto it = timers.begin(); it != timers.end(); ++it)
                if (it->second.first <= target && (due == timers.end() || it->second.first < due->second.first)) due = it;
            if (due == timers.end()) break;
            now = due->second.first;
            auto action = std::move(due->second.second);
            timers.erase(due);
            action();
            QCoreApplication::processEvents();
        }
        now = target;
        QCoreApplication::processEvents();
    }

private:
    qint64 now = 0;
    int next = 1;
    std::map<int, std::pair<qint64, std::function<void()>>> timers;
};

/// An in-process helper that speaks the protocol and records what it received.
class FakeHelper : public HelperConnection {
public:
    QString helperBuild = Build;
    bool handshakes = true;
    bool answersHeartbeats = true;
    bool confirmsCancel = true;
    std::function<std::optional<QJsonObject>(const QString &)> onCommand = [](const QString &) { return std::nullopt; };
    std::vector<QJsonObject> receivedFrames;
    bool hasExited = false;

    void send(const QByteArray &line) override {
        if (hasExited) return;
        const QJsonObject frame = QJsonDocument::fromJson(line).object();
        receivedFrames.push_back(frame);
        const QString type = frame.value("type").toString();
        if (type == "hello" && handshakes) {
            if (frame.value("build").toString() == helperBuild) reply({{"type", "welcome"}, {"build", helperBuild}});
            else {
                reply({{"type", "refused"}, {"reason", "differentBuild"}});
                exitLater();
            }
        } else if (type == "heartbeat" && answersHeartbeats) {
            reply({{"type", "heartbeat"}, {"sequence", frame.value("sequence")}});
        } else if (type == "command") {
            const QString id = frame.value("id").toString();
            reply({{"type", "accepted"}, {"id", id}});
            if (auto result = onCommand(frame.value("name").toString())) {
                result->insert("id", id);
                reply(*result);
            }
        } else if (type == "cancel" && confirmsCancel) {
            reply({{"type", "result"}, {"id", frame.value("id")}, {"outcome", "cancelled"}});
        } else if (type == "shutdown") {
            exitLater();
        }
    }

    void exit() {
        if (hasExited) return;
        hasExited = true;
        emit exited();
    }

    QStringList commands() const {
        QStringList names;
        for (const auto &frame : receivedFrames)
            if (frame.value("type") == "command") names << frame.value("name").toString();
        return names;
    }

    bool receivedType(const QString &type) const {
        for (const auto &frame : receivedFrames)
            if (frame.value("type") == type) return true;
        return false;
    }

    /// Delivers a frame to the shell on the next turn of the event loop.
    void deliver(const QJsonObject &frame) { reply(frame); }

private:
    void reply(const QJsonObject &frame) {
        const QByteArray line = QJsonDocument(frame).toJson(QJsonDocument::Compact);
        QMetaObject::invokeMethod(this, [this, line] { if (!hasExited) emit received(line); }, Qt::QueuedConnection);
    }
    void exitLater() { QMetaObject::invokeMethod(this, [this] { exit(); }, Qt::QueuedConnection); }
};

/// Starts fake helpers and records container operations in order.
class FakeSpawner : public HelperSpawner {
public:
    std::function<void(FakeHelper &)> configure = [](FakeHelper &) {};
    std::vector<FakeHelper *> started;
    QStringList log;

    HelperConnection *start() override {
        auto *helper = new FakeHelper;
        configure(*helper);
        started.push_back(helper);
        log << QStringLiteral("start %1").arg(started.size());
        return helper;
    }

    void terminateAndWaitEmpty(HelperConnection *connection, std::function<void()> done) override {
        const int index = indexOf(connection);
        log << QStringLiteral("terminate %1").arg(index);
        static_cast<FakeHelper *>(connection)->exit();
        log << QStringLiteral("empty %1").arg(index);
        done();
    }

private:
    int indexOf(HelperConnection *connection) const {
        for (size_t i = 0; i < started.size(); ++i)
            if (started[i] == connection) return int(i) + 1;
        return 0;
    }
};

inline QJsonObject completed(const QJsonObject &value = {}) {
    return {{"type", "result"}, {"outcome", "completed"}, {"value", value}};
}


/// Sends an event frame to the shell, as the helper does.
inline void emitEvent(FakeHelper &helper, const QString &workflow, const QString &name, const QJsonObject &fields) {
    helper.deliver({{"type", "event"}, {"sequence", 1}, {"workflow", workflow}, {"name", name}, {"fields", fields}});
}

} // namespace ssmconnect::testing
