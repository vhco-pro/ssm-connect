// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The settings window: profiles from the helper, edited and saved through it, the active profile,
// profile import, VS Code setup and start at sign-in. It holds no connection rules; each button
// calls the shell controller, which sends one helper command.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    title: "SSM Connect Settings"
    width: 640
    height: 560
    visible: true

    readonly property var fieldNames: ["name", "ssoStartUrl", "ssoRegion", "accountId", "roleName", "resourceRegion",
                                       "instanceTagKey", "instanceTagValue", "localPort", "remotePort"]
    readonly property var labels: ({ name: "Name", ssoStartUrl: "SSO start URL", ssoRegion: "SSO region",
                                     accountId: "Account ID", roleName: "Role", resourceRegion: "Resource region",
                                     instanceTagKey: "Instance tag key", instanceTagValue: "Instance tag value",
                                     localPort: "Local port", remotePort: "Remote port" })
    property var selected: profiles.currentIndex >= 0 && profiles.currentIndex < shell.profiles.length
                           ? shell.profiles[profiles.currentIndex] : null

    function fieldText(name) {
        return selected && selected[name] !== undefined ? String(selected[name]) : ""
    }

    function edited() {
        var profile = selected ? JSON.parse(JSON.stringify(selected)) : {}
        for (var i = 0; i < fields.count; ++i) {
            var field = fields.itemAt(i)
            profile[field.fieldName] = field.text
        }
        return profile
    }

    Connections {
        target: shell
        function onProfileSelected(id) {
            for (var i = 0; i < shell.profiles.length; ++i)
                if (shell.profiles[i].id === id) profiles.currentIndex = i
        }
    }

    Component.onCompleted: shell.reloadProfiles()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        Label { text: "Profiles"; font.bold: true }
        ListView {
            id: profiles
            objectName: "profiles"
            Layout.fillWidth: true
            Layout.preferredHeight: 120
            clip: true
            currentIndex: -1
            model: shell.profiles
            delegate: ItemDelegate {
                required property var modelData
                required property int index
                width: ListView.view.width
                text: modelData.name
                highlighted: ListView.isCurrentItem
                onClicked: profiles.currentIndex = index
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Repeater {
                id: fields
                model: window.fieldNames
                delegate: RowLayout {
                    required property string modelData
                    readonly property string fieldName: modelData
                    property alias text: input.text
                    Layout.fillWidth: true
                    Label { text: window.labels[modelData]; Layout.preferredWidth: 140 }
                    TextField {
                        id: input
                        objectName: modelData
                        Layout.fillWidth: true
                        text: window.fieldText(modelData)
                    }
                }
            }
        }

        RowLayout {
            Button { objectName: "save"; text: "Save"; onClicked: shell.saveProfile(window.edited()) }
            Button {
                objectName: "use"
                text: "Use This Profile"
                onClicked: if (window.selected) shell.useProfile(window.selected.id)
            }
            Button { objectName: "import"; text: "Import…"; onClicked: shell.importProfile() }
            Button { objectName: "editorSetup"; text: "Set Up VS Code"; onClicked: shell.setUpEditor() }
        }

        CheckBox {
            objectName: "startAtLogin"
            text: "Start SSM Connect when I sign in"
            visible: typeof startup !== "undefined"
            checked: typeof startup !== "undefined" && startup.enabled
            onToggled: startup.setEnabled(checked, executablePath)
        }
        Item { Layout.fillHeight: true }
    }
}
