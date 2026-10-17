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

LingmoUI.Window {
    id: rootWindow

    width: 1180
    height: 740
    minimumWidth: 940
    minimumHeight: 560
    visible: true
    title: qsTr("E-mail")

    // As in Settings: nearly opaque, title strip shared with the sidebar
    background.opacity: LingmoUI.Theme.darkMode ? 0.88 : 0.97
    header.height: LingmoUI.Units.windowHeaderHeight
    contentTopMargin: 0

    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    property bool offeredSetup: false
    // "mail", "rules", "calendar", "tasks" or "contacts"
    property string page: "mail"
    readonly property bool dialogOpen: composer.visible || accountDialog.visible || removeConfirm.visible
                                       || deleteConfirm.visible || moveDialog.visible || ruleEditor.visible
                                       || contactEditor.visible
    readonly property bool mailKeys: page === "mail" && !dialogOpen && Mail.currentIsImap

    LingmoUI.WindowBlur {
        view: rootWindow
        geometry: Qt.rect(rootWindow.x, rootWindow.y, rootWindow.width, rootWindow.height)
        windowRadius: rootWindow.windowRadius
        enabled: true
    }

    function compose(draft) {
        page = "mail"
        composer.compose(draft || {})
    }

    Shortcut { sequence: "Ctrl+N"; enabled: Mail.currentAccountId !== "" && !rootWindow.dialogOpen; onActivated: rootWindow.compose({}) }
    Shortcut { sequence: "F5"; onActivated: Mail.refresh() }
    Shortcut { sequence: "Ctrl+R"; enabled: !!Mail.message.loaded && !rootWindow.dialogOpen; onActivated: rootWindow.compose(Mail.replyDraft()) }
    Shortcut { sequence: "Ctrl+Shift+F"; enabled: !!Mail.message.loaded && !rootWindow.dialogOpen; onActivated: rootWindow.compose(Mail.forwardDraft()) }
    // Message keys; text fields keep their own keys (they take the shortcut override)
    Shortcut { sequences: [StandardKey.Delete]; enabled: rootWindow.mailKeys; onActivated: messageList.deleteSelected() }
    Shortcut { sequence: "Ctrl+U"; enabled: rootWindow.mailKeys; onActivated: messageList.toggleRead() }
    Shortcut { sequence: "S"; enabled: rootWindow.mailKeys; onActivated: messageList.toggleStar() }
    Shortcut { sequence: "E"; enabled: rootWindow.mailKeys; onActivated: messageList.archiveSelected() }
    Shortcut { sequence: "Ctrl+A"; enabled: rootWindow.mailKeys; onActivated: messageList.selectAll() }
    Shortcut { sequence: "J"; enabled: rootWindow.page === "mail" && !rootWindow.dialogOpen; onActivated: messageList.step(1) }
    Shortcut { sequence: "K"; enabled: rootWindow.page === "mail" && !rootWindow.dialogOpen; onActivated: messageList.step(-1) }
    Shortcut { sequence: "Escape"; enabled: rootWindow.page === "mail" && !rootWindow.dialogOpen && messageList.selectedIds.length > 1; onActivated: messageList.clearSelection() }

    Connections {
        target: Mail
        // First run: go straight to adding an account
        function onAccountsChanged() {
            if (Mail.accountsLoaded && Mail.accounts.length === 0 && !rootWindow.offeredSetup) {
                rootWindow.offeredSetup = true
                accountDialog.reset()
                accountDialog.open()
            }
        }
        function onStatusChanged() {
            if (Mail.status.length > 0)
                statusTimer.restart()
        }
        function onDeleteNeedsConfirm(ids) {
            deleteConfirm.ids = ids
            deleteConfirm.text = ids.length === 1
                ? qsTr("A mensagem será apagada do servidor para sempre. Isso não pode ser desfeito.")
                : qsTr("%1 mensagens serão apagadas do servidor para sempre. Isso não pode ser desfeito.").arg(ids.length)
            deleteConfirm.open()
        }
    }

    Timer {
        id: statusTimer
        interval: 5000
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        AccountsPane {
            id: sideBar
            Layout.fillHeight: true
            page: rootWindow.page
            onPageRequested: (name) => rootWindow.page = name
            onComposeRequested: rootWindow.compose({})
            onAddAccountRequested: {
                accountDialog.reset()
                accountDialog.open()
            }
            onRemoveRequested: (account) => {
                removeConfirm.accountId = account.id
                removeConfirm.text = qsTr("A conta %1 e a senha salva serão removidas deste computador. As mensagens continuam no servidor.").arg(account.email)
                removeConfirm.open()
            }
        }

        // ---------- Content
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: LingmoUI.Units.largeSpacing

            // Title strip: shares the header with the window buttons
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: rootWindow.header.height
                Layout.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                Layout.rightMargin: LingmoUI.Units.largeSpacing * 1.5
                spacing: LingmoUI.Units.smallSpacing

                Item { Layout.fillWidth: true }
                LingmoUI.Spinner {
                    size: 16
                    running: Mail.busy && !Mail.setupBusy
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.maximumWidth: 420
                    elide: Text.ElideRight
                    color: LingmoUI.Theme.secondaryTextColor
                    opacity: statusTimer.running || Mail.setupBusy ? 1 : 0
                    text: Mail.status
                    Behavior on opacity { NumberAnimation { duration: LingmoUI.Units.shortDuration } }
                }
            }

            LingmoUI.Banner {
                type: LingmoUI.Banner.Error
                Layout.fillWidth: true
                Layout.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                Layout.rightMargin: LingmoUI.Units.largeSpacing * 1.5
                visible: text.length > 0 && rootWindow.page !== "calendar" && rootWindow.page !== "tasks"
                text: Mail.error
                onClosed: Mail.clearError()
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: ["mail", "rules", "calendar", "tasks", "contacts"].indexOf(rootWindow.page)

                // ---------- E-mail
                Item {
                    // Loading / first-run state
                    Item {
                        anchors.fill: parent
                        visible: Mail.accounts.length === 0

                        ColumnLayout {
                            anchors.centerIn: parent
                            width: Math.min(parent.width - 80, 420)
                            spacing: LingmoUI.Units.largeSpacing * 1.5

                            LingmoUI.EmptyState {
                                Layout.fillWidth: true
                                iconName: "qrc:/lingmo-mail.svg"
                                iconSize: LingmoUI.Units.iconSizes.huge * 1.5
                                busy: !Mail.accountsLoaded
                                title: Mail.accountsLoaded ? qsTr("Bem-vindo ao E-mail") : ""
                                text: Mail.accountsLoaded ? qsTr("Adicione sua conta do Gmail, Yahoo, iCloud ou de qualquer provedor com IMAP ou POP3. Mensagens são mostradas só como texto, sem conteúdo remoto.") : ""
                            }
                            SetupGuide {
                                Layout.fillWidth: true
                                visible: Mail.accountsLoaded
                            }
                            LingmoUI.ActionButton {
                                Layout.alignment: Qt.AlignHCenter
                                visible: Mail.accountsLoaded
                                primary: true
                                text: qsTr("Adicionar conta")
                                onClicked: {
                                    accountDialog.reset()
                                    accountDialog.open()
                                }
                            }
                        }
                    }

                    // Message list and reader, as cards
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                        anchors.rightMargin: LingmoUI.Units.largeSpacing * 1.5
                        anchors.bottomMargin: LingmoUI.Units.largeSpacing * 1.5
                        spacing: LingmoUI.Units.largeSpacing
                        visible: Mail.accounts.length > 0

                        LingmoUI.Card {
                            Layout.preferredWidth: Math.max(320, Math.min(400, rootWindow.width * 0.32))
                            Layout.fillHeight: true

                            MessageList {
                                id: messageList
                                anchors.fill: parent
                                onMoveRequested: (ids, anchor) => moveDialog.choose(ids)
                                onRulesRequested: rootWindow.page = "rules"
                            }
                        }

                        LingmoUI.Card {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            MessageReader {
                                anchors.fill: parent
                                onReplyRequested: rootWindow.compose(Mail.replyDraft())
                                onForwardRequested: rootWindow.compose(Mail.forwardDraft())
                                onRuleRequested: (message) => ruleEditor.fromMessage(message)
                                onMoveRequested: (ids, anchor) => moveDialog.choose(ids)
                            }
                        }
                    }
                }

                // ---------- Regras
                RulesPage {
                    onEditRequested: (rule) => ruleEditor.edit(rule)
                }

                // ---------- Calendário and Tarefas: the calendar side's pages, when installed
                SectionLoader {
                    source: "qrc:/qml/CalendarPage.qml"
                    title: qsTr("Calendário")
                    wanted: rootWindow.page === "calendar"
                }
                SectionLoader {
                    source: "qrc:/qml/TasksPage.qml"
                    title: qsTr("Tarefas")
                    wanted: rootWindow.page === "tasks"
                }

                // ---------- Contatos
                ContactsPage {
                    onWriteRequested: (recipient) => rootWindow.compose({ to: recipient })
                    onEditRequested: (contact) => contactEditor.edit(contact)
                }
            }
        }
    }

    AccountDialog {
        id: accountDialog
    }

    ComposerDialog {
        id: composer
    }

    RuleEditor {
        id: ruleEditor
    }

    ContactEditor {
        id: contactEditor
    }

    ConfirmDialog {
        id: removeConfirm
        property string accountId: ""
        title: qsTr("Remover conta?")
        acceptText: qsTr("Remover")
        destructive: true
        onAccepted: Mail.removeAccount(accountId)
    }

    ConfirmDialog {
        id: deleteConfirm
        property var ids: []
        title: qsTr("Apagar definitivamente?")
        acceptText: qsTr("Apagar")
        destructive: true
        onAccepted: {
            Mail.deleteMessages(ids, true)
            messageList.clearSelection()
        }
    }

    // "Mover para…": the folders of the open account
    MailPopup {
        id: moveDialog
        property var ids: []
        title: ids.length > 1 ? qsTr("Mover %1 mensagens para").arg(ids.length) : qsTr("Mover para")
        width: Math.min(420, parent ? parent.width - 80 : 420)
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        function choose(list) {
            ids = list
            targets.model = Mail.moveTargets()
            open()
        }

        ListView {
            id: targets
            width: parent.width
            implicitHeight: Math.min(contentHeight, 360)
            height: implicitHeight
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            delegate: LingmoUI.SideBarItem {
                required property var modelData
                width: ListView.view.width
                indent: Math.min(modelData.depth || 0, 4) * LingmoUI.Units.largeSpacing
                title: modelData.title
                iconName: Mail.folderIcon(modelData.role || "")
                onClicked: {
                    moveDialog.close()
                    Mail.moveMessages(moveDialog.ids, modelData.path)
                    messageList.clearSelection()
                }
            }
        }

        buttons: [
            Item { Layout.fillWidth: true },
            LingmoUI.ActionButton {
                text: qsTr("Cancelar")
                onClicked: moveDialog.close()
            }
        ]
    }
}
