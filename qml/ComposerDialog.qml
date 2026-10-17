/*
 * Copyright (C) 2026 LingmoOS Team.
 *
 * Author:     devalexandre <alexandre@dev2learn.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LingmoUI.CompatibleModule 3.0 as LingmoUI
import Lingmo.Mail

// Write a new message, a reply or a forward (plain text)
MailPopup {
    id: dialog

    property string inReplyTo: ""
    property string references: ""
    property string errorText: ""
    property string initialBody: ""
    property bool showCc: false

    title: inReplyTo ? qsTr("Responder") : subjectField.text.match(/^fwd?:/i) ? qsTr("Encaminhar") : qsTr("Nova mensagem")
    width: Math.min(760, parent ? parent.width - 80 : 760)
    height: Math.min(640, parent ? parent.height - 60 : 640)

    readonly property bool edited: toField.text.trim() || ccField.text.trim()
                                   || (bodyArea.text !== initialBody && bodyArea.text.trim())

    function compose(draft) {
        draft = draft || {}
        toField.text = draft.to || ""
        ccField.text = draft.cc || ""
        subjectField.text = draft.subject || ""
        bodyArea.text = draft.body || ""
        initialBody = bodyArea.text
        inReplyTo = draft.inReplyTo || ""
        references = draft.references || ""
        showCc = !!ccField.text
        errorText = ""
        open()
        if (toField.text) {
            bodyArea.forceActiveFocus()
            bodyArea.cursorPosition = 0
        } else {
            toField.forceActiveFocus()
        }
    }

    function discard() {
        if (edited && !Mail.sending)
            discardConfirm.open()
        else
            close()
    }

    function submit() {
        errorText = ""
        Mail.send({ to: toField.text, cc: ccField.text, subject: subjectField.text, body: bodyArea.text,
                    inReplyTo: inReplyTo, references: references })
    }

    // Escape asks first when there is something to lose
    closePolicy: Popup.NoAutoClose
    Shortcut {
        sequence: "Escape"
        enabled: dialog.visible && !discardConfirm.visible && !toField.suggesting && !ccField.suggesting
        onActivated: dialog.discard()
    }
    Shortcut {
        sequence: "Ctrl+Return"
        enabled: dialog.visible && !Mail.sending && !toField.suggesting && !ccField.suggesting
        onActivated: dialog.submit()
    }

    Connections {
        target: Mail
        enabled: dialog.visible
        function onSent() { dialog.close() }
        function onSendFailed(error) { dialog.errorText = error }
    }

    ConfirmDialog {
        id: discardConfirm
        title: qsTr("Descartar mensagem?")
        text: qsTr("O texto escrito será perdido.")
        acceptText: qsTr("Descartar")
        destructive: true
        onAccepted: dialog.close()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: LingmoUI.Units.largeSpacing

        LingmoUI.Banner {
            type: LingmoUI.Banner.Error
            Layout.fillWidth: true
            text: dialog.errorText
            onClosed: dialog.errorText = ""
        }

        LingmoUI.RoundedRect {
            Layout.fillWidth: true
            implicitHeight: fields.implicitHeight + LingmoUI.Units.largeSpacing * 2
            radius: LingmoUI.Theme.mediumRadius
            color: LingmoUI.Theme.backgroundColor

            GridLayout {
                id: fields
                anchors.fill: parent
                anchors.margins: LingmoUI.Units.largeSpacing
                columns: 2
                columnSpacing: LingmoUI.Units.largeSpacing
                rowSpacing: LingmoUI.Units.smallSpacing
                enabled: !Mail.sending

                Label { text: qsTr("De:"); color: LingmoUI.Theme.secondaryTextColor; font.pointSize: LingmoUI.Units.fontBody }
                Label {
                    font.pointSize: LingmoUI.Units.fontBody
                    Layout.fillWidth: true
                    text: {
                        const a = Mail.currentAccount
                        return a.name ? "%1 <%2>".arg(a.name).arg(a.email) : (a.email || "")
                    }
                    color: LingmoUI.Theme.textColor
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }

                Label { text: qsTr("Para:"); color: LingmoUI.Theme.secondaryTextColor; font.pointSize: LingmoUI.Units.fontBody }
                RowLayout {
                    Layout.fillWidth: true
                    RecipientField {
                        id: toField
                        Layout.fillWidth: true
                        placeholderText: qsTr("nome@exemplo.com, outra@exemplo.com")
                    }
                    LingmoUI.ActionButton {
                        visible: !dialog.showCc
                        text: qsTr("Cc")
                        onClicked: {
                            dialog.showCc = true
                            ccField.forceActiveFocus()
                        }
                    }
                }

                Label { visible: dialog.showCc; text: qsTr("Cc:"); color: LingmoUI.Theme.secondaryTextColor; font.pointSize: LingmoUI.Units.fontBody }
                RecipientField {
                    id: ccField
                    visible: dialog.showCc
                    Layout.fillWidth: true
                }

                Label { text: qsTr("Assunto:"); color: LingmoUI.Theme.secondaryTextColor; font.pointSize: LingmoUI.Units.fontBody }
                TextField {
                    id: subjectField
                    Layout.fillWidth: true
                    selectByMouse: true
                    // One line only: headers can't carry line breaks
                    validator: RegularExpressionValidator { regularExpression: /[^\r\n]*/ }
                }
            }
        }

        LingmoUI.RoundedRect {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: LingmoUI.Theme.mediumRadius
            color: LingmoUI.Theme.backgroundColor

            ScrollView {
                anchors.fill: parent
                anchors.margins: LingmoUI.Units.smallSpacing
                clip: true

                TextArea {
                    id: bodyArea
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    readOnly: Mail.sending
                    color: LingmoUI.Theme.textColor
                    placeholderText: qsTr("Escreva sua mensagem…")
                    placeholderTextColor: LingmoUI.Theme.disabledTextColor
                    background: null
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: subjectField.text.match(/^fwd?:/i) !== null && !dialog.inReplyTo
            text: qsTr("Os anexos da mensagem original não são encaminhados.")
            color: LingmoUI.Theme.secondaryTextColor
            font.pointSize: LingmoUI.Units.fontCaption
            wrapMode: Text.Wrap
        }
    }

    buttons: [
        LingmoUI.Spinner {
                        running: Mail.sending
        },
        Label {
            font.pointSize: LingmoUI.Units.fontCaption
            Layout.fillWidth: true
            text: Mail.sending ? qsTr("Enviando…") : qsTr("Ctrl+Enter para enviar")
            color: LingmoUI.Theme.secondaryTextColor
            elide: Text.ElideRight
        },
        LingmoUI.ActionButton {
            text: qsTr("Descartar")
            enabled: !Mail.sending
            onClicked: dialog.discard()
        },
        LingmoUI.ActionButton {
            primary: true
            text: qsTr("Enviar")
            enabled: !Mail.sending && toField.text.trim().length > 0
            onClicked: dialog.submit()
        }
    ]
}
