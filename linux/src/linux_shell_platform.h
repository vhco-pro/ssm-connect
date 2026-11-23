// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include "shell_controller.h"

#include <functional>

namespace ssmconnect {

/// The real Linux platform for the shell. Every application it starts (the sign-in page through
/// xdg-open, VS Code, DCV Viewer, Chrome) runs in its own transient systemd scope, so it survives
/// the helper and the shell. Notifications and errors go through the tray.
class LinuxShellPlatform : public ShellPlatform {
public:
    LinuxShellPlatform(std::function<void(const QString &, const QString &)> notify,
                       std::function<void(const QString &, const QString &)> showError, int clipboardClearSeconds = 30);

    QString dcvViewerPath() const override;
    void openUrl(const QString &url) override;
    void start(const QString &path, const QStringList &arguments) override;
    void setClipboard(const QString &text) override;
    void notify(const QString &title, const QString &body) override;
    void showError(const QString &action, const QString &message) override;
    QString chooseProfileFile() override;
    bool confirm(const QString &title, const QString &message) override;
    int choose(const QString &title, const QString &message, const QStringList &options) override;
    QString chooseFolder(const QString &title) override;
    QString chooseSaveFile(const QString &title) override;
    void reveal(const QString &path) override;

private:
    std::function<void(const QString &, const QString &)> notify_;
    std::function<void(const QString &, const QString &)> showError_;
    int clipboardClearSeconds_;
};

} // namespace ssmconnect
