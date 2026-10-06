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

// Connect a CalDAV account (iCloud, Yahoo, Fastmail, Nextcloud...) with an app password
MailPopup {
    id: dialog

    property string provider: "icloud"
    property string errorText: ""

    width: Math.min(580, parent ? parent.width - 80 : 580)
    height: Math.min(implicitHeight, parent ? parent.height - 48 : implicitHeight)
    title: qsTr("Adicionar conta de calendário")
    closePolicy: Popup.CloseOnEscape

    readonly property var providers: [
        {
            key: "icloud", title: qsTr("iCloud"),
            steps: [
                qsTr("Entre na sua Conta Apple (a verificação em duas etapas precisa estar ativa)."),
                qsTr("Em Login e segurança, abra “Senhas específicas de app” e crie uma."),
                qsTr("Use o e-mail da Conta Apple e essa senha aqui.")
            ],
            url: "https://account.apple.com/account/manage", link: qsTr("Abrir Conta Apple")
        },
        {
            key: "yahoo", title: qsTr("Yahoo"),
            steps: [
                qsTr("Abra a Segurança da conta Yahoo."),
                qsTr("Clique em “Gerar senha de app”, dê um nome (por exemplo, Lingmo) e gere."),
                qsTr("Use seu e-mail Yahoo e a senha gerada aqui.")
            ],
            url: "https://login.yahoo.com/account/security", link: qsTr("Abrir Segurança do Yahoo")
        },
        {
            key: "fastmail", title: qsTr("Fastmail"),
            steps: [
                qsTr("No Fastmail, abra Configurações › Privacidade e segurança › Senhas de app."),
                qsTr("Crie uma senha com acesso a “Calendários (CalDAV)”."),
                qsTr("Use seu e-mail Fastmail e essa senha aqui.")
            ],
            url: "", link: ""
        },
        {
            key: "other", title: qsTr("Nextcloud e outros"),
            steps: [
                qsTr("Informe o endereço do servidor, por exemplo https://nuvem.exemplo.com (o endereço CalDAV é encontrado sozinho quando o servidor publica /.well-known/caldav)."),
                qsTr("No Nextcloud com verificação em duas etapas, crie uma senha de app em Configurações › Segurança."),
                qsTr("Só servidores com HTTPS são aceitos.")
            ],
            url: "", link: ""
        }
    ]
    readonly property var current: providers.find(p => p.key === provider) || providers[0]
    readonly property var mailChoices: Calendar.mailAccounts.filter(a => provider === "other" ? true : a.provider === provider)

    function reset() {
        errorText = ""
        provider = "icloud"
        emailField.text = ""
        urlField.text = ""
        passwordField.text = ""
        Calendar.loadMailAccounts()
    }

    function connectAccount() {
        errorText = ""
        const email = emailField.text.trim()
        Calendar.addCalDavAccount({
            provider: provider,
            email: email,
            username: email,
            url: urlField.text.trim(),
            name: provider === "other" ? "" : current.title
        }, passwordField.text)
    }

    onOpened: emailField.forceActiveFocus()
    onClosed: {
        Calendar.cancelSetup()
        passwordField.text = ""
    }

    Connections {
        target: Calendar
        enabled: dialog.visible
        function onCalDavAdded(account) {
            passwordField.text = ""
            dialog.close()
        }
        function onSetupFailed(error) {
            dialog.errorText = error
        }
    }

    ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        implicitHeight: Math.min(form.implicitHeight, 540)

        ColumnLayout {
            id: form
            width: scroll.availableWidth
            spacing: LingmoUI.Units.largeSpacing
            enabled: !Calendar.setupBusy

            Banner {
                Layout.fillWidth: true
                text: dialog.errorText
                onClosed: dialog.errorText = ""
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: LingmoUI.Theme.disabledTextColor
                text: qsTr("Os calendários e listas de tarefas da conta são sincronizados nos dois sentidos. Google Agenda ainda não é suportado.")
            }

            // Provider choice
            GridLayout {
                Layout.fillWidth: true
                columns: 4
                columnSpacing: LingmoUI.Units.smallSpacing
                rowSpacing: LingmoUI.Units.smallSpacing
                Repeater {
                    model: dialog.providers
                    delegate: Rectangle {
                        id: choice
                        required property var modelData
                        readonly property bool selected: dialog.provider === modelData.key
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        implicitHeight: choiceLabel.implicitHeight + LingmoUI.Units.largeSpacing * 1.5
                        radius: LingmoUI.Theme.smallRadius
                        color: selected ? LingmoUI.Theme.highlightColor
                             : choiceHover.hovered ? Qt.darker(LingmoUI.Theme.alternateBackgroundColor, LingmoUI.Theme.darkMode ? 0.85 : 1.05)
                             : LingmoUI.Theme.alternateBackgroundColor
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Accessible.role: Accessible.RadioButton
                        Accessible.checked: selected
                        Accessible.name: modelData.title
                        HoverHandler { id: choiceHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                dialog.provider = choice.modelData.key
                                dialog.errorText = ""
                            }
                        }
                        Label {
                            id: choiceLabel
                            anchors.centerIn: parent
                            width: parent.width - 8
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: choice.modelData.title
                            color: choice.selected ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                        }
                    }
                }
            }

            // Reuse the address of a mail account already set up
            ColumnLayout {
                Layout.fillWidth: true
                visible: dialog.mailChoices.length > 0
                spacing: LingmoUI.Units.smallSpacing
                Label { text: qsTr("Usar a conta de e-mail"); color: LingmoUI.Theme.textColor }
                ComboBox {
                    id: mailBox
                    Layout.fillWidth: true
                    model: [qsTr("Escolha uma conta…")].concat(dialog.mailChoices.map(a => a.email))
                    onActivated: (index) => {
                        if (index > 0)
                            emailField.text = dialog.mailChoices[index - 1].email
                        passwordField.forceActiveFocus()
                    }
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: LingmoUI.Theme.disabledTextColor
                    font.pointSize: LingmoUI.Theme.fontSize * 0.9
                    text: qsTr("Informe de novo a senha de app: por segurança, o calendário guarda a sua própria cópia no chaveiro.")
                }
            }

            Label { text: dialog.provider === "other" ? qsTr("Usuário") : qsTr("E-mail"); color: LingmoUI.Theme.textColor }
            TextField {
                id: emailField
                Layout.fillWidth: true
                placeholderText: dialog.provider === "other" ? qsTr("Seu usuário no servidor") : qsTr("voce@exemplo.com")
                inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                maximumLength: 320
            }

            Label { visible: dialog.provider === "other"; text: qsTr("Servidor"); color: LingmoUI.Theme.textColor }
            TextField {
                id: urlField
                Layout.fillWidth: true
                visible: dialog.provider === "other"
                placeholderText: "https://nuvem.exemplo.com"
                inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
                maximumLength: 500
            }

            Label { text: qsTr("Senha de app"); color: LingmoUI.Theme.textColor }
            TextField {
                id: passwordField
                Layout.fillWidth: true
                echoMode: TextInput.Password
                passwordCharacter: "•"
                placeholderText: dialog.provider === "other" ? qsTr("Senha ou senha de app") : qsTr("Senha de app")
                inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhHiddenText
                onAccepted: if (connectButton.enabled) connectButton.clicked()
            }

            // How to get the app password, for the chosen provider
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: guide.implicitHeight + LingmoUI.Units.largeSpacing * 2
                radius: LingmoUI.Theme.mediumRadius
                color: LingmoUI.Theme.alternateBackgroundColor

                ColumnLayout {
                    id: guide
                    anchors.fill: parent
                    anchors.margins: LingmoUI.Units.largeSpacing
                    spacing: LingmoUI.Units.smallSpacing

                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Como configurar: %1").arg(dialog.current.title)
                        font.bold: true
                        color: LingmoUI.Theme.textColor
                    }
                    Repeater {
                        model: dialog.current.steps
                        delegate: RowLayout {
                            required property string modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: LingmoUI.Units.smallSpacing
                            Label {
                                Layout.alignment: Qt.AlignTop
                                text: (index + 1) + "."
                                color: LingmoUI.Theme.highlightColor
                                font.bold: true
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: modelData
                                color: LingmoUI.Theme.textColor
                            }
                        }
                    }
                    ActionButton {
                        Layout.topMargin: LingmoUI.Units.smallSpacing
                        visible: dialog.current.url !== ""
                        text: dialog.current.link
                        // Fixed https pages of the providers only
                        onClicked: Qt.openUrlExternally(dialog.current.url)
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: LingmoUI.Theme.disabledTextColor
                font.pointSize: LingmoUI.Theme.fontSize * 0.9
                text: qsTr("A senha fica guardada no chaveiro da sessão, não em arquivos.")
            }
        }
    }

    buttons: [
        Spinner {
            Layout.preferredWidth: 22
            Layout.preferredHeight: 22
            running: Calendar.setupBusy
        },
        Label {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: LingmoUI.Theme.disabledTextColor
            text: Calendar.setupBusy ? qsTr("Procurando calendários e sincronizando…") : ""
        },
        ActionButton {
            text: qsTr("Cancelar")
            onClicked: {
                if (Calendar.setupBusy)
                    Calendar.cancelSetup()
                else
                    dialog.close()
            }
        },
        ActionButton {
            id: connectButton
            primary: true
            text: qsTr("Conectar")
            enabled: !Calendar.setupBusy && emailField.text.trim().length > 0 && passwordField.text.length > 0
                     && (dialog.provider !== "other" || urlField.text.trim().length > 0)
            onClicked: dialog.connectAccount()
        }
    ]
}
