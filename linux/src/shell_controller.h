// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include "helper_host.h"

#include <QList>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

namespace ssmconnect {

/// One shell action: its label, the helper command it sends and its arguments.
struct ShellAction {
    QString label;
    QString command;
    QVariantMap arguments;
};

/// What the controller needs from Linux; the Qt shell and tests each supply one.
class ShellPlatform {
public:
    virtual ~ShellPlatform() = default;
    /// DCV Viewer's executable, or empty when it is not installed.
    virtual QString dcvViewerPath() const = 0;
    virtual void openUrl(const QString &url) = 0;
    virtual void start(const QString &path, const QStringList &arguments) = 0;
    virtual void startBrowser(const QString &browser, const QString &mode, const QString &profile, int socksPort) = 0;
    virtual void setClipboard(const QString &text) = 0;
    virtual void notify(const QString &title, const QString &body) = 0;
    virtual void showError(const QString &action, const QString &message) = 0;
    /// A profile file the user picks, or empty when they cancel.
    virtual QString chooseProfileFile() = 0;
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

    /// Sends an action's command and reports a failure to the user.
    HelperCommand *run(const ShellAction &action);

    QVariantList profiles() const { return profiles_; }
    /// Latest state per workflow (desktop, web, editor), from the helper's events.
    QVariantMap states() const { return states_; }

    Q_INVOKABLE void reloadProfiles(const QString &select = {});
    Q_INVOKABLE void saveProfile(const QVariantMap &profile);
    Q_INVOKABLE void useProfile(const QString &id);
    Q_INVOKABLE void importProfile();
    Q_INVOKABLE void setUpEditor();

signals:
    void profilesChanged();
    /// After a reload: the profile the settings window should keep selected.
    void profileSelected(const QString &id);
    void stateChanged();

private:
    void handle(const QJsonObject &frame);
    void launch(const QJsonObject &fields);

    HelperHost &host_;
    ShellPlatform &platform_;
    QVariantList profiles_;
    QVariantMap states_;
};

} // namespace ssmconnect
