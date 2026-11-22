// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "linux_shell_platform.h"

#include "user_applications.h"

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QGuiApplication>
#include <QMessageBox>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

namespace ssmconnect {

LinuxShellPlatform::LinuxShellPlatform(std::function<void(const QString &, const QString &)> notify,
                                       std::function<void(const QString &, const QString &)> showError, int clipboardClearSeconds)
    : notify_(std::move(notify)), showError_(std::move(showError)), clipboardClearSeconds_(clipboardClearSeconds) {}

QString LinuxShellPlatform::dcvViewerPath() const {
    return QStandardPaths::findExecutable(QStringLiteral("dcvviewer"));
}

void LinuxShellPlatform::openUrl(const QString &url) {
    // Only the sign-in page and documentation: https URLs.
    if (QUrl(url).scheme() != QStringLiteral("https")) return;
    UserApplications::launch(QStringLiteral("xdg-open"), {url});
}

void LinuxShellPlatform::start(const QString &path, const QStringList &arguments) {
    if (UserApplications::launch(path, arguments).pid == 0) showError_(QStringLiteral("SSM Connect"), "Could not start " + path + ".");
}

void LinuxShellPlatform::setClipboard(const QString &text) {
    QClipboard *clipboard = QGuiApplication::clipboard();
    clipboard->setText(text);
    // The password leaves the clipboard after a while, unless the user copied something else.
    QTimer::singleShot(clipboardClearSeconds_ * 1000, clipboard, [clipboard, text] {
        if (clipboard->text() == text) clipboard->clear();
    });
}

void LinuxShellPlatform::notify(const QString &title, const QString &body) { notify_(title, body); }

void LinuxShellPlatform::showError(const QString &action, const QString &message) { showError_(action, message); }

bool LinuxShellPlatform::confirm(const QString &title, const QString &message) {
    return QMessageBox::question(nullptr, title, message) == QMessageBox::Yes;
}

QString LinuxShellPlatform::chooseProfileFile() {
    return QFileDialog::getOpenFileName(nullptr, QStringLiteral("Import a profile"), QDir::homePath(),
                                        QStringLiteral("SSM Connect profiles (*.ssmconnect *.yaml *.yml *.json)"));
}

} // namespace ssmconnect
