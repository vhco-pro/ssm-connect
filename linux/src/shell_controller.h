// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include "helper_host.h"

#include <QList>
#include <QObject>
#include <QPointer>
#include <QVariantList>
#include <QVariantMap>

namespace ssmconnect {

/// One shell action: its label, the helper command it sends and its arguments.
struct ShellAction {
    QString label;
    QString command;
    QVariantMap arguments;
};

/// One control of the macOS interface the Linux shell offers (contracts/macos-parity.json, AC-29):
/// its inventory id, where it appears, the helper command it sends (or a cancel of its workflow's
/// running command, or none for a shell-only control), macOS's confirmation, and when macOS
/// offers and enables it.
struct ShellControl {
    QString id;
    QString surface; // menu, settings, editor, log, about
    QString label;
    QString command;
    QStringList commands; // a toggle: the first when off, the second when on
    QString cancelWorkflow;
    QString confirmTitle;
    QString confirmText;
    QString offeredWhen;
    QString enabledWhen;
};

/// What the controller needs from Linux; the Qt shell and tests each supply one.
class ShellPlatform {
public:
    virtual ~ShellPlatform() = default;
    /// DCV Viewer's executable, or empty when it is not installed.
    virtual QString dcvViewerPath() const = 0;
    virtual void openUrl(const QString &url) = 0;
    virtual void start(const QString &path, const QStringList &arguments) = 0;
    virtual void setClipboard(const QString &text) = 0;
    virtual void notify(const QString &title, const QString &body) = 0;
    virtual void showError(const QString &action, const QString &message) = 0;
    /// Asks the user a yes-or-no question; true for yes.
    virtual bool confirm(const QString &title, const QString &message) = 0;
    /// A profile file the user picks, or empty when they cancel.
    virtual QString chooseProfileFile() = 0;
    /// One of `options` the user picks, by index, or -1 when they cancel.
    virtual int choose(const QString &title, const QString &message, const QStringList &options) {
        Q_UNUSED(title); Q_UNUSED(message); Q_UNUSED(options);
        return -1;
    }
    /// A folder the user picks, or empty when they cancel.
    virtual QString chooseFolder(const QString &title) { Q_UNUSED(title); return {}; }
    /// A file to write the user picks, or empty when they cancel.
    virtual QString chooseSaveFile(const QString &title) { Q_UNUSED(title); return {}; }
    /// Shows a file in the platform's file manager.
    virtual void reveal(const QString &path) { Q_UNUSED(path); }
};

/// The Linux shell's behaviour without connection rules, as on Windows: every user action becomes
/// one helper command, and the helper's events drive the tray state and the requests only the
/// shell can serve (the sign-in page, VS Code, DCV Viewer, browsers, the clipboard and
/// notifications). Applications start in their own systemd scopes, outside the helper's unit.
/// The QML settings window calls the invokable methods.
class ShellController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY profilesChanged)
public:
    ShellController(HelperHost &host, ShellPlatform &platform, QObject *parent = nullptr);

    /// The actions the tray menu offers, in order.
    static const QList<ShellAction> &menuActions();

    /// Sends an action's command and reports a failure to the user. Disconnect while a Connect
    /// runs cancels that Connect instead, and returns it.
    HelperCommand *run(const ShellAction &action);

    QVariantList profiles() const { return profiles_; }

    /// The macOS controls this shell offers, by inventory id.
    static const QList<ShellControl> &controls();
    static const ShellControl *control(const QString &id);
    /// The helper's latest details: what the macOS menu reads from the workflows.
    QVariantMap details() const { return details_; }
    /// Whether macOS would show the control, and let it be used, in this state; `context` adds the
    /// shell's own state (the selected profile, a per-item control's item).
    Q_INVOKABLE bool isOffered(const QString &id, const QVariantMap &context = {}) const;
    Q_INVOKABLE bool isEnabled(const QString &id, const QVariantMap &context = {}) const;
    /// Operates a control as macOS does: nothing when it is unavailable, macOS's confirmation first,
    /// a cancel of its workflow's running command for a cancel control. Returns the command sent.
    Q_INVOKABLE HelperCommand *trigger(const QString &id, const QVariantMap &arguments = {}, const QVariantMap &context = {});
    /// Sends a helper command directly and reports a failure.
    HelperCommand *runCommand(const QString &command, const QVariantMap &arguments = {});
    /// Latest state per workflow (desktop, web, editor), from the helper's events.
    QVariantMap states() const { return states_; }

    Q_INVOKABLE void reloadProfiles(const QString &select = {});
    Q_INVOKABLE void saveProfile(const QVariantMap &profile);
    Q_INVOKABLE void useProfile(const QString &id);
    Q_INVOKABLE void importProfile();
    Q_INVOKABLE void setUpEditor();

signals:
    void detailsChanged();
    void profilesChanged();
    /// After a reload: the profile the settings window should keep selected.
    void profileSelected(const QString &id);
    void stateChanged();

private:
    void handle(const QJsonObject &frame);
    void launch(const QJsonObject &fields);
    void sendSave(const QString &id, const QString &json, bool acceptFormatting);

    HelperHost &host_;
    ShellPlatform &platform_;
    QVariantList profiles_;
    QVariantMap states_;
    QPointer<HelperCommand> connecting_;
    QVariantMap details_;
};

} // namespace ssmconnect
