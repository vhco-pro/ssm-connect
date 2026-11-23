// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The connection log, as the macOS Log window shows it: entries from the helper's getLog, and Clear.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: log
    title: "SSM Connect Log"
    width: 640
    height: 420
    visible: true

    property var entries: []

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        Label { text: "Connection events appear here as they happen."; visible: log.entries.length === 0 }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: log.entries
            delegate: Label {
                required property var modelData
                width: ListView.view.width
                wrapMode: Text.Wrap
                text: modelData.time + "  [" + modelData.category + "]  " + modelData.message
            }
        }
        RowLayout {
            Label { text: log.entries.length + " entries" }
            Item { Layout.fillWidth: true }
            Button { objectName: "log-button-clear"; text: "Clear"; onClicked: { shell.trigger(objectName); log.entries = [] } }
        }
    }
}
