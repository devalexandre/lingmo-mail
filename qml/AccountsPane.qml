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

// Left pane, in the style of Lingmo Settings' sidebar: compose, folders and accounts
Item {
    id: control

    signal composeRequested()
    signal addAccountRequested()
    signal removeRequested(var account)

    implicitWidth: 230

    readonly property var tileColors: [LingmoUI.Theme.blueColor, LingmoUI.Theme.purpleColor, LingmoUI.Theme.orangeColor,
                                       LingmoUI.Theme.greenColor, LingmoUI.Theme.pinkColor, LingmoUI.Theme.redColor]

    function initials(account) {
        const source = (account.name || account.email || "?").trim()
        return source.length > 0 ? source[0].toUpperCase() : "?"
    }

    Rectangle {
        anchors.fill: parent
        // Same tone as the Settings and Store sidebars
        color: LingmoUI.Theme.darkMode ? Qt.rgba(0.11, 0.11, 0.15, 0.55) : "#EDEEF2"
        Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.Linear } }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // The window's buttons sit in this strip
        Item { Layout.preferredHeight: rootWindow.header.height }

        Label {
            text: rootWindow.title
            color: rootWindow.active ? LingmoUI.Theme.textColor : LingmoUI.Theme.disabledTextColor
            leftPadding: LingmoUI.Units.largeSpacing + LingmoUI.Units.smallSpacing
            rightPadding: LingmoUI.Units.largeSpacing + LingmoUI.Units.smallSpacing
            topPadding: 2
            bottomPadding: LingmoUI.Units.smallSpacing * 1.5
            font.pointSize: LingmoUI.Theme.fontSize * 1.6
            font.bold: true
        }

        ActionButton {
            Layout.fillWidth: true
            Layout.leftMargin: LingmoUI.Units.largeSpacing
            Layout.rightMargin: LingmoUI.Units.largeSpacing
            Layout.bottomMargin: LingmoUI.Units.smallSpacing
            primary: true
            text: qsTr("Escrever")
            enabled: Mail.currentAccountId !== ""
            onClicked: control.composeRequested()
        }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: column.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            LingmoUI.WheelHandler { target: flick }

            ColumnLayout {
                id: column
                x: LingmoUI.Units.largeSpacing
                width: flick.width - LingmoUI.Units.largeSpacing * 2
                spacing: LingmoUI.Units.smallSpacing

                Label {
                    Layout.topMargin: LingmoUI.Units.largeSpacing
                    Layout.leftMargin: LingmoUI.Units.smallSpacing
                    visible: Mail.currentAccountId !== ""
                    text: qsTr("Pastas")
                    color: LingmoUI.Theme.disabledTextColor
                }

                // Only the inbox for now: the worker reads INBOX
                SideBarItem {
                    Layout.fillWidth: true
                    visible: Mail.currentAccountId !== ""
                    title: qsTr("Caixa de entrada")
                    tileText: "✉"
                    tileColor: LingmoUI.Theme.blueColor
                    trailing: Mail.inboxLoaded && Mail.messages.length > 0 ? String(Mail.messages.length) : ""
                    isCurrent: true
                    onClicked: Mail.closeMessage()
                }

                Label {
                    Layout.topMargin: LingmoUI.Units.largeSpacing
                    Layout.leftMargin: LingmoUI.Units.smallSpacing
                    text: qsTr("Contas")
                    color: LingmoUI.Theme.disabledTextColor
                }

                Repeater {
                    model: Mail.accounts

                    delegate: SideBarItem {
                        id: row
                        required property var modelData
                        required property int index

                        Layout.fillWidth: true
                        title: modelData.name || modelData.email
                        tileText: control.initials(modelData)
                        tileColor: control.tileColors[index % control.tileColors.length]
                        // The open folder is highlighted; the current account is marked by its weight
                        isCurrent: false
                        emphasized: modelData.id === Mail.currentAccountId
                        Accessible.name: modelData.email
                        onClicked: Mail.currentAccountId = modelData.id

                        ToolTip.visible: row.hovered && !!modelData.name
                        ToolTip.text: modelData.email
                        ToolTip.delay: 600

                        // Options button, shown on hover
                        Rectangle {
                            id: moreButton
                            Layout.preferredWidth: 24
                            Layout.preferredHeight: 24
                            radius: width / 2
                            visible: row.hovered || moreArea.containsMouse || accountMenu.visible
                            color: moreArea.containsMouse ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                                    LingmoUI.Theme.textColor.b, 0.12)
                                                          : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Accessible.role: Accessible.Button
                            Accessible.name: qsTr("Opções da conta")

                            Label {
                                anchors.centerIn: parent
                                text: "\u22EF"
                                color: LingmoUI.Theme.textColor
                            }
                            MouseArea {
                                id: moreArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: accountMenu.popup(moreButton, 0, moreButton.height)
                            }

                            Menu {
                                id: accountMenu
                                MenuItem {
                                    text: qsTr("Usar esta conta")
                                    enabled: row.modelData.id !== Mail.currentAccountId
                                    onTriggered: Mail.currentAccountId = row.modelData.id
                                }
                                MenuItem {
                                    text: qsTr("Remover conta…")
                                    onTriggered: control.removeRequested(row.modelData)
                                }
                            }
                        }
                    }
                }

                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: LingmoUI.Units.smallSpacing
                    visible: Mail.accountsLoaded && Mail.accounts.length === 0
                    wrapMode: Text.Wrap
                    text: qsTr("Nenhuma conta ainda")
                    color: LingmoUI.Theme.disabledTextColor
                }
            }
        }

        ActionButton {
            Layout.fillWidth: true
            Layout.margins: LingmoUI.Units.largeSpacing
            text: qsTr("Adicionar conta")
            onClicked: control.addAccountRequested()
        }
    }
}
