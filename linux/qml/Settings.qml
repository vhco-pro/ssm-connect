// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The settings window, laid out as the macOS one: startup, connection and clipboard settings, the
// profiles with Use, and the add, import, duplicate, delete, file and edit actions. It holds no
// connection rules: each control is named by its contracts/macos-parity.json id and calls the shell
// controller, which offers and enables it as macOS does and sends its helper command.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    objectName: "settings"
    title: "SSM Connect Settings"
    width: 680
    height: 620
    visible: true

    property var selected: profiles.currentIndex >= 0 && profiles.currentIndex < shell.profiles.length
                           ? shell.profiles[profiles.currentIndex] : null
    property var importable: []

    function attachment(id) {
        for (var i = 0; i < shell.files.length; ++i)
            if (shell.files[i].id === id) return shell.files[i]
        return null
    }
    // The shell context the inventory's rules read for the selected profile.
    function context() {
        var file = selected ? attachment(selected.id) : null
        return { "selected": selected ? "true" : "false", "selected.attached": file ? "true" : "false",
                 "selected.pending": file && file.pending === "true" ? "true" : "false",
                 "profiles": String(shell.profiles.length) }
    }
    function selectedArguments() { return selected ? { "id": selected.id, "profile": selected } : {} }

    Connections {
        target: shell
        function onProfileSelected(id) {
            for (var i = 0; i < shell.profiles.length; ++i)
                if (shell.profiles[i].id === id) profiles.currentIndex = i
        }
        function onImportableProfilesChanged(list) { window.importable = list; importMenu.open() }
    }

    Component.onCompleted: shell.reloadProfiles()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        Label { text: "Startup"; font.bold: true }
        CheckBox {
            objectName: "settings-toggle-launch-at-login"
            text: "Launch at login"
            visible: typeof startup !== "undefined"
            checked: typeof startup !== "undefined" && startup.enabled
            onToggled: startup.setEnabled(checked, executablePath)
        }
        CheckBox {
            objectName: "settings-toggle-connect-automatically-on-launch"
            text: "Connect automatically on launch"
            checked: shell.settings.connectOnLaunch === "true"
            onToggled: shell.trigger(objectName, { "value": checked ? "true" : "false" })
        }
        Label { text: "Connection"; font.bold: true }
        CheckBox {
            objectName: "settings-toggle-reconnect-automatically-if-the-tunnel-drops"
            text: "Reconnect automatically if the tunnel drops"
            checked: shell.settings.autoReconnect !== "false"
            onToggled: shell.trigger(objectName, { "value": checked ? "true" : "false" })
        }
        Label { text: "Clipboard"; font.bold: true }
        RowLayout {
            Label { text: "Clear copied password after" }
            SpinBox {
                objectName: "settings-clipboard-auto-clear"
                from: 0; to: 600; stepSize: 5
                value: Number(shell.settings.clipboardAutoClearSeconds || 30)
                onValueModified: shell.trigger(objectName, { "value": String(value) })
            }
            Label { text: "seconds (0 keeps it until you replace it)" }
        }

        Label { text: "Profiles"; font.bold: true }
        ListView {
            id: profiles
            objectName: "profiles"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            currentIndex: -1
            model: shell.profiles
            delegate: ItemDelegate {
                required property var modelData
                required property int index
                width: ListView.view.width
                highlighted: ListView.isCurrentItem
                onClicked: profiles.currentIndex = index
                contentItem: RowLayout {
                    Label {
                        Layout.fillWidth: true
                        text: modelData.name + "  ·  " + (modelData.accountId || "") + " · " + (modelData.resourceRegion || "")
                              + (window.attachment(modelData.id) ? "  (attached to a profile file)" : "")
                    }
                    Button {
                        objectName: "settings-button-use"
                        text: "Use"
                        visible: shell.isOffered(objectName, { "item.active": modelData.id === shell.activeProfileId ? "true" : "false" })
                        onClicked: shell.trigger(objectName, { "id": modelData.id }, { "item.active": "false" })
                    }
                }
            }
        }

        RowLayout {
            ToolButton {
                objectName: "settings-button-add-a-blank-profile"
                text: "+"
                ToolTip.text: "Add a blank profile"; ToolTip.visible: hovered
                onClicked: shell.trigger(objectName)
            }
            ToolButton {
                objectName: "settings-menu-import-a-profile-from-aws-config"
                text: "Import from ~/.aws/config"
                onClicked: shell.trigger(objectName)
                Menu {
                    id: importMenu
                    Repeater {
                        model: window.importable
                        delegate: MenuItem {
                            required property var modelData
                            objectName: "settings-button-profile-name"
                            text: modelData.name
                            onTriggered: shell.trigger(objectName, { "profile": modelData })
                        }
                    }
                    MenuItem { text: "No SSO profiles found in ~/.aws/config"; enabled: false; visible: window.importable.length === 0 }
                }
            }
            ToolButton {
                objectName: "settings-button-duplicate-the-selected-profile"
                text: "Duplicate"
                enabled: shell.isEnabled(objectName, window.context())
                onClicked: shell.trigger(objectName, window.selectedArguments(), window.context())
            }
            ToolButton {
                objectName: "settings-button-delete-the-selected-profile"
                text: "−"
                ToolTip.text: "Delete the selected profile"; ToolTip.visible: hovered
                enabled: shell.isEnabled(objectName, window.context())
                onClicked: shell.trigger(objectName, window.selectedArguments(), window.context())
            }
            Item { Layout.fillWidth: true }
            ToolButton {
                objectName: "settings-menu-files"
                text: "Files"
                onClicked: filesMenu.open()
                Menu {
                    id: filesMenu
                    MenuItem {
                        objectName: "settings-button-open-profile-file"
                        text: "Open Profile File…"
                        onTriggered: shell.trigger(objectName, {}, window.context())
                    }
                    MenuItem {
                        objectName: "settings-button-export-profile"
                        text: "Export Profile…"
                        enabled: shell.isEnabled(objectName, window.context())
                        onTriggered: shell.trigger(objectName, window.selectedArguments(), window.context())
                    }
                    MenuItem {
                        objectName: "settings-button-save-a-local-copy"
                        text: "Save a Local Copy"
                        enabled: shell.isEnabled(objectName, window.context())
                        onTriggered: shell.trigger(objectName, { "id": window.selected.id }, window.context())
                    }
                    MenuSeparator { visible: shell.isOffered("settings-button-reload-review-changes", window.context()) }
                    MenuItem {
                        objectName: "settings-button-reload-review-changes"
                        text: "Reload / Review Changes"
                        visible: shell.isOffered(objectName, window.context())
                        onTriggered: shell.trigger(objectName, window.selectedArguments(), window.context())
                    }
                    MenuItem {
                        objectName: "settings-button-apply-external-changes"
                        text: "Apply External Changes"
                        visible: shell.isOffered(objectName, window.context())
                        enabled: shell.isEnabled(objectName, window.context())
                        onTriggered: shell.trigger(objectName, window.selectedArguments(), window.context())
                    }
                    MenuItem {
                        objectName: "settings-button-locate-file"
                        text: "Locate File…"
                        visible: shell.isOffered(objectName, window.context())
                        onTriggered: shell.trigger(objectName, window.selectedArguments(), window.context())
                    }
                    MenuItem {
                        objectName: "settings-button-detach-keep-local-profile"
                        text: "Detach (Keep Local Profile)"
                        visible: shell.isOffered(objectName, window.context())
                        onTriggered: shell.trigger(objectName, window.selectedArguments(), window.context())
                    }
                }
            }
            Button {
                objectName: "settings-button-edit"
                text: "Edit…"
                enabled: shell.isEnabled(objectName, window.context())
                onClicked: shell.trigger(objectName, window.selectedArguments(), window.context())
            }
        }
    }
}
