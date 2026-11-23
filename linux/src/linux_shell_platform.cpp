// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#include "linux_shell_platform.h"

#include "user_applications.h"

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QFileInfo>
#include <QFileDialog>
#include <QGuiApplication>
#include <QMessageBox>
#include <QPushButton>
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

int LinuxShellPlatform::choose(const QString &title, const QString &message, const QStringList &options) {
    QMessageBox box(QMessageBox::Question, title, message);
    QList<QAbstractButton *> buttons;
    for (const QString &option : options)
        buttons.append(static_cast<QAbstractButton *>(
            box.addButton(option, option == QStringLiteral("Cancel") ? QMessageBox::RejectRole : QMessageBox::AcceptRole)));
    box.exec();
    const qsizetype index = buttons.indexOf(box.clickedButton());
    return index < 0 || options.value(index) == QStringLiteral("Cancel") ? -1 : int(index);
}

QString LinuxShellPlatform::chooseFolder(const QString &title) {
    return QFileDialog::getExistingDirectory(nullptr, title, QDir::homePath());
}

QString LinuxShellPlatform::chooseSaveFile(const QString &title) {
    return QFileDialog::getSaveFileName(nullptr, title, QDir::home().filePath(QStringLiteral("workstation.yaml")),
                                        QStringLiteral("Profile (*.yaml *.yml *.json)"));
}

// The desktop's file manager selects the file (org.freedesktop.FileManager1), or opens its folder.
void LinuxShellPlatform::reveal(const QString &path) {
    QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.FileManager1"), QStringLiteral("/org/freedesktop/FileManager1"),
                                                       QStringLiteral("org.freedesktop.FileManager1"), QStringLiteral("ShowItems"));
    call << QStringList{QUrl::fromLocalFile(path).toString()} << QString();
    if (QDBusConnection::sessionBus().call(call).type() == QDBusMessage::ErrorMessage)
        UserApplications::launch(QStringLiteral("xdg-open"), {QFileInfo(path).absolutePath()});
}

} // namespace ssmconnect
