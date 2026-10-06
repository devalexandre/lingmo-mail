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
    minimumWidth: 900
    minimumHeight: 560
    visible: true
    title: qsTr("E-mail")

    // As in Settings: nearly opaque, title strip shared with the sidebar
    background.opacity: LingmoUI.Theme.darkMode ? 0.88 : 0.97
    header.height: 40
    contentTopMargin: 0

    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    property bool offeredSetup: false

    LingmoUI.WindowBlur {
        view: rootWindow
        geometry: Qt.rect(rootWindow.x, rootWindow.y, rootWindow.width, rootWindow.height)
        windowRadius: rootWindow.windowRadius
        enabled: true
    }

    Shortcut { sequence: "Ctrl+N"; enabled: Mail.currentAccountId !== ""; onActivated: composer.compose({}) }
    Shortcut { sequence: "F5"; onActivated: Mail.refresh() }
    Shortcut { sequence: "Ctrl+R"; enabled: !!Mail.message.loaded; onActivated: composer.compose(Mail.replyDraft()) }
    Shortcut { sequence: "Ctrl+Shift+F"; enabled: !!Mail.message.loaded; onActivated: composer.compose(Mail.forwardDraft()) }

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
    }

    Timer {
        id: statusTimer
        interval: 5000
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        AccountsPane {
            Layout.fillHeight: true
            onComposeRequested: composer.compose({})
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
                Spinner {
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    running: Mail.busy && !Mail.setupBusy
                }
                Label {
                    Layout.maximumWidth: 420
                    elide: Text.ElideRight
                    color: LingmoUI.Theme.disabledTextColor
                    opacity: statusTimer.running || Mail.setupBusy ? 1 : 0
                    text: Mail.status
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
            }

            Banner {
                Layout.fillWidth: true
                Layout.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                Layout.rightMargin: LingmoUI.Units.largeSpacing * 1.5
                text: Mail.error
                onClosed: Mail.clearError()
            }

            // ---------- Loading / first-run state
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: Mail.accounts.length === 0

                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 80, 420)
                    spacing: LingmoUI.Units.largeSpacing * 1.5

                    Image {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: LingmoUI.Units.iconSizes.huge * 1.5
                        Layout.preferredHeight: LingmoUI.Units.iconSizes.huge * 1.5
                        source: "qrc:/lingmo-mail.svg"
                        sourceSize: Qt.size(192, 192)
                    }
                    Spinner {
                        Layout.alignment: Qt.AlignHCenter
                        running: !Mail.accountsLoaded
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: Mail.accountsLoaded
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        text: qsTr("Bem-vindo ao E-mail")
                        font.pointSize: LingmoUI.Theme.fontSize * 1.5
                        font.bold: true
                        color: LingmoUI.Theme.textColor
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: Mail.accountsLoaded
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        text: qsTr("Adicione sua conta do Gmail, Outlook, Yahoo, iCloud ou de qualquer provedor com IMAP ou POP3. Mensagens são mostradas só como texto, sem conteúdo remoto.")
                        color: LingmoUI.Theme.disabledTextColor
                    }
                    ActionButton {
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

            // ---------- Message list and reader, as cards
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                Layout.rightMargin: LingmoUI.Units.largeSpacing * 1.5
                Layout.bottomMargin: LingmoUI.Units.largeSpacing * 1.5
                spacing: LingmoUI.Units.largeSpacing
                visible: Mail.accounts.length > 0

                LingmoUI.RoundedRect {
                    Layout.preferredWidth: Math.max(300, Math.min(380, rootWindow.width * 0.3))
                    Layout.fillHeight: true
                    radius: LingmoUI.Theme.mediumRadius
                    color: LingmoUI.Theme.secondBackgroundColor

                    MessageList {
                        anchors.fill: parent
                    }
                }

                LingmoUI.RoundedRect {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: LingmoUI.Theme.mediumRadius
                    color: LingmoUI.Theme.secondBackgroundColor

                    MessageReader {
                        anchors.fill: parent
                        onReplyRequested: composer.compose(Mail.replyDraft())
                        onForwardRequested: composer.compose(Mail.forwardDraft())
                    }
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

    ConfirmDialog {
        id: removeConfirm
        property string accountId: ""
        title: qsTr("Remover conta?")
        acceptText: qsTr("Remover")
        destructive: true
        onAccepted: Mail.removeAccount(accountId)
    }
}
