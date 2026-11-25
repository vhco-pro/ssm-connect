// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "shell_controller.h"

#include <QJsonArray>
#include <QRegularExpression>

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
    // A helper sends its details only after a first command, so a helper that becomes ready is
    // asked for its profiles. A helper that stops takes its connections with it, and its
    // replacement starts with none: what the stopped helper reported no longer describes anything.
    connect(&host_, &HelperHost::statusChanged, this, [this] {
        if (host_.status() == HelperHostStatus::Ready) {
            reloadProfiles({}, true);
            return;
        }
        if (!details_.isEmpty()) {
            details_.clear();
            emit detailsChanged();
        }
        if (states_.isEmpty()) return;
        states_.clear();
        emit stateChanged();
    });
    if (host_.status() == HelperHostStatus::Ready)
        QMetaObject::invokeMethod(this, [this] { reloadProfiles({}, true); }, Qt::QueuedConnection);
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
    // The helper refuses a second desktop command while Connect runs, so Disconnect then cancels
    // the Connect, as Disconnect while connecting does on macOS: the helper's cancel ends what the
    // Connect started.
    if (action.command == "disconnect" && connecting_ && !connecting_->isFinished()) {
        connecting_->cancel();
        return connecting_;
    }
    HelperCommand *command = host_.send(action.command, action.arguments);
    if (action.command == "connect") connecting_ = command;
    auto report = [this, command, label = action.label] {
        const HelperOutcome outcome = command->result().outcome;
        if (outcome == HelperOutcome::Failed || outcome == HelperOutcome::Rejected || outcome == HelperOutcome::CoreStopped)
            platform_.showError(label, command->result().message.isEmpty() ? HelperHost::UnavailableMessage : command->result().message);
    };
    if (command->isFinished()) report();
    else connect(command, &HelperCommand::finished, this, report);
    return command;
}

void ShellController::reloadProfiles(const QString &select, bool quiet) {
    // The reload a ready helper gets is quiet: a helper that stops again is shown by the tray.
    HelperCommand *command = quiet ? host_.send(QStringLiteral("listProfiles"), {})
                                   : run({QStringLiteral("Profiles"), QStringLiteral("listProfiles"), {}});
    auto loaded = [this, command, select] {
        if (command->result().outcome != HelperOutcome::Completed) return;
        const QVariantMap value = command->result().value;
        profiles_ = QJsonDocument::fromJson(value.value("profiles").toString().toUtf8()).array().toVariantList();
        activeID_ = value.value("active").toString();
        settings_ = QJsonDocument::fromJson(value.value("settings").toString().toUtf8()).object().toVariantMap();
        files_ = QJsonDocument::fromJson(value.value("files").toString().toUtf8()).array().toVariantList();
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
    sendSave(id, QString::fromUtf8(json), false);
}

void ShellController::sendSave(const QString &id, const QString &json, bool acceptFormatting) {
    QVariantMap arguments{{"profile", json}};
    if (acceptFormatting) arguments.insert("acceptFormatting", "true");
    HelperCommand *command = host_.send(QStringLiteral("saveProfile"), arguments);
    auto finished = [this, command, id, json] {
        const HelperResult result = command->result();
        // An attached file needs consent to its canonical formatting once, and is never saved
        // over changes made outside SSM Connect: the user can load the file's version instead.
        if (result.code == "formattingConsentRequired") {
            if (platform_.confirm(QStringLiteral("Save Profile"), result.message)) sendSave(id, json, true);
            return;
        }
        if (result.code == "fileConflict") {
            if (platform_.confirm(QStringLiteral("Save Profile"),
                                  result.message + QStringLiteral(" Load the file's version now? Your edits are not saved."))) {
                HelperCommand *apply = run({QStringLiteral("Load File Changes"), QStringLiteral("applyFileChanges"), {{"id", id}}});
                if (apply->isFinished()) reloadProfiles(id);
                else connect(apply, &HelperCommand::finished, this, [this, id] { reloadProfiles(id); });
            }
            return;
        }
        if (result.outcome == HelperOutcome::Failed || result.outcome == HelperOutcome::Rejected || result.outcome == HelperOutcome::CoreStopped)
            platform_.showError(QStringLiteral("Save Profile"), result.message.isEmpty() ? HelperHost::UnavailableMessage : result.message);
        // Reloading keeps the saved profile selected, so Use acts on it.
        reloadProfiles(id);
    };
    if (command->isFinished()) finished();
    else connect(command, &HelperCommand::finished, this, finished);
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
        else if (name == "reveal" && fields.contains("path")) platform_.reveal(fields.value("path").toString());
        else if (name == "notify")
            platform_.notify(fields.value("title").toString("SSM Connect"), fields.value("body").toString());
        return;
    }
    if (workflow == "details" && name == "details") {
        details_ = fields.toVariantMap();
        emit detailsChanged();
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
    } else if (kind == "browser" && fields.contains("path")) {
        // The core picks the browser and builds its command line, routing included.
        platform_.start(fields.value("path").toString(), fields.value("arguments").toString().split(QChar(0x1F), Qt::SkipEmptyParts));
    }
}

