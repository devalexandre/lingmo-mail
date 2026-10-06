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

// Add or edit a contact of the local address book
MailPopup {
    id: dialog

    property string contactId: ""
    property bool wasCollected: false
    property string errorText: ""

    title: contactId ? qsTr("Editar contato") : qsTr("Novo contato")
    width: Math.min(520, parent ? parent.width - 80 : 520)
    closePolicy: Popup.CloseOnEscape

    function edit(contact) {
        contact = contact || {}
        contactId = contact.id || ""
        wasCollected = !!contact.collected
        nameField.text = contact.name || ""
        emailsField.text = (contact.emails || []).join(", ")
        phoneField.text = contact.phone || ""
        notesArea.text = contact.notes || ""
        errorText = ""
        open()
        nameField.forceActiveFocus()
    }

    function submit() {
        errorText = ""
        Mail.saveContact({ id: contactId, name: nameField.text, emails: emailsField.text,
                           phone: phoneField.text, notes: notesArea.text })
    }

    Connections {
        target: Mail
        enabled: dialog.visible
        function onContactSaved() { dialog.close() }
        function onContactFailed(error) { dialog.errorText = error }
    }

    ColumnLayout {
        width: parent.width
        spacing: LingmoUI.Units.largeSpacing

        Banner {
            Layout.fillWidth: true
            text: dialog.errorText
            onClosed: dialog.errorText = ""
        }

        Banner {
            Layout.fillWidth: true
            error: false
            closable: false
            text: dialog.wasCollected ? qsTr("Coletado automaticamente de uma mensagem enviada. Ao salvar, vira um contato seu.") : ""
        }

        LingmoUI.RoundedRect {
            Layout.fillWidth: true
            implicitHeight: grid.implicitHeight + LingmoUI.Units.largeSpacing * 2
            radius: LingmoUI.Theme.mediumRadius
            color: LingmoUI.Theme.backgroundColor

            GridLayout {
                id: grid
                anchors.fill: parent
                anchors.margins: LingmoUI.Units.largeSpacing
                columns: 2
                columnSpacing: LingmoUI.Units.largeSpacing
                rowSpacing: LingmoUI.Units.smallSpacing

                Label { text: qsTr("Nome:"); color: LingmoUI.Theme.disabledTextColor }
                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    maximumLength: 200
                    selectByMouse: true
                    validator: RegularExpressionValidator { regularExpression: /[^\r\n]*/ }
                }
                Label { text: qsTr("E-mails:"); color: LingmoUI.Theme.disabledTextColor }
                TextField {
                    id: emailsField
                    Layout.fillWidth: true
                    selectByMouse: true
                    placeholderText: qsTr("nome@exemplo.com, outro@exemplo.com")
                    inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                    validator: RegularExpressionValidator { regularExpression: /[^\r\n]*/ }
                }
                Label { text: qsTr("Telefone:"); color: LingmoUI.Theme.disabledTextColor }
                TextField {
                    id: phoneField
                    Layout.fillWidth: true
                    maximumLength: 40
                    selectByMouse: true
                    inputMethodHints: Qt.ImhDialableCharactersOnly
                    validator: RegularExpressionValidator { regularExpression: /[0-9+()\-. ]*/ }
                }
                Label {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: LingmoUI.Units.smallSpacing
                    text: qsTr("Notas:")
                    color: LingmoUI.Theme.disabledTextColor
                }
                ScrollView {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 110
                    clip: true
                    TextArea {
                        id: notesArea
                        textFormat: TextEdit.PlainText
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        color: LingmoUI.Theme.textColor
                    }
                }
            }
        }
    }

    buttons: [
        Item { Layout.fillWidth: true },
        ActionButton {
            text: qsTr("Cancelar")
            onClicked: dialog.close()
        },
        ActionButton {
            primary: true
            text: qsTr("Salvar")
            enabled: nameField.text.trim() || emailsField.text.trim()
            onClicked: dialog.submit()
        }
    ]
}
