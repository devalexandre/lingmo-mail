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

// Left pane, in the style of Lingmo Settings' sidebar: E-mail (accounts and their
// folders, rules), then the other sections of the app
Item {
    id: control

    // "mail", "rules", "calendar", "tasks" or "contacts"
    property string page: "mail"
    signal pageRequested(string page)
    signal composeRequested()
    signal addAccountRequested()
    signal removeRequested(var account)

    implicitWidth: LingmoUI.Units.sideBarWidth

    readonly property var tileColors: [LingmoUI.Theme.blueColor, LingmoUI.Theme.purpleColor, LingmoUI.Theme.orangeColor,
                                       LingmoUI.Theme.greenColor, LingmoUI.Theme.pinkColor, LingmoUI.Theme.redColor]
    // Accounts whose folders are folded away (the open one is always shown)
    property var collapsed: ({})

    function initials(account) {
        const source = (account.name || account.email || "?").trim()
        return source.length > 0 ? source[0].toUpperCase() : "?"
    }

    function toggle(accountId, open) {
        const next = Object.assign({}, collapsed)
        // true = folded, false = unfolded
        next[accountId] = open ? next[accountId] !== true ? true : false
                               : next[accountId] === false ? true : false
        collapsed = next
    }

    Rectangle {
        anchors.fill: parent
        // Same tone as the Settings and Store sidebars
        color: LingmoUI.Theme.sideBarColor
        Behavior on color { ColorAnimation { duration: LingmoUI.Units.longDuration } }
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
            font.pointSize: LingmoUI.Units.fontTitle
            font.bold: true
        }

        LingmoUI.ActionButton {
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
            contentHeight: column.implicitHeight + LingmoUI.Units.largeSpacing
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            LingmoUI.WheelHandler { target: flick }

            ColumnLayout {
                id: column
                x: LingmoUI.Units.largeSpacing
                width: flick.width - LingmoUI.Units.largeSpacing * 2
                spacing: LingmoUI.Units.smallSpacing

                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.topMargin: LingmoUI.Units.largeSpacing
                    Layout.leftMargin: LingmoUI.Units.smallSpacing
                    text: qsTr("E-mail")
                    color: LingmoUI.Theme.secondaryTextColor
                }

                Repeater {
                    model: Mail.accounts

                    delegate: ColumnLayout {
                        id: accountBlock
                        required property var modelData
                        required property int index
                        readonly property bool isOpen: modelData.id === Mail.currentAccountId
                        readonly property var folders: Mail.folderCache[modelData.id] || []
                        // The open account shows its folders unless folded; the others only when unfolded
                        readonly property bool expanded: isOpen ? control.collapsed[modelData.id] !== true
                                                                : control.collapsed[modelData.id] === false
                        readonly property int inboxUnread: {
                            const inbox = folders.find(f => f.role === "inbox")
                            return inbox ? inbox.unread : -1
                        }

                        Layout.fillWidth: true
                        spacing: 2

                        LingmoUI.SideBarItem {
                            id: row
                            Layout.fillWidth: true
                            title: accountBlock.modelData.name || accountBlock.modelData.email
                            tileText: control.initials(accountBlock.modelData)
                            tileColor: control.tileColors[accountBlock.index % control.tileColors.length]
                            emphasized: accountBlock.isOpen
                            badge: !accountBlock.expanded && accountBlock.inboxUnread > 0 ? accountBlock.inboxUnread : ""
                            Accessible.name: accountBlock.modelData.email
                            onClicked: {
                                if (accountBlock.isOpen && control.page === "mail") {
                                    control.toggle(accountBlock.modelData.id, true)
                                    return
                                }
                                const next = Object.assign({}, control.collapsed)
                                next[accountBlock.modelData.id] = false
                                control.collapsed = next
                                Mail.openFolder(accountBlock.modelData.id, "INBOX")
                                control.pageRequested("mail")
                            }

                            ToolTip.visible: row.hovered && !!accountBlock.modelData.name
                            ToolTip.text: accountBlock.modelData.email
                            ToolTip.delay: 600

                            // Options button, shown on hover
                            LingmoUI.IconButton {
                                id: moreButton
                                size: 24
                                visible: row.hovered || hovered || accountMenu.visible
                                iconName: "view-more-symbolic"
                                tipText: qsTr("Opções da conta")
                                onClicked: accountMenu.popup(moreButton, 0, moreButton.height)

                                Menu {
                                    id: accountMenu
                                    MenuItem {
                                        text: accountBlock.expanded ? qsTr("Recolher pastas") : qsTr("Mostrar pastas")
                                        onTriggered: control.toggle(accountBlock.modelData.id, accountBlock.isOpen)
                                    }
                                    MenuItem {
                                        text: qsTr("Remover conta…")
                                        onTriggered: control.removeRequested(accountBlock.modelData)
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: accountBlock.expanded ? accountBlock.folders : []

                            delegate: LingmoUI.SideBarItem {
                                required property var modelData
                                Layout.fillWidth: true
                                indent: LingmoUI.Units.largeSpacing + Math.min(modelData.depth || 0, 4) * LingmoUI.Units.largeSpacing
                                title: Mail.folderTitle(modelData)
                                iconName: Mail.folderIcon(modelData.role || "")
                                // Unread mail in the inbox as a badge, other folders as a plain count
                                badge: modelData.role === "inbox" && modelData.unread > 0 ? modelData.unread : ""
                                trailing: modelData.role !== "inbox" && modelData.unread > 0 ? String(modelData.unread) : ""
                                isCurrent: control.page === "mail" && accountBlock.isOpen
                                           && modelData.path === Mail.currentFolder
                                Accessible.name: title
                                onClicked: {
                                    Mail.openFolder(accountBlock.modelData.id, modelData.path)
                                    control.pageRequested("mail")
                                }
                            }
                        }

                        // Folders not known yet: the inbox, until the first listing arrives
                        LingmoUI.SideBarItem {
                            Layout.fillWidth: true
                            visible: accountBlock.expanded && accountBlock.folders.length === 0 && accountBlock.isOpen
                            indent: LingmoUI.Units.largeSpacing
                            title: qsTr("Caixa de entrada")
                            iconName: "mail-folder-inbox"
                            isCurrent: control.page === "mail"
                            onClicked: control.pageRequested("mail")
                        }
                    }
                }

                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    Layout.leftMargin: LingmoUI.Units.smallSpacing
                    visible: Mail.accountsLoaded && Mail.accounts.length === 0
                    wrapMode: Text.Wrap
                    text: qsTr("Nenhuma conta ainda")
                    color: LingmoUI.Theme.secondaryTextColor
                }

                LingmoUI.SideBarItem {
                    Layout.fillWidth: true
                    visible: Mail.accounts.length > 0
                    title: qsTr("Regras")
                    tileText: "☰"
                    tileColor: LingmoUI.Theme.orangeColor
                    isCurrent: control.page === "rules"
                    onClicked: control.pageRequested("rules")
                }

            }
        }

        // Other sections: always in view, below the mail folders
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: LingmoUI.Units.largeSpacing
            Layout.rightMargin: LingmoUI.Units.largeSpacing
            implicitHeight: 1
            color: LingmoUI.Theme.dividerColor
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: LingmoUI.Units.largeSpacing
            Layout.rightMargin: LingmoUI.Units.largeSpacing
            Layout.topMargin: LingmoUI.Units.smallSpacing
            spacing: LingmoUI.Units.smallSpacing

            LingmoUI.SideBarItem {
                Layout.fillWidth: true
                title: qsTr("Calendário")
                tileText: "▦"
                tileColor: LingmoUI.Theme.redColor
                isCurrent: control.page === "calendar"
                onClicked: control.pageRequested("calendar")
            }
            LingmoUI.SideBarItem {
                Layout.fillWidth: true
                title: qsTr("Tarefas")
                tileText: "✓"
                tileColor: LingmoUI.Theme.greenColor
                isCurrent: control.page === "tasks"
                onClicked: control.pageRequested("tasks")
            }
            LingmoUI.SideBarItem {
                Layout.fillWidth: true
                title: qsTr("Contatos")
                tileText: "@"
                tileColor: LingmoUI.Theme.purpleColor
                isCurrent: control.page === "contacts"
                onClicked: control.pageRequested("contacts")
            }
        }

        LingmoUI.ActionButton {
            Layout.fillWidth: true
            Layout.leftMargin: LingmoUI.Units.largeSpacing
            Layout.rightMargin: LingmoUI.Units.largeSpacing
            Layout.topMargin: LingmoUI.Units.smallSpacing * 1.5
            Layout.bottomMargin: LingmoUI.Units.largeSpacing
            text: qsTr("Adicionar conta")
            onClicked: control.addAccountRequested()
        }
    }
}