const QList<ShellControl> &ShellController::controls() {
    static const QList<ShellControl> list{
#include "parity_controls.inc"
    };
    return list;
}

const ShellControl *ShellController::control(const QString &id) {
    for (const ShellControl &c : controls())
        if (c.id == id) return &c;
    return nullptr;
}

namespace {

bool truthy(const QString &value) { return !value.isEmpty() && value != "false" && value != "0"; }

bool clause(const QString &text, const QVariantMap &values) {
    const QString c = text.trimmed();
    if (c.startsWith('!') && !c.contains('=')) return !truthy(values.value(c.mid(1)).toString());
    if (c.contains("!=")) return !c.section("!=", 1).split('|').contains(values.value(c.section("!=", 0, 0)).toString());
    if (c.contains('>')) return values.value(c.section('>', 0, 0)).toString().toInt() > c.section('>', 1).toInt();
    if (c.contains('=')) return c.section('=', 1).split('|').contains(values.value(c.section('=', 0, 0)).toString());
    return truthy(values.value(c).toString());
}

// Which workflow a command belongs to, for the cancel controls (the helper runs one per workflow).
QString workflowOf(const QString &command) {
    static const QMap<QString, QString> map{
        {"connect", "desktop"}, {"reconnect", "desktop"}, {"disconnect", "desktop"}, {"stopWorkstation", "desktop"},
        {"openEditor", "editor"}, {"reconnectWorkspace", "editor"}, {"renewEditorAccess", "editor"}, {"approveReplacement", "editor"},
        {"cancelEditorRecovery", "editor"}, {"stopRemoteAccess", "editor"}, {"restoreEditorSetup", "editor"}, {"installEditorSetup", "editor"},
        {"startWebForwards", "web"}, {"stopWebForwards", "web"}, {"approveForwardingReplacement", "web"}, {"applyWebChanges", "web"},
        {"cancelForwardingRecovery", "web"}};
    return map.value(command);
}

// A cancel control whose no-command form is itself the cancellation; Stop Remote Access and
// Restore Editor Setup instead run as their own command once the cancelled one has ended.
bool cancelsOnly(const QString &otherwise) {
    return otherwise == "cancelEditorRecovery" || otherwise == "cancelForwardingRecovery" || otherwise == "disconnect";
}

} // namespace

bool ShellController::evaluate(const QString &rule, const QVariantMap &values) {
    if (rule.trimmed().isEmpty()) return true;
    for (const QString &alternative : rule.split(" or ")) {
        bool all = true;
        for (const QString &part : alternative.split(" & ")) all = all && clause(part, values);
        if (all) return true;
    }
    return false;
}

QVariantMap ShellController::merged(const QVariantMap &context) const {
    QVariantMap values = details_;
    for (auto it = context.begin(); it != context.end(); ++it) values.insert(it.key(), it.value());
    return values;
}

bool ShellController::isOffered(const QString &id, const QVariantMap &context) const {
    const ShellControl *c = control(id);
    if (!c) return false;
    // Until the helper has sent its details, only the controls the shell serves itself are offered.
    const bool needsHelper = !c->command.isEmpty() || !c->commands.isEmpty() || !c->cancelWorkflow.isEmpty();
    if (needsHelper && details_.isEmpty()) return false;
    return evaluate(c->offeredWhen, merged(context));
}

