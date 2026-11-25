// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "tray.h"

#include <QIcon>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

namespace ssmconnect {

Tray::Tray(ShellController &controller, std::function<void()> showSettings, std::function<void()> retry, std::function<void()> quit,
           QObject *parent)
    : QObject(parent), controller_(controller), menu_(std::make_unique<QMenu>()) {
    // The macOS menu's controls, in its order, each named by its parity inventory id.
    for (const ShellControl &control : ShellController::controls()) {
        if (control.surface != "menu") continue;
        QAction *item = menu_->addAction(control.label);
        item->setObjectName(control.id);
        item->setData(control.id);
        if (control.command == "openForward") {
            forwardAnchor_ = item; // one item per local forward follows it
            item->setVisible(false);
            continue;
        }
        const QString id = control.id;
        connect(item, &QAction::triggered, this, [this, id] { controller_.trigger(id); });
        items_ << item;
    }
    menu_->addSeparator();
    connect(menu_->addAction(QStringLiteral("Retry Core")), &QAction::triggered, this, [retry] { retry(); });
    connect(&controller, &ShellController::showSettingsRequested, this, [showSettings] { showSettings(); });
    connect(&controller, &ShellController::quitRequested, this, [quit] { quit(); });
    connect(&controller, &ShellController::detailsChanged, this, &Tray::refresh);
    connect(menu_.get(), &QMenu::aboutToShow, this, &Tray::refresh);
    refresh();
    icon_.setContextMenu(menu_.get());
    icon_.setToolTip(QStringLiteral("SSM Connect"));
    update(QStringLiteral("Disconnected"), QStringLiteral("SSM Connect"));
    if (QSystemTrayIcon::isSystemTrayAvailable()) icon_.show();
}

// Shows and enables each item as macOS does in the current state, with its current label.
void Tray::refresh() {
    for (QAction *item : items_) {
        const QString id = item->objectName();
        item->setText(controller_.labelFor(id));
        item->setVisible(controller_.isOffered(id));
        item->setEnabled(controller_.isEnabled(id));
    }
    if (!forwardAnchor_) return;
    for (QAction *item : forwardItems_) {
        menu_->removeAction(item);
        item->deleteLater();
    }
    forwardItems_.clear();
    const QJsonArray forwards = QJsonDocument::fromJson(controller_.details().value("web.forwards").toString().toUtf8()).array();
    QAction *before = nullptr;
    const QList<QAction *> actions = menu_->actions();
    const qsizetype anchor = actions.indexOf(forwardAnchor_);
    if (anchor >= 0 && anchor + 1 < actions.size()) before = actions[anchor + 1];
    for (const QJsonValue &value : forwards) {
        const QJsonObject forward = value.toObject();
        const QVariantMap context{{"item.openPath", forward.value("openPath").toString()}};
        const QString id = forwardAnchor_->objectName();
        if (!controller_.isOffered(id, context)) continue;
        auto *item = new QAction(QStringLiteral("Open ") + forward.value("name").toString(), menu_.get());
        item->setObjectName(id);
        item->setEnabled(controller_.isEnabled(id, context));
        const QVariantMap arguments{{"name", forward.value("name").toString()}};
        connect(item, &QAction::triggered, this, [this, id, arguments, context] { controller_.trigger(id, arguments, context); });
        menu_->insertAction(before, item);
        forwardItems_ << item;
    }
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
