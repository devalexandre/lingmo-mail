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

// Local address book: saved contacts and addresses collected from sent mail
Item {
    id: control

    signal writeRequested(string recipient)
    signal editRequested(var contact)

    readonly property var tileColors: [LingmoUI.Theme.blueColor, LingmoUI.Theme.purpleColor, LingmoUI.Theme.orangeColor,
                                       LingmoUI.Theme.greenColor, LingmoUI.Theme.pinkColor, LingmoUI.Theme.redColor]

    readonly property var filtered: {
        const query = search.text.trim().toLowerCase()
        const kind = show.currentIndex   // 0 all, 1 mine, 2 collected
        return Mail.contacts.filter(c => {
            if ((kind === 1 && c.collected) || (kind === 2 && !c.collected))
                return false
            if (!query)
                return true
            return (c.name + " " + c.emails.join(" ") + " " + c.phone).toLowerCase().indexOf(query) >= 0
        })
    }

    function recipient(contact) {
        const address = contact.emails[0] || ""
        if (!contact.name || /[,;<>"@()]/.test(contact.name))
            return address
        return "%1 <%2>".arg(contact.name).arg(address)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.rightMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.bottomMargin: LingmoUI.Units.largeSpacing * 1.5
        spacing: LingmoUI.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.largeSpacing

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Label {
                    text: qsTr("Contatos")
                    font.pointSize: LingmoUI.Theme.fontSize * 1.5
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                }
                Label {
                    Layout.fillWidth: true
                    text: qsTr("Guardados só neste computador. Quem recebe suas mensagens entra como coletado automaticamente.")
                    color: LingmoUI.Theme.disabledTextColor
                    wrapMode: Text.Wrap
                }
            }
            ActionButton {
                primary: true
                text: qsTr("Novo contato")
                onClicked: control.editRequested({})
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.largeSpacing

            TextField {
                id: search
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                placeholderText: qsTr("Buscar por nome, e-mail ou telefone…")
                selectByMouse: true
                leftPadding: LingmoUI.Units.largeSpacing
                color: LingmoUI.Theme.textColor
                placeholderTextColor: LingmoUI.Theme.disabledTextColor
                Keys.onEscapePressed: text = ""
                background: Rectangle {
                    radius: height / 2
                    color: LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.05)
                    border.width: search.activeFocus ? 2 : 0
                    border.color: LingmoUI.Theme.highlightColor
                }
            }
            ComboBox {
                id: show
                Layout.preferredWidth: 230
                model: [qsTr("Todos"), qsTr("Meus contatos"), qsTr("Coletados automaticamente")]
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: LingmoUI.Units.smallSpacing
            model: control.filtered
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            LingmoUI.WheelHandler { target: list }

            delegate: LingmoUI.RoundedRect {
                id: card
                required property var modelData
                required property int index
                width: ListView.view.width
                implicitHeight: row.implicitHeight + LingmoUI.Units.largeSpacing * 1.5
                radius: LingmoUI.Theme.mediumRadius
                color: hover.hovered ? LingmoUI.Theme.alternateBackgroundColor : LingmoUI.Theme.secondBackgroundColor
                HoverHandler { id: hover }

                RowLayout {
                    id: row
                    anchors.fill: parent
                    anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                    anchors.rightMargin: LingmoUI.Units.largeSpacing
                    spacing: LingmoUI.Units.largeSpacing

                    Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        radius: 16
                        color: control.tileColors[(card.modelData.name || card.modelData.emails[0] || "?").charCodeAt(0) % control.tileColors.length]
                        Label {
                            anchors.centerIn: parent
                            text: (card.modelData.name || card.modelData.emails[0] || "?")[0].toUpperCase()
                            color: LingmoUI.Theme.highlightedTextColor
                            font.bold: true
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        RowLayout {
                            Layout.fillWidth: true
                            Label {
                                Layout.fillWidth: true
                                text: card.modelData.name || card.modelData.emails[0]
                                font.bold: true
                                color: LingmoUI.Theme.textColor
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                            Label {
                                visible: card.modelData.collected
                                text: qsTr("Coletado automaticamente")
                                color: LingmoUI.Theme.disabledTextColor
                                font.pointSize: LingmoUI.Theme.fontSize * 0.85
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            text: [card.modelData.emails.join(", "), card.modelData.phone].filter(x => x).join("  ·  ")
                            color: LingmoUI.Theme.disabledTextColor
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                    }

                    IconButton {
                        iconName: "mail-message-new"
                        tipText: qsTr("Escrever e-mail")
                        enabled: card.modelData.emails.length > 0 && Mail.currentAccountId !== ""
                        onClicked: control.writeRequested(control.recipient(card.modelData))
                    }
                    IconButton {
                        iconName: "document-edit"
                        tipText: qsTr("Editar")
                        onClicked: control.editRequested(card.modelData)
                    }
                    IconButton {
                        iconName: "edit-delete"
                        tipText: qsTr("Apagar contato")
                        onClicked: {
                            deleteConfirm.contactId = card.modelData.id
                            deleteConfirm.text = qsTr("%1 será apagado da sua agenda.")
                                                 .arg(card.modelData.name || card.modelData.emails[0])
                            deleteConfirm.open()
                        }
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 420)
                visible: list.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: LingmoUI.Theme.disabledTextColor
                font.pointSize: LingmoUI.Theme.fontSize * 1.1
                text: !Mail.contactsLoaded ? qsTr("Carregando contatos…")
                    : search.text.trim() ? qsTr("Nenhum contato encontrado")
                    : qsTr("Nenhum contato ainda")
            }
        }
    }

    ConfirmDialog {
        id: deleteConfirm
        property string contactId: ""
        title: qsTr("Apagar contato?")
        acceptText: qsTr("Apagar")
        destructive: true
        onAccepted: Mail.deleteContact(contactId)
    }
}