bool ShellController::isEnabled(const QString &id, const QVariantMap &context) const {
    const ShellControl *c = control(id);
    return c && isOffered(id, context) && evaluate(c->enabledWhen, merged(context));
}

QString ShellController::labelFor(const QString &id) const {
    const ShellControl *c = control(id);
    if (!c) return {};
    const QString desktop = details_.value("desktop.state").toString();
    if (c->command == "connect") {
        if (desktop == "connected") return QStringLiteral("Connected");
        if (desktop == "error") return QStringLiteral("Retry Connect");
        if (desktop.isEmpty() || desktop == "disconnected") return QStringLiteral("Connect");
        return QStringLiteral("Connecting…");
    }
    if (!c->commands.isEmpty()) {
        const QString web = details_.value("web.state").toString();
        return web == "On" || web == "Starting" ? QStringLiteral("Turn Off Web Forwards") : QStringLiteral("Turn On Web Forwards");
    }
    const QString editor = details_.value("editor.state").toString();
    if (c->command == "openEditor" && editor == "opening") return QStringLiteral("Opening VS Code");
    if (c->command == "reconnectWorkspace" && editor == "recovering") return QStringLiteral("Recovering Existing Workspace");
    if (c->command == "renewEditorAccess" && editor == "renewing") return QStringLiteral("Renewing Editor Access");
    if (c->command == "openBrowser" && details_.value("web.openingBrowser").toString() == "true") return QStringLiteral("Opening Browser");
    return c->label;
}

QVariantMap ShellController::activeProfile() const {
    for (const QVariant &p : profiles_) {
        const QVariantMap profile = p.toMap();
        if (profile.value("id").toString() == activeID_) return profile;
    }
    return profiles_.isEmpty() ? QVariantMap{} : profiles_.first().toMap();
}

// Fills `{key}` placeholders with details values; `{editor.replacement.user}` reads a field of the
// JSON a details value holds.
QString ShellController::format(const QString &text, const QVariantMap &values) const {
    QString out = text;
    static const QRegularExpression placeholder(QStringLiteral("\\{([a-zA-Z.]+)\\}"));
    auto it = placeholder.globalMatch(text);
    while (it.hasNext()) {
        const QString key = it.next().captured(1);
        QString value = values.value(key).toString();
        if (value.isEmpty() && key.count('.') >= 2) {
            const QString holder = key.section('.', 0, 1);
            value = QJsonDocument::fromJson(values.value(holder).toString().toUtf8()).object().value(key.section('.', 2)).toVariant().toString();
        }
        out.replace('{' + key + '}', value);
    }
    return out;
}

