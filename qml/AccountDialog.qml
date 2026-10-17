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

// Add an account: e-mail -> discovered servers -> password -> connection test
MailPopup {
    id: dialog

    property int step: 0             // 0: address, 1: review + password
    property string errorText: ""
    property string infoText: ""
    property bool showAdvanced: false
    property bool waitingGoogle: false

    height: Math.min(implicitHeight, parent ? parent.height - 48 : implicitHeight)
    title: step === 0 ? qsTr("Adicionar conta de e-mail") : qsTr("Confira os dados da conta")

    readonly property string domain: {
        const at = emailField.text.lastIndexOf("@")
        return at >= 0 ? emailField.text.slice(at + 1).trim().toLowerCase() : ""
    }

    function reset() {
        step = 0
        errorText = ""
        infoText = ""
        showAdvanced = false
        waitingGoogle = false
        emailField.text = ""
        nameField.text = ""
        passwordField.text = ""
    }

    function fill(account) {
        if (account.email) emailField.text = account.email
        protocolBox.currentIndex = account.protocol === "pop3" ? 1 : 0
        incomingHost.text = account.incomingHost || ""
        incomingPort.text = String(account.incomingPort || "")
        incomingSecurity.currentIndex = account.incomingSecurity === "starttls" ? 1 : 0
        username.text = account.username || emailField.text.trim()
        smtpHost.text = account.smtpHost || ""
        smtpPort.text = String(account.smtpPort || "")
        smtpSecurity.currentIndex = account.smtpSecurity === "tls" ? 0 : 1
        smtpUsername.text = account.smtpUsername || username.text
    }

    function account() {
        return {
            email: emailField.text.trim(),
            name: nameField.text.trim(),
            protocol: protocolBox.currentIndex === 1 ? "pop3" : "imap",
            username: username.text.trim(),
            smtpUsername: smtpUsername.text.trim(),
            incomingHost: incomingHost.text.trim(),
            incomingPort: parseInt(incomingPort.text, 10) || 0,
            incomingSecurity: incomingSecurity.currentIndex === 1 ? "starttls" : "tls",
            smtpHost: smtpHost.text.trim(),
            smtpPort: parseInt(smtpPort.text, 10) || 0,
            smtpSecurity: smtpSecurity.currentIndex === 0 ? "tls" : "starttls",
            auth: "password"
        }
    }

    function next() {
        errorText = ""
        if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(emailField.text.trim())) {
            errorText = qsTr("Informe um endereço de e-mail válido.")
            return
        }
        Mail.discover(emailField.text.trim())
    }


    onOpened: emailField.forceActiveFocus()
    onClosed: {
        Mail.cancelSetup()
        passwordField.text = ""
    }

    Connections {
        target: Mail
        enabled: dialog.visible
        function onDiscovered(account) {
            dialog.fill(account)
            dialog.infoText = ""
            dialog.step = 1
            passwordField.forceActiveFocus()
        }
        function onDiscoverFailed(error) {
            // Let the user fill the servers by hand, starting from common names
            const d = dialog.domain
            dialog.fill({ protocol: "imap", incomingHost: d ? "imap." + d : "", incomingPort: 993,
                          incomingSecurity: "tls", smtpHost: d ? "smtp." + d : "", smtpPort: 587,
                          smtpSecurity: "starttls" })
            dialog.infoText = error
            dialog.showAdvanced = true
            dialog.step = 1
        }
        function onAccountSaved(account) {
            passwordField.text = ""
            dialog.waitingGoogle = false
            dialog.close()
        }
        function onSetupFailed(error) {
            dialog.waitingGoogle = false
            dialog.errorText = error
        }
    }

    ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        implicitHeight: Math.min(steps.implicitHeight, 520)

        ColumnLayout {
            id: steps
            width: scroll.availableWidth
            spacing: LingmoUI.Units.largeSpacing

            LingmoUI.Banner {
                type: LingmoUI.Banner.Error
                Layout.fillWidth: true
                text: dialog.errorText
                onClosed: dialog.errorText = ""
            }
            LingmoUI.Banner {
                Layout.fillWidth: true
                type: LingmoUI.Banner.Info
                text: dialog.infoText
                onClosed: dialog.infoText = ""
            }

            // ---------- Step 0: address
            ColumnLayout {
                Layout.fillWidth: true
                visible: dialog.step === 0
                spacing: LingmoUI.Units.largeSpacing

                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: LingmoUI.Theme.secondaryTextColor
                    text: qsTr("Digite seu e-mail: os servidores são encontrados automaticamente para os provedores mais comuns.")
                }
                Label { text: qsTr("Seu nome (opcional)"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    placeholderText: qsTr("Como os destinatários verão você")
                    enabled: !Mail.setupBusy
                }
                Label { text: qsTr("E-mail"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                TextField {
                    id: emailField
                    Layout.fillWidth: true
                    placeholderText: qsTr("voce@exemplo.com")
                    inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                    enabled: !Mail.setupBusy
                    onAccepted: dialog.next()
                }

                SetupGuide {
                    Layout.fillWidth: true
                    Layout.topMargin: LingmoUI.Units.smallSpacing
                    domain: dialog.domain
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: Mail.googleAvailable
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: LingmoUI.Theme.dividerColor }
                    Label { text: qsTr("ou"); color: LingmoUI.Theme.secondaryTextColor; font.pointSize: LingmoUI.Units.fontCaption }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: LingmoUI.Theme.dividerColor }
                }

                LingmoUI.ActionButton {
                    Layout.fillWidth: true
                    visible: Mail.googleAvailable
                    text: dialog.waitingGoogle ? qsTr("Aguardando o navegador…") : qsTr("Entrar com Google")
                    enabled: !Mail.setupBusy
                    onClicked: {
                        dialog.errorText = ""
                        dialog.waitingGoogle = true
                        Mail.signInWithGoogle()
                    }
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    visible: dialog.waitingGoogle
                    wrapMode: Text.Wrap
                    color: LingmoUI.Theme.secondaryTextColor
                    text: qsTr("Autorize o acesso na página do Google que abriu no navegador. Esta janela continua sozinha.")
                }
            }

            // ---------- Step 1: review and password
            ColumnLayout {
                Layout.fillWidth: true
                visible: dialog.step === 1
                spacing: LingmoUI.Units.largeSpacing

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: summary.implicitHeight + LingmoUI.Units.largeSpacing * 2
                    radius: LingmoUI.Theme.mediumRadius
                    color: LingmoUI.Theme.alternateBackgroundColor

                    ColumnLayout {
                        id: summary
                        anchors.fill: parent
                        anchors.margins: LingmoUI.Units.largeSpacing
                        spacing: 2
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.fillWidth: true
                            text: emailField.text.trim()
                            font.bold: true
                            color: LingmoUI.Theme.textColor
                            elide: Text.ElideRight
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontCaption
                            Layout.fillWidth: true
                            text: qsTr("Recebimento: %1 (%2, %3)").arg(incomingHost.text || "—")
                                  .arg(protocolBox.currentText).arg(incomingSecurity.currentText)
                            color: LingmoUI.Theme.secondaryTextColor
                            elide: Text.ElideRight
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontCaption
                            Layout.fillWidth: true
                            text: qsTr("Envio: %1 (SMTP, %2)").arg(smtpHost.text || "—").arg(smtpSecurity.currentText)
                            color: LingmoUI.Theme.secondaryTextColor
                            elide: Text.ElideRight
                        }
                    }
                }

                // Collapsible section header
                RowLayout {
                    spacing: LingmoUI.Units.smallSpacing
                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        text: "\u25B8"
                        color: LingmoUI.Theme.highlightColor
                        rotation: dialog.showAdvanced ? 90 : 0
                        Behavior on rotation { NumberAnimation { duration: LingmoUI.Units.shortDuration; easing.type: LingmoUI.Units.easing } }
                    }
                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        text: qsTr("Configurações avançadas")
                        color: LingmoUI.Theme.highlightColor
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -LingmoUI.Units.smallSpacing
                            cursorShape: Qt.PointingHandCursor
                            onClicked: dialog.showAdvanced = !dialog.showAdvanced
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    visible: dialog.showAdvanced
                    columns: 2
                    columnSpacing: LingmoUI.Units.largeSpacing
                    rowSpacing: LingmoUI.Units.smallSpacing
                    enabled: !Mail.setupBusy

                    Label { text: qsTr("Protocolo"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    ComboBox {
                        id: protocolBox
                        Layout.fillWidth: true
                        model: ["IMAP", "POP3"]
                        onActivated: {
                            // Follow the protocol's usual port unless it was customized
                            const tls = incomingSecurity.currentIndex === 0
                            if (["993", "143", "995", "110", ""].indexOf(incomingPort.text) >= 0)
                                incomingPort.text = currentIndex === 1 ? (tls ? "995" : "110") : (tls ? "993" : "143")
                        }
                    }

                    Label { text: qsTr("Servidor de entrada"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    TextField { id: incomingHost; Layout.fillWidth: true; placeholderText: "imap.exemplo.com" }

                    Label { text: qsTr("Porta"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField {
                            id: incomingPort
                            Layout.preferredWidth: 90
                            validator: IntValidator { bottom: 1; top: 65535 }
                            inputMethodHints: Qt.ImhDigitsOnly
                        }
                        ComboBox {
                            id: incomingSecurity
                            Layout.fillWidth: true
                            model: ["TLS", "STARTTLS"]
                            onActivated: {
                                const pop = protocolBox.currentIndex === 1
                                if (["993", "143", "995", "110", ""].indexOf(incomingPort.text) >= 0)
                                    incomingPort.text = pop ? (currentIndex === 0 ? "995" : "110") : (currentIndex === 0 ? "993" : "143")
                            }
                        }
                    }

                    Label { text: qsTr("Usuário"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    TextField { id: username; Layout.fillWidth: true; placeholderText: emailField.text.trim() }

                    Label { text: qsTr("Servidor de saída (SMTP)"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    TextField { id: smtpHost; Layout.fillWidth: true; placeholderText: "smtp.exemplo.com" }

                    Label { text: qsTr("Porta"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField {
                            id: smtpPort
                            Layout.preferredWidth: 90
                            validator: IntValidator { bottom: 1; top: 65535 }
                            inputMethodHints: Qt.ImhDigitsOnly
                        }
                        ComboBox {
                            id: smtpSecurity
                            Layout.fillWidth: true
                            model: ["TLS", "STARTTLS"]
                            currentIndex: 1
                            onActivated: {
                                if (["465", "587", ""].indexOf(smtpPort.text) >= 0)
                                    smtpPort.text = currentIndex === 0 ? "465" : "587"
                            }
                        }
                    }

                    Label { text: qsTr("Usuário SMTP"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    TextField { id: smtpUsername; Layout.fillWidth: true; placeholderText: username.text || emailField.text.trim() }
                }

                Label { text: qsTr("Senha"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                TextField {
                    id: passwordField
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    placeholderText: qsTr("Senha ou senha de app")
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhHiddenText
                    enabled: !Mail.setupBusy
                    onAccepted: if (connectButton.enabled) connectButton.clicked()
                }
                SetupGuide {
                    Layout.fillWidth: true
                    domain: dialog.domain
                    onlyMatching: true
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: LingmoUI.Theme.secondaryTextColor
                    font.pointSize: LingmoUI.Units.fontCaption
                    text: qsTr("A senha fica guardada no chaveiro da sessão, não em arquivos.")
                        + (dialog.domain === "gmail.com" && Mail.googleAvailable ? " " + qsTr("Ou use “Entrar com Google”.") : "")
                }
            }
        }
    }

    buttons: [
        LingmoUI.Spinner {
                        running: Mail.setupBusy
        },
        Label {
            font.pointSize: LingmoUI.Units.fontCaption
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: LingmoUI.Theme.secondaryTextColor
            text: !Mail.setupBusy ? ""
                  : dialog.waitingGoogle ? qsTr("Aguardando autorização…")
                  : dialog.step === 0 ? qsTr("Procurando servidores…")
                  : qsTr("Testando a conexão…")
        },
        LingmoUI.ActionButton {
            text: dialog.step === 1 && !Mail.setupBusy ? qsTr("Voltar") : qsTr("Cancelar")
            onClicked: {
                if (Mail.setupBusy) {
                    Mail.cancelSetup()
                    dialog.waitingGoogle = false
                } else if (dialog.step === 1) {
                    dialog.step = 0
                    dialog.errorText = ""
                    dialog.infoText = ""
                    passwordField.text = ""
                } else {
                    dialog.close()
                }
            }
        },
        LingmoUI.ActionButton {
            id: connectButton
            primary: true
            text: dialog.step === 0 ? qsTr("Continuar") : qsTr("Conectar")
            enabled: !Mail.setupBusy && (dialog.step === 0 ? emailField.text.trim().length > 0
                                                           : passwordField.text.length > 0)
            onClicked: {
                if (dialog.step === 0) {
                    dialog.next()
                } else {
                    dialog.errorText = ""
                    Mail.saveAccount(dialog.account(), passwordField.text)
                }
            }
        }
    ]
}
