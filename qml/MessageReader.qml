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

// Right pane: the open message, as plain text only (no HTML, no remote content)
Item {
    id: control

    signal replyRequested()
    signal forwardRequested()
    signal ruleRequested(var message)
    signal moveRequested(var ids, Item anchor)

    readonly property bool imap: Mail.currentIsImap
    // The calendar side's singleton (Lingmo.Mail shadows QtQuick.Controls' own Calendar type,
    // which has no createTask)
    readonly property bool calendarAvailable: typeof Calendar !== "undefined" && typeof Calendar.createTask === "function"

    function createTask() {
        if (!calendarAvailable)
            return
        const body = (message.body || "").replace(/\s+/g, " ").trim()
        const notes = qsTr("De: %1").arg(message.sender || "") + "\n\n" + body.substring(0, 500)
        Calendar.createTask(message.subject || "", notes, "")
    }

    readonly property var message: Mail.message
    readonly property bool hasMessage: Mail.currentMessageId !== ""
    readonly property bool loaded: !!message.loaded

    // ---------- Nothing open
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 360)
        visible: !control.hasMessage
        spacing: LingmoUI.Units.largeSpacing

        Image {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 72
            Layout.preferredHeight: 72
            source: "qrc:/lingmo-mail.svg"
            sourceSize: Qt.size(144, 144)
            opacity: 0.45
        }
        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: Mail.currentAccountId !== "" ? qsTr("Selecione uma mensagem para ler")
                                               : qsTr("Nenhuma conta selecionada")
            color: LingmoUI.Theme.disabledTextColor
            font.pointSize: LingmoUI.Theme.fontSize * 1.1
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: LingmoUI.Units.largeSpacing * 1.5
        spacing: LingmoUI.Units.largeSpacing
        visible: control.hasMessage

        // ---------- Headers
        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.largeSpacing

            Label {
                Layout.fillWidth: true
                text: control.message.subject || ""
                font.pointSize: LingmoUI.Theme.fontSize * 1.45
                font.bold: true
                color: LingmoUI.Theme.textColor
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            ActionButton {
                Layout.alignment: Qt.AlignTop
                text: qsTr("Responder")
                enabled: control.loaded
                onClicked: control.replyRequested()
            }
            ActionButton {
                Layout.alignment: Qt.AlignTop
                text: qsTr("Encaminhar")
                enabled: control.loaded
                onClicked: control.forwardRequested()
            }
        }

        // ---------- Actions on this message
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: -LingmoUI.Units.smallSpacing
            spacing: 2

            IconButton {
                visible: control.imap
                iconName: control.message.starred ? "rating" : "rating-unrated"
                tipText: control.message.starred ? qsTr("Remover estrela (S)") : qsTr("Marcar com estrela (S)")
                onClicked: Mail.setStarred([Mail.currentMessageId], !control.message.starred)
            }
            IconButton {
                visible: control.imap
                iconName: "mail-mark-unread"
                tipText: qsTr("Marcar como não lida (Ctrl+U)")
                enabled: !control.message.unread
                onClicked: Mail.markRead([Mail.currentMessageId], false)
            }
            IconButton {
                visible: control.imap
                iconName: "mail-archive"
                tipText: qsTr("Arquivar (E)")
                onClicked: Mail.archive([Mail.currentMessageId])
            }
            IconButton {
                id: moveButton
                visible: control.imap
                iconName: "folder"
                tipText: qsTr("Mover para…")
                onClicked: control.moveRequested([Mail.currentMessageId], moveButton)
            }
            IconButton {
                visible: control.imap
                iconName: "edit-delete"
                tipText: Mail.currentFolderRole === "trash" ? qsTr("Apagar definitivamente (Del)")
                                                             : qsTr("Mover para a Lixeira (Del)")
                onClicked: Mail.deleteMessages([Mail.currentMessageId], false)
            }

            Item { Layout.fillWidth: true }

            ActionButton {
                visible: control.calendarAvailable
                text: qsTr("Criar tarefa")
                enabled: control.loaded
                onClicked: control.createTask()
            }
            IconButton {
                id: moreButton
                iconName: "view-more-symbolic"
                tipText: qsTr("Mais ações")
                enabled: control.loaded
                onClicked: moreMenu.popup(moreButton, 0, moreButton.height)

                Menu {
                    id: moreMenu
                    MenuItem {
                        text: qsTr("Criar regra a partir desta mensagem…")
                        enabled: control.imap
                        onTriggered: control.ruleRequested(control.message)
                    }
                    MenuItem {
                        text: qsTr("Adicionar remetente aos contatos")
                        onTriggered: Mail.saveContact({ name: control.message.senderName !== control.message.senderAddress
                                                              ? control.message.senderName : "",
                                                        emails: [control.message.senderAddress] })
                    }
                    MenuItem {
                        visible: control.calendarAvailable
                        height: visible ? implicitHeight : 0
                        text: qsTr("Criar tarefa")
                        onTriggered: control.createTask()
                    }
                }
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: LingmoUI.Units.largeSpacing
            rowSpacing: 2

            Label { text: qsTr("De:"); color: LingmoUI.Theme.disabledTextColor }
            Label {
                Layout.fillWidth: true
                text: control.message.sender || ""
                color: LingmoUI.Theme.textColor
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Label { text: qsTr("Para:"); color: LingmoUI.Theme.disabledTextColor }
            Label {
                Layout.fillWidth: true
                text: control.message.to || ""
                color: LingmoUI.Theme.textColor
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Label {
                visible: !!control.message.cc
                text: qsTr("Cc:")
                color: LingmoUI.Theme.disabledTextColor
            }
            Label {
                visible: !!control.message.cc
                Layout.fillWidth: true
                text: control.message.cc || ""
                color: LingmoUI.Theme.textColor
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Label { text: qsTr("Data:"); color: LingmoUI.Theme.disabledTextColor }
            Label {
                Layout.fillWidth: true
                text: control.message.fullDate || ""
                color: LingmoUI.Theme.textColor
                elide: Text.ElideRight
            }
        }

        // ---------- Calendar invitations: shown by the calendar's InviteCard when installed
        Repeater {
            model: control.loaded ? (control.message.calendarParts || []) : []
            delegate: ColumnLayout {
                id: inviteBlock
                required property string modelData
                Layout.fillWidth: true
                spacing: 0

                Loader {
                    id: invite
                    Layout.fillWidth: true
                    Component.onCompleted: setSource("qrc:/qml/InviteCard.qml", {
                        icsText: inviteBlock.modelData,
                        accountId: Mail.currentAccountId,
                        organizerReplyTo: control.message.replyTo || control.message.sender || ""
                    })
                }

                // Without the calendar part: a neutral note instead
                LingmoUI.RoundedRect {
                    Layout.fillWidth: true
                    visible: invite.status === Loader.Error
                    implicitHeight: inviteNote.implicitHeight + LingmoUI.Units.largeSpacing * 1.5
                    radius: LingmoUI.Theme.smallRadius
                    color: LingmoUI.Theme.alternateBackgroundColor
                    Label {
                        id: inviteNote
                        anchors.fill: parent
                        anchors.margins: LingmoUI.Units.largeSpacing * 0.75
                        verticalAlignment: Text.AlignVCenter
                        text: qsTr("Esta mensagem contém um convite de calendário.")
                        color: LingmoUI.Theme.disabledTextColor
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        // ---------- Attachments (names only: nothing is opened or downloaded)
        ColumnLayout {
            Layout.fillWidth: true
            visible: control.loaded && (control.message.attachments || []).length > 0
            spacing: LingmoUI.Units.smallSpacing

            Flow {
                Layout.fillWidth: true
                spacing: LingmoUI.Units.smallSpacing
                Repeater {
                    model: control.message.attachments || []
                    delegate: Rectangle {
                        required property var modelData
                        width: Math.min(chip.implicitWidth + LingmoUI.Units.largeSpacing * 2, 260)
                        height: 28
                        radius: 14
                        color: LingmoUI.Theme.alternateBackgroundColor
                        Label {
                            id: chip
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, 260 - LingmoUI.Units.largeSpacing * 2)
                            text: modelData
                            color: LingmoUI.Theme.textColor
                            elide: Text.ElideMiddle
                            textFormat: Text.PlainText
                        }
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                text: qsTr("Os anexos não são abertos aqui por segurança. Use o site do seu provedor para baixá-los.")
                color: LingmoUI.Theme.disabledTextColor
                font.pointSize: LingmoUI.Theme.fontSize * 0.85
                wrapMode: Text.Wrap
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: LingmoUI.Theme.textColor
            opacity: 0.1
        }

        // ---------- Body
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ScrollView {
                anchors.fill: parent
                clip: true
                visible: control.loaded

                TextArea {
                    text: control.message.body || ""
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    color: LingmoUI.Theme.textColor
                    background: null
                    font.pointSize: LingmoUI.Theme.fontSize
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                visible: !control.loaded
                spacing: LingmoUI.Units.largeSpacing
                Spinner {
                    Layout.alignment: Qt.AlignHCenter
                    running: Mail.loadingMessage
                }
                Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: Mail.loadingMessage ? qsTr("Abrindo mensagem…") : qsTr("Não foi possível abrir a mensagem")
                    color: LingmoUI.Theme.disabledTextColor
                }
                ActionButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: !Mail.loadingMessage
                    text: qsTr("Tentar novamente")
                    onClicked: Mail.openMessage(Mail.currentMessageId)
                }
            }
        }
    }
}
