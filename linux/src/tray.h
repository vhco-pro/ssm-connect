// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#pragma once

#include "shell_controller.h"

#include <QMenu>
#include <QObject>
#include <QSystemTrayIcon>

#include <functional>
#include <memory>

namespace ssmconnect {

/// The tray icon and its menu. On Linux desktops `QSystemTrayIcon` registers a StatusNotifierItem
/// over D-Bus (KDE Plasma natively, GNOME with the AppIndicator extension). Its items are the macOS
/// menu's controls (contracts/macos-parity.json), shown and enabled as macOS shows them; Retry Core
/// is the shell's own.
class Tray : public QObject {
    Q_OBJECT
public:
    Tray(ShellController &controller, std::function<void()> showSettings, std::function<void()> retry, std::function<void()> quit,
         QObject *parent = nullptr);

    QMenu *menu() const { return menu_.get(); }
    void update(const QString &state, const QString &tooltip);
    void showMessage(const QString &title, const QString &body, bool error);

private:
    void refresh();
    ShellController &controller_;
    std::unique_ptr<QMenu> menu_;
    QList<QAction *> items_;
    QAction *forwardAnchor_ = nullptr;
    QList<QAction *> forwardItems_;
    QSystemTrayIcon icon_;
};

} // namespace ssmconnect
