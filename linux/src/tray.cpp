// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "tray.h"

#include <QIcon>

namespace ssmconnect {

Tray::Tray(ShellController &controller, std::function<void()> showSettings, std::function<void()> retry, std::function<void()> quit,
           QObject *parent)
    : QObject(parent), menu_(std::make_unique<QMenu>()) {
    for (const ShellAction &action : ShellController::menuActions()) {
        QAction *item = menu_->addAction(action.label);
        item->setData(action.command);
        connect(item, &QAction::triggered, this, [&controller, action] { controller.run(action); });
    }
    menu_->addSeparator();
    connect(menu_->addAction(QStringLiteral("Settings…")), &QAction::triggered, this, [showSettings] { showSettings(); });
    connect(menu_->addAction(QStringLiteral("Retry Core")), &QAction::triggered, this, [retry] { retry(); });
    connect(menu_->addAction(QStringLiteral("Quit")), &QAction::triggered, this, [quit] { quit(); });
    icon_.setContextMenu(menu_.get());
    icon_.setToolTip(QStringLiteral("SSM Connect"));
    update(QStringLiteral("Disconnected"), QStringLiteral("SSM Connect"));
    if (QSystemTrayIcon::isSystemTrayAvailable()) icon_.show();
}

void Tray::update(const QString &state, const QString &tooltip) {
    // Theme icons, so the tray follows the desktop's style.
    const QString name = state == QStringLiteral("Connected")  ? QStringLiteral("network-vpn")
                         : state == QStringLiteral("Error")    ? QStringLiteral("network-error")
                         : state.contains(QStringLiteral("ing")) ? QStringLiteral("network-vpn-acquiring")
                                                                 : QStringLiteral("network-vpn-disconnected");
    icon_.setIcon(QIcon::fromTheme(name, QIcon::fromTheme(QStringLiteral("network-wired"))));
    icon_.setToolTip(tooltip);
}

void Tray::showMessage(const QString &title, const QString &body, bool error) {
    icon_.showMessage(title, body, error ? QSystemTrayIcon::Critical : QSystemTrayIcon::Information);
}

} // namespace ssmconnect