HelperCommand *ShellController::trigger(const QString &id, const QVariantMap &arguments, const QVariantMap &context) {
    const ShellControl *c = control(id);
    if (!c || !isEnabled(id, context)) return nullptr;
    const QVariantMap values = merged(context);
    const bool asks = !c->confirmTitle.isEmpty() && evaluate(c->confirmWhen, values);

    if (!c->cancelWorkflow.isEmpty()) {
        if (asks && !platform_.confirm(format(c->confirmTitle, values), format(c->confirmText, values))) return nullptr;
        HelperCommand *running = running_.value(c->cancelWorkflow);
        if (running && !running->isFinished()) {
            cancelRunning(running, *c, arguments);
            return running;
        }
        return runCommand(c->otherwise, arguments);
    }
    if (c->command.isEmpty() && c->commands.isEmpty()) {
        performShell(*c, arguments);
        return nullptr;
    }
    if (!c->field.isEmpty()) return editField(*c, arguments);

    QString command = c->command;
    if (!c->commands.isEmpty()) {
        const QString web = values.value("web.state").toString();
        command = web == "On" || web == "Starting" ? c->commands.value(1) : c->commands.value(0);
    }
    QVariantMap args = arguments;
    if (command == "importProfile") return openProfileFile();
    if (command == "exportProfile") {
        const QString path = platform_.chooseSaveFile(QStringLiteral("Export Profile"));
        if (path.isEmpty()) return nullptr;
        args.insert("path", path);
    }
    if (command == "locateProfileFile") {
        const QString path = platform_.chooseProfileFile();
        if (path.isEmpty()) return nullptr;
        args.insert("path", path);
    }
    if (command == "openBrowser" && asks) {
        // macOS asks for a browser mode when the profile has none, and saves it first.
        const int choice = platform_.choose(format(c->confirmTitle, values), format(c->confirmText, values), c->choices);
        if (choice < 0 || choice >= 2) return nullptr;
        QVariantMap profile = activeProfile();
        QVariantMap web = profile.value("webForwards").toMap();
        web.insert("browserMode", choice == 0 ? "separate" : "existing");
        profile.insert("webForwards", web);
        sendSave(profile.value("id").toString(), QString::fromUtf8(QJsonDocument(QJsonObject::fromVariantMap(profile)).toJson(QJsonDocument::Compact)), false);
        return runCommand(command, args);
    }
    if (command == "openEditor" && asks) {
        // First use: consent to the SSH Include, then open.
        if (!platform_.confirm(format(c->confirmTitle, values), format(c->confirmText, values))) return nullptr;
        HelperCommand *setup = runCommand("installEditorSetup", {{"consent", "true"}});
        auto open = [this, setup, args] {
            if (setup->result().outcome == HelperOutcome::Completed) runCommand("openEditor", args);
        };
        if (setup->isFinished()) open();
        else connect(setup, &HelperCommand::finished, this, open);
        return setup;
    }
    if (asks && !platform_.confirm(format(c->confirmTitle, values), format(c->confirmText, values))) return nullptr;
    HelperCommand *sent = runCommand(command, args);
    if (!c->shell.isEmpty()) {
        // Show Log: open the window once the log is read.
        auto show = [this, sent] { emit showLogRequested(sent->result().value.value("entries").toString()); };
        if (sent->isFinished()) show();
        else connect(sent, &HelperCommand::finished, this, show);
    }
    if (command == "listAWSConfigProfiles") {
        auto loaded = [this, sent] {
            emit importableProfilesChanged(QJsonDocument::fromJson(sent->result().value.value("profiles").toString().toUtf8()).array().toVariantList());
        };
        if (sent->isFinished()) loaded();
        else connect(sent, &HelperCommand::finished, this, loaded);
    }
    if (command.contains("Profile") || command == "saveLocalCopy" || command == "applyFileChanges" || command == "saveSettings"
        || command == "reviewFileChanges") {
        auto reload = [this] { reloadProfiles(); };
        if (sent->isFinished()) reload();
        else connect(sent, &HelperCommand::finished, this, reload);
    }
    if (command == "reviewFileChanges") {
        // Outside changes to an attached file are shown, as macOS shows them, and stay pending until applied.
        auto review = [this, sent] {
            if (sent->result().value.value("pending").toString() != "true") return;
            const QJsonObject d = QJsonDocument::fromJson(sent->result().value.value("document").toString().toUtf8()).object();
            auto f = [&d](const char *key) { return d.value(QLatin1String(key)).toVariant().toString(); };
            platform_.choose(QStringLiteral("Review external profile changes"),
                             QStringLiteral("The stored configuration and existing connections have not changed. Apply replaces the stored "
                                            "configuration only; existing transport-specific pending-Apply and ownership checks still apply.\n"
                                            "Account: %1, role: %2\nRegion: %3, target: %4=%5")
                                 .arg(f("accountId"), f("roleName"), f("resourceRegion"), f("instanceTagKey"), f("instanceTagValue")),
                             {QStringLiteral("Keep Pending")});
        };
        if (sent->isFinished()) review();
        else connect(sent, &HelperCommand::finished, this, review);
    }
    return sent;
}

// Cancels the running command of the control's workflow. When the helper had already finished it,
// the result is not "cancelled": a pure cancel control then sends its no-command form once, which
// ends what the finished command left (such as a replacement waiting for review). Stop Remote
// Access and Restore Editor Setup run as their own command once the cancelled one has ended. The
// cancelled command itself is never sent again.
void ShellController::cancelRunning(HelperCommand *running, const ShellControl &control, const QVariantMap &arguments) {
    const QString otherwise = control.otherwise;
    const bool only = cancelsOnly(otherwise);
    QPointer<HelperCommand> guarded(running);
    auto after = [this, guarded, otherwise, only, arguments] {
        if (!guarded) return;
        if (!only || guarded->result().outcome != HelperOutcome::Cancelled) runCommand(otherwise, arguments);
    };
    connect(running, &HelperCommand::finished, this, after, Qt::SingleShotConnection);
    running->cancel();
}

