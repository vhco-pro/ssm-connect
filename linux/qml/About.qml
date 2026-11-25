// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// About SSM Connect, as the macOS About window: version, system, licence, project and release notes
// links, and the connection states legend.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: about
    title: "About SSM Connect"
    width: 460
    height: 420
    visible: true

    property string version: typeof buildVersion !== "undefined" ? buildVersion : ""
    property bool showStates: false

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8
        Label { text: "SSM Connect"; font.bold: true; font.pixelSize: 18 }
        Label { text: "Version " + about.version }
        GridLayout {
            columns: 2
            Label { text: "License" }
            Button {
                Accessible.onPressAction: clicked() // screen readers: Qt 6.4 does not click on the press action
                objectName: "about-link-apache-license-2-0"; text: "Apache License 2.0"; flat: true; onClicked: shell.trigger(objectName) }
        }
        RowLayout {
            Button {
                Accessible.onPressAction: clicked() // screen readers: Qt 6.4 does not click on the press action
                objectName: "about-link-project"; text: "Project"; flat: true; onClicked: shell.trigger(objectName) }
            Button {
                Accessible.onPressAction: clicked() // screen readers: Qt 6.4 does not click on the press action
                objectName: "about-link-release-notes"; text: "Release Notes"; flat: true; onClicked: shell.trigger(objectName) }
        }
        Button {
            Accessible.onPressAction: clicked() // screen readers: Qt 6.4 does not click on the press action
            objectName: "about-disclosuregroup-connection-states"
            text: (about.showStates ? "▾ " : "▸ ") + "Connection States"
            flat: true
            onClicked: about.showStates = !about.showStates
        }
        ColumnLayout {
            visible: about.showStates
            Repeater {
                model: [ "Disconnected: idle, not connected", "Authenticating: SSO sign-in", "Resolving: finding the instance by its tag",
                         "Starting: starting a stopped workstation", "Waiting for SSM: waiting for the SSM agent",
                         "Tunneling: starting the session and the plugin", "Connected: the tunnel is up", "Error: something failed" ]
                delegate: Label { required property string modelData; text: modelData }
            }
        }
        Item { Layout.fillHeight: true }
    }
}
