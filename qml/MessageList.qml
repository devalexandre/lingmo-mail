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

// Middle pane: the latest messages in the inbox
Item {
    id: control

    implicitWidth: 340

    readonly property var filtered: {
        const query = search.text.trim().toLowerCase()
        if (!query)
            return Mail.messages
        return Mail.messages.filter(m => (m.subject + " " + m.sender).toLowerCase().indexOf(query) >= 0)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: LingmoUI.Units.largeSpacing
        spacing: LingmoUI.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.smallSpacing

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Label {
                    Layout.fillWidth: true
                    text: qsTr("Caixa de entrada")
                    font.pointSize: LingmoUI.Theme.fontSize * 1.3
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                    elide: Text.ElideRight
                }
                Label {
                    Layout.fillWidth: true
                    text: Mail.currentAccount.email || ""
                    color: LingmoUI.Theme.disabledTextColor
                    font.pointSize: LingmoUI.Theme.fontSize * 0.85
                    elide: Text.ElideRight
                }
            }

            Spinner {
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                running: Mail.loadingInbox && Mail.inboxLoaded
            }

            ActionButton {
                text: qsTr("Atualizar")
                enabled: Mail.currentAccountId !== "" && !Mail.loadingInbox
                onClicked: Mail.refresh()
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Buscar mensagens novas (F5)")
            }
        }

        TextField {
            id: search
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            placeholderText: qsTr("Filtrar por assunto ou remetente…")
            enabled: Mail.messages.length > 0
            selectByMouse: true
            leftPadding: LingmoUI.Units.largeSpacing
            color: LingmoUI.Theme.textColor
            placeholderTextColor: LingmoUI.Theme.disabledTextColor
            font.pointSize: LingmoUI.Theme.fontSize

            // Pill-shaped, like the store's search field
            background: Rectangle {
                radius: height / 2
                color: LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.05)
                border.width: search.activeFocus ? 2 : 0
                border.color: LingmoUI.Theme.highlightColor
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: control.filtered
            ScrollBar.vertical: ScrollBar {}
            keyNavigationEnabled: true

            LingmoUI.WheelHandler { target: list }

            delegate: ItemDelegate {
                id: row
                required property var modelData
                required property int index
                readonly property bool current: modelData.id === Mail.currentMessageId

                width: ListView.view.width
                height: 64
                hoverEnabled: true
                onClicked: Mail.openMessage(modelData.id)
                Accessible.name: modelData.senderName + ", " + modelData.subject

                background: Rectangle {
                    radius: LingmoUI.Theme.mediumRadius
                    color: row.current ? LingmoUI.Theme.highlightColor
                         : row.hovered ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                 LingmoUI.Theme.textColor.b, 0.1)
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
                }

                contentItem: ColumnLayout {
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: row.modelData.senderName || qsTr("(Sem remetente)")
                            font.bold: true
                            color: row.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                        Label {
                            text: row.modelData.when || ""
                            color: row.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.disabledTextColor
                            font.pointSize: LingmoUI.Theme.fontSize * 0.85
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: row.modelData.subject
                        color: row.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                        opacity: 0.85
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                }
            }

            // ---------- Empty and loading states
            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - LingmoUI.Units.largeSpacing * 2
                spacing: LingmoUI.Units.largeSpacing
                visible: list.count === 0

                Spinner {
                    Layout.alignment: Qt.AlignHCenter
                    running: Mail.loadingInbox && !Mail.inboxLoaded
                }
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: LingmoUI.Theme.disabledTextColor
                    text: {
                        if (Mail.currentAccountId === "")
                            return qsTr("Adicione uma conta para ver suas mensagens")
                        if (Mail.loadingInbox && !Mail.inboxLoaded)
                            return qsTr("Carregando mensagens…")
                        if (!Mail.inboxLoaded)
                            return qsTr("Não foi possível carregar a caixa de entrada")
                        if (search.text.trim())
                            return qsTr("Nenhuma mensagem encontrada")
                        return qsTr("Nenhuma mensagem na caixa de entrada")
                    }
                }
                ActionButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: Mail.currentAccountId !== "" && !Mail.inboxLoaded && !Mail.loadingInbox
                    text: qsTr("Tentar novamente")
                    onClicked: Mail.refresh()
                }
            }
        }
    }
}