void ShellController::performShell(const ShellControl &control, const QVariantMap &arguments) {
    const QString what = control.shell;
    if (what.startsWith("open the settings window")) emit showSettingsRequested();
    else if (what.startsWith("open the About window")) emit showAboutRequested();
    else if (what.startsWith("quit")) emit quitRequested();
    else if (what.startsWith("open the documentation URL"))
        platform_.openUrl(QStringLiteral("https://code.visualstudio.com/docs/remote/troubleshooting"));
    else if (what.startsWith("open the license URL"))
        platform_.openUrl(QStringLiteral("https://github.com/vhco-pro/ssm-connect/blob/main/LICENSE"));
    else if (what.startsWith("open the project URL")) platform_.openUrl(QStringLiteral("https://github.com/vhco-pro/ssm-connect"));
    else if (what.startsWith("open the release notes URL"))
        platform_.openUrl(QStringLiteral("https://github.com/vhco-pro/ssm-connect/releases"));
    else if (what.startsWith("open the profile editor with a blank")) emit editProfileRequested({});
    else if (what.startsWith("open the profile editor")) emit editProfileRequested(arguments.value("profile").toMap());
}

// Edits one field of the active profile (or of the draft the window passes) and saves it, or one
// app setting.
HelperCommand *ShellController::editField(const ShellControl &control, const QVariantMap &arguments) {
    if (control.command == "saveSettings") return runCommand("saveSettings", {{control.field, arguments.value("value", "")}});
    QVariantMap profile = arguments.contains("profile") ? arguments.value("profile").toMap() : activeProfile();
    if (arguments.contains("value") && !control.field.contains("[]") && !control.field.contains(' ')) {
        const QStringList path = control.field.split('.');
        if (path.size() == 1) profile.insert(path[0], arguments.value("value"));
        else {
            QVariantMap section = profile.value(path[0]).toMap();
            section.insert(path[1], arguments.value("value"));
            profile.insert(path[0], section);
        }
    }
    const QString json = QString::fromUtf8(QJsonDocument(QJsonObject::fromVariantMap(profile)).toJson(QJsonDocument::Compact));
    HelperCommand *command = runCommand("saveProfile", {{"profile", json}});
    connect(command, &HelperCommand::finished, this, [this] { reloadProfiles(); });
    return command;
}

// Open Profile File: macOS previews the file before anything is stored, then attaches it or imports
// a local copy.
HelperCommand *ShellController::openProfileFile() {
    const ShellControl *c = control("settings-button-open-profile-file");
    const QString path = platform_.chooseProfileFile();
    if (path.isEmpty() || !c) return nullptr;
    HelperCommand *preview = runCommand("previewProfileFile", {{"path", path}});
    auto ask = [this, preview, path, c] {
        if (preview->result().outcome != HelperOutcome::Completed) return;
        QVariantMap values = details_;
        const QJsonObject profile = QJsonDocument::fromJson(preview->result().value.value("profile").toString().toUtf8()).object();
        for (auto it = profile.begin(); it != profile.end(); ++it) values.insert("preview." + it.key(), it.value().toVariant());
        const int choice = platform_.choose(format(c->confirmTitle, values), format(c->confirmText, values), c->choices);
        if (choice < 0 || choice >= 2) return;
        HelperCommand *imported = runCommand("importProfile", {{"path", path}, {"attach", choice == 0 ? "true" : "false"}});
        connect(imported, &HelperCommand::finished, this, [this] { reloadProfiles(); });
    };
    if (preview->isFinished()) ask();
    else connect(preview, &HelperCommand::finished, this, ask);
    return preview;
}

HelperCommand *ShellController::runCommand(const QString &command, const QVariantMap &arguments) {
    HelperCommand *sent = run({command, command, arguments});
    const QString workflow = workflowOf(command);
    if (!workflow.isEmpty()) running_.insert(workflow, sent);
    return sent;
}

void ShellController::systemResumed() {
    // Quiet: a helper that is busy or stopped needs no wake check, and the user did nothing to be told about.
    if (host_.status() == HelperHostStatus::Ready) host_.send(QStringLiteral("systemWake"), {});
}

} // namespace ssmconnect
