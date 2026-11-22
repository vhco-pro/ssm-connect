// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "shell_controller.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QUuid>

namespace ssmconnect {

namespace {
constexpr const char *SignInRequiredBody =
    "Your SSO session has ended. Choose Sign In with SSO in the SSM Connect menu; what you started continues after you sign in.";
}

ShellController::ShellController(HelperHost &host, ShellPlatform &platform, QObject *parent)
    : QObject(parent), host_(host), platform_(platform) {
    connect(&host_, &HelperHost::eventReceived, this, &ShellController::handle);
    // A helper that stops takes its connections with it, and its replacement starts with none: what
    // the stopped helper reported no longer describes anything.
    connect(&host_, &HelperHost::statusChanged, this, [this] {
        if (host_.status() == HelperHostStatus::Ready || states_.isEmpty()) return;
        states_.clear();
        emit stateChanged();
    });
}

const QList<ShellAction> &ShellController::menuActions() {
    static const QList<ShellAction> actions{
        {QStringLiteral("Sign In with SSO"), QStringLiteral("signIn"), {}},
        {QStringLiteral("Connect"), QStringLiteral("connect"), {}},
        {QStringLiteral("Disconnect"), QStringLiteral("disconnect"), {}},
        {QStringLiteral("Stop Workstation"), QStringLiteral("stopWorkstation"), {}},
        {QStringLiteral("Open VS Code"), QStringLiteral("openEditor"), {}},
        {QStringLiteral("Start Web Forwards"), QStringLiteral("startWebForwards"), {}},
        {QStringLiteral("Stop Web Forwards"), QStringLiteral("stopWebForwards"), {}},
        {QStringLiteral("Open Browser"), QStringLiteral("openBrowser"), {}},
    };
    return actions;
}

HelperCommand *ShellController::run(const ShellAction &action) {
    HelperCommand *command = host_.send(action.command, action.arguments);
    auto report = [this, command, label = action.label] {
        const HelperOutcome outcome = command->result().outcome;
        if (outcome == HelperOutcome::Failed || outcome == HelperOutcome::Rejected || outcome == HelperOutcome::CoreStopped)
            platform_.showError(label, command->result().message.isEmpty() ? HelperHost::UnavailableMessage : command->result().message);
    };
    if (command->isFinished()) report();
    else connect(command, &HelperCommand::finished, this, report);
    return command;
}

void ShellController::reloadProfiles(const QString &select) {
    HelperCommand *command = run({QStringLiteral("Profiles"), QStringLiteral("listProfiles"), {}});
    auto loaded = [this, command, select] {
        if (command->result().outcome != HelperOutcome::Completed) return;
        profiles_ = QJsonDocument::fromJson(command->result().value.value("profiles").toString().toUtf8()).array().toVariantList();
        emit profilesChanged();
        if (!select.isEmpty()) emit profileSelected(select);
    };
    if (command->isFinished()) loaded();
    else connect(command, &HelperCommand::finished, this, loaded);
}

void ShellController::saveProfile(const QVariantMap &edited) {
    QVariantMap profile = edited;
    if (profile.value("id").toString().isEmpty()) profile.insert("id", QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper());
    for (const char *port : {"localPort", "remotePort"}) {
        bool ok = false;
        const int value = profile.value(port).toString().toInt(&ok);
        profile.insert(port, ok ? value : 8443);
    }
    const QString id = profile.value("id").toString();
    const QByteArray json = QJsonDocument(QJsonObject::fromVariantMap(profile)).toJson(QJsonDocument::Compact);
    HelperCommand *command = run({QStringLiteral("Save Profile"), QStringLiteral("saveProfile"), {{"profile", QString::fromUtf8(json)}}});
    // Reloading keeps the saved profile selected, so Use acts on it.
    if (command->isFinished()) reloadProfiles(id);
    else connect(command, &HelperCommand::finished, this, [this, id] { reloadProfiles(id); });
}

void ShellController::useProfile(const QString &id) {
    if (!id.isEmpty()) run({QStringLiteral("Use Profile"), QStringLiteral("setActiveProfile"), {{"id", id}}});
}

void ShellController::importProfile() {
    const QString path = platform_.chooseProfileFile();
    if (path.isEmpty()) return;
    HelperCommand *command = run({QStringLiteral("Import Profile"), QStringLiteral("importProfile"), {{"path", path}, {"attach", "true"}}});
    if (command->isFinished()) reloadProfiles();
    else connect(command, &HelperCommand::finished, this, [this] { reloadProfiles(); });
}

void ShellController::setUpEditor() {
    run({QStringLiteral("Set Up VS Code"), QStringLiteral("installEditorSetup"), {{"consent", "true"}}});
}

void ShellController::handle(const QJsonObject &frame) {
    const QString workflow = frame.value("workflow").toString();
    const QString name = frame.value("name").toString();
    const QJsonObject fields = frame.value("fields").toObject();
    if (workflow == "shell") {
        if (name == "openURL" && fields.contains("url")) platform_.openUrl(fields.value("url").toString());
        else if (name == "launchApplication") launch(fields);
        else if (name == "setClipboard" && fields.contains("text")) platform_.setClipboard(fields.value("text").toString());
        else if (name == "notify")
            platform_.notify(fields.value("title").toString("SSM Connect"), fields.value("body").toString());
        return;
    }
    if (name == "state" && !workflow.isEmpty() && fields.contains("state")) {
        const QString state = fields.value("state").toString();
        // An action waits for an explicit sign-in once the SSO session can no longer be renewed:
        // say so once, and name the menu item, since the tray only shows the action's state.
        if (workflow == "authorization" && state == "signInRequired" && states_.value(workflow).toString() != state)
            platform_.notify(QStringLiteral("Sign in required"), QString::fromUtf8(SignInRequiredBody));
        states_.insert(workflow, state);
        emit stateChanged();
    }
}

void ShellController::launch(const QJsonObject &fields) {
    const QString kind = fields.value("kind").toString();
    if (kind == "vsCode" && fields.contains("path")) {
        platform_.start(fields.value("path").toString(), fields.value("arguments").toString().split(QChar(0x1F), Qt::SkipEmptyParts));
    } else if (kind == "dcvViewer" && fields.contains("file")) {
        const QString viewer = platform_.dcvViewerPath();
        if (viewer.isEmpty()) platform_.showError("DCV Viewer", "Install Amazon DCV Viewer to open the desktop. The tunnel stays connected.");
        else platform_.start(viewer, {fields.value("file").toString()});
    } else if (kind == "browser") {
        bool ok = false;
        const int port = fields.value("socksPort").toString().toInt(&ok);
        platform_.startBrowser(fields.value("browser").toString(), fields.value("mode").toString(), fields.value("profile").toString(),
                               ok ? port : 1080);
    }
}

} // namespace ssmconnect
