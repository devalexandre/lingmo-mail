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
