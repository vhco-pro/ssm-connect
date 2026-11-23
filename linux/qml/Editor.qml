// Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
//
// The profile editor, with the macOS editor's fields: general, SSO, workstation, tunnel, connect
// mode, remote development and web forwards with their proxy suffixes and local forwards. It edits a
// draft and saves it through the shell controller, which sends saveProfile (with the attached-file
// consent and conflict handling) or saveLocalCopy. Each control is named by its parity inventory id.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: editor
    title: draft.name ? "Edit " + draft.name : "New Profile"
    width: 560
    height: 720
    visible: true

    property var draft: ({})
    property bool attached: false

    function ensure() {
        var d = JSON.parse(JSON.stringify(draft || {}))
        if (!d.webForwards) d.webForwards = { "enabled": false, "proxySuffixes": [], "localForwards": [] }
        if (!d.webForwards.proxySuffixes) d.webForwards.proxySuffixes = []
        if (!d.webForwards.localForwards) d.webForwards.localForwards = []
        if (!d.remoteDevelopment) d.remoteDevelopment = { "enabled": false }
        if (!d.connectAction) d.connectAction = { "dcvViewer": {} }
        if (!d.connectMode) d.connectMode = "singleUser"
        return d
    }
    function set(path, value) {
        var d = ensure()
        var parts = path.split(".")
        if (parts.length === 1) d[parts[0]] = value
        else d[parts[0]][parts[1]] = value
        draft = d
    }
    function text(path) {
        var d = draft || {}
        var parts = path.split(".")
        var v = parts.length === 1 ? d[parts[0]] : (d[parts[0]] || {})[parts[1]]
        return v === undefined || v === null ? "" : String(v)
    }

    Component.onCompleted: draft = ensure()

    ScrollView {
        anchors.fill: parent
        anchors.margins: 12
        ColumnLayout {
            width: editor.width - 40
            spacing: 6

            Label { text: "General"; font.bold: true }
            TextField { objectName: "profileeditor-textfield-display-name"; placeholderText: "Display name"; Layout.fillWidth: true
                        text: editor.text("name"); onEditingFinished: editor.set("name", text) }

            Label { text: "AWS SSO"; font.bold: true }
            TextField { objectName: "profileeditor-textfield-sso-start-url"; placeholderText: "SSO start URL"; Layout.fillWidth: true
                        text: editor.text("ssoStartUrl"); onEditingFinished: editor.set("ssoStartUrl", text) }
            TextField { objectName: "profileeditor-textfield-sso-region"; placeholderText: "SSO region"; Layout.fillWidth: true
                        text: editor.text("ssoRegion"); onEditingFinished: editor.set("ssoRegion", text) }
            TextField { objectName: "profileeditor-textfield-account-id"; placeholderText: "Account ID"; Layout.fillWidth: true
                        text: editor.text("accountId"); onEditingFinished: editor.set("accountId", text) }
            TextField { objectName: "profileeditor-textfield-role-name"; placeholderText: "Role name"; Layout.fillWidth: true
                        text: editor.text("roleName"); onEditingFinished: editor.set("roleName", text) }

            Label { text: "Workstation"; font.bold: true }
            TextField { objectName: "profileeditor-textfield-resource-region"; placeholderText: "Resource region"; Layout.fillWidth: true
                        text: editor.text("resourceRegion"); onEditingFinished: editor.set("resourceRegion", text) }
            TextField { objectName: "profileeditor-textfield-instance-tag-key"; placeholderText: "Instance tag key"; Layout.fillWidth: true
                        text: editor.text("instanceTagKey"); onEditingFinished: editor.set("instanceTagKey", text) }
            TextField { objectName: "profileeditor-textfield-instance-tag-value"; placeholderText: "Instance tag value"; Layout.fillWidth: true
                        text: editor.text("instanceTagValue"); onEditingFinished: editor.set("instanceTagValue", text) }
            TextField { objectName: "profileeditor-textfield-dcv-password-secret-id-optional"; placeholderText: "DCV password secret id (optional)"
                        Layout.fillWidth: true; text: editor.text("secretId"); onEditingFinished: editor.set("secretId", text) }

            Label { text: "Tunnel"; font.bold: true }
            RowLayout {
                Label { text: "Local port" }
                TextField { objectName: "profileeditor-textfield-local-port"; Accessible.name: "Local port"; text: editor.text("localPort")
                            validator: IntValidator { bottom: 1; top: 65535 }
                                        onEditingFinished: editor.set("localPort", Number(text)) }
                Label { text: "Remote port" }
                TextField { objectName: "profileeditor-textfield-remote-port"; Accessible.name: "Remote port"; text: editor.text("remotePort")
                            validator: IntValidator { bottom: 1; top: 65535 }
                                        onEditingFinished: editor.set("remotePort", Number(text)) }
            }
            CheckBox { Accessible.onToggleAction: { toggle(); toggled() }
                       objectName: "profileeditor-toggle-open-dcv-viewer-automatically"; text: "Open DCV Viewer automatically"
                       checked: !!editor.draft.connectAction && editor.draft.connectAction.dcvViewer !== undefined
                       onToggled: editor.set("connectAction", checked ? { "dcvViewer": {} } : { "tunnelOnly": {} }) }

            Label { text: "Connect mode"; font.bold: true }
            ComboBox {
                objectName: "profileeditor-picker-mode"; Accessible.name: "Mode"
                model: [ "singleUser", "multiUser" ]
                displayText: currentValue === "multiUser" ? "Multi-user" : "Single-user"
                currentIndex: editor.text("connectMode") === "multiUser" ? 1 : 0
                onActivated: editor.set("connectMode", currentValue)
            }
            RowLayout {
                visible: editor.text("connectMode") === "multiUser"
                Label { text: "Agent port" }
                TextField { objectName: "profileeditor-textfield-agent-port"; Accessible.name: "Agent port"; text: editor.text("agentRemotePort")
                            validator: IntValidator { bottom: 1; top: 65535 }
                                        onEditingFinished: editor.set("agentRemotePort", Number(text)) }
            }

            Label { text: "Remote Development"; font.bold: true }
            CheckBox { Accessible.onToggleAction: { toggle(); toggled() }
                       objectName: "profileeditor-toggle-enable-native-vs-code-access"; text: "Enable native VS Code access"
                       checked: editor.text("remoteDevelopment.enabled") === "true"
                       onToggled: editor.set("remoteDevelopment.enabled", checked) }
            TextField { objectName: "profileeditor-textfield-remote-folder-optional"; placeholderText: "Remote folder (optional), /home/user/code/project"
                        Layout.fillWidth: true; enabled: editor.text("remoteDevelopment.enabled") === "true"
                        text: editor.text("remoteDevelopment.folder"); onEditingFinished: editor.set("remoteDevelopment.folder", text) }

            Label { text: "Web Forwards"; font.bold: true }
            CheckBox { Accessible.onToggleAction: { toggle(); toggled() }
                       objectName: "profileeditor-toggle-enable-web-forwards"; text: "Enable web forwards"
                       checked: editor.text("webForwards.enabled") === "true"; onToggled: editor.set("webForwards.enabled", checked) }
            ColumnLayout {
                enabled: editor.text("webForwards.enabled") === "true"
                Layout.fillWidth: true
                TextField { objectName: "profileeditor-textfield-ssh-user-optional"; placeholderText: "SSH user (optional)"; Layout.fillWidth: true
                            text: editor.text("webForwards.sshUser"); onEditingFinished: editor.set("webForwards.sshUser", text) }
                RowLayout {
                    CheckBox { Accessible.onToggleAction: { toggle(); toggled() }
                               objectName: "profileeditor-toggle-socks-proxy"; text: "SOCKS proxy"
                               checked: editor.text("webForwards.socksPort") !== ""
                               onToggled: editor.set("webForwards.socksPort", checked ? 1080 : null) }
                    TextField { objectName: "profileeditor-textfield-socks-port"; Accessible.name: "SOCKS port"; visible: editor.text("webForwards.socksPort") !== ""
                                text: editor.text("webForwards.socksPort"); validator: IntValidator { bottom: 1; top: 65535 }
                                onEditingFinished: editor.set("webForwards.socksPort", Number(text)) }
                }
                RowLayout {
                    Label { text: "Browser" }
                    ComboBox { objectName: "profileeditor-picker-browser"; Accessible.name: "Browser"; model: [ "automatic", "chrome", "zen" ]
                               currentIndex: Math.max(0, model.indexOf(editor.text("webForwards.browser")))
                               onActivated: editor.set("webForwards.browser", currentValue) }
                    Label { text: "Browser Mode" }
                    ComboBox { objectName: "profileeditor-picker-browser-mode"; Accessible.name: "Browser Mode"; model: [ "separate", "existing" ]
                               displayText: currentValue === "existing" ? "Use My Browser" : "Separate Browser"
                               currentIndex: editor.text("webForwards.browserMode") === "existing" ? 1 : 0
                               onActivated: editor.set("webForwards.browserMode", currentValue) }
                }
                RowLayout {
                    visible: editor.text("webForwards.browserMode") === "existing"
                    Label { text: "Profile: " + (editor.text("webForwards.browserProfilePath") || "Not selected") }
                    Button { objectName: "profileeditor-button-choose-profile-folder"; text: "Choose Profile Folder"
                             onClicked: { var p = shell.chooseFolder("Choose the Zen profile folder"); if (p) editor.set("webForwards.browserProfilePath", p) } }
                }
                Label { text: "Zen only. Chrome requires a separately approved proxy extension and is unavailable in this mode."
                        visible: editor.text("webForwards.browserMode") === "existing"; font.pixelSize: 11 }
                Repeater {
                    model: editor.draft.webForwards ? editor.draft.webForwards.proxySuffixes : []
                    delegate: RowLayout {
                        required property string modelData
                        required property int index
                        TextField { objectName: "profileeditor-textfield-domain-suffix"; placeholderText: ".internal.example.com"; text: modelData
                                    Layout.fillWidth: true
                                    onEditingFinished: { var d = editor.ensure(); d.webForwards.proxySuffixes[index] = text; editor.draft = d } }
                        ToolButton { objectName: "profileeditor-button-remove-domain"; text: "−"; ToolTip.text: "Remove domain"; ToolTip.visible: hovered
                                     onClicked: { var d = editor.ensure(); d.webForwards.proxySuffixes.splice(index, 1); editor.draft = d } }
                    }
                }
                Button { objectName: "profileeditor-button-add-a-proxy-domain-suffix"; text: "Add Domain"
                         onClicked: { var d = editor.ensure(); d.webForwards.proxySuffixes.push(""); editor.draft = d } }
                Repeater {
                    model: editor.draft.webForwards ? editor.draft.webForwards.localForwards : []
                    delegate: ColumnLayout {
                        required property var modelData
                        required property int index
                        function update(key, value) { var d = editor.ensure(); d.webForwards.localForwards[index][key] = value; editor.draft = d }
                        RowLayout {
                            TextField { objectName: "profileeditor-textfield-name"; placeholderText: "Name"; text: modelData.name || ""
                                        onEditingFinished: update("name", text) }
                            ToolButton { objectName: "profileeditor-button-remove-local-forward"; text: "−"; ToolTip.text: "Remove local forward"
                                         ToolTip.visible: hovered
                                         onClicked: { var d = editor.ensure(); d.webForwards.localForwards.splice(index, 1); editor.draft = d } }
                        }
                        RowLayout {
                            Label { text: "Local port" }
                            TextField { objectName: "profileeditor-textfield-local-port-2"; Accessible.name: "Forward local port"; text: String(modelData.localPort || "")
                                        onEditingFinished: update("localPort", Number(text)) }
                            Label { text: "Remote port" }
                            TextField { objectName: "profileeditor-textfield-remote-port-2"; Accessible.name: "Forward remote port"; text: String(modelData.remotePort || "")
                                        onEditingFinished: update("remotePort", Number(text)) }
                        }
                        TextField { objectName: "profileeditor-textfield-remote-host"; placeholderText: "Remote host"; text: modelData.remoteHost || ""
                                    onEditingFinished: update("remoteHost", text) }
                        TextField { objectName: "profileeditor-textfield-open-path-optional"; placeholderText: "Open path (optional)"
                                    text: modelData.openPath || ""; onEditingFinished: update("openPath", text) }
                    }
                }
                Button { objectName: "profileeditor-button-add-local-forward"; text: "Add Local Forward"
                         onClicked: { var d = editor.ensure()
                                      d.webForwards.localForwards.push({ "name": "New Forward", "localPort": 8080, "remoteHost": "127.0.0.1", "remotePort": 8080 })
                                      editor.draft = d } }
            }

            RowLayout {
                Layout.topMargin: 12
                Button { objectName: "profileeditor-button-cancel"; text: "Cancel"; onClicked: editor.close() }
                Item { Layout.fillWidth: true }
                Button { objectName: "profileeditor-button-save-a-local-copy"; text: "Save a Local Copy"
                         visible: shell.isOffered(objectName, { "item.attached": editor.attached ? "true" : "false" })
                         onClicked: { shell.trigger(objectName, { "profile": JSON.stringify(editor.draft) }, { "item.attached": "true" }); editor.close() } }
                Button { objectName: "profileeditor-button-save"; text: "Save"; highlighted: true
                         onClicked: { shell.saveProfile(editor.draft); editor.close() } }
            }
        }
    }
}
