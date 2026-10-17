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

// How to set up each provider: most big ones refuse the account password
// in mail apps and need an app password instead
ColumnLayout {
    id: guide

    // Domain of the address being added: opens that provider's guide
    property string domain: ""
    // Show only the guide for `domain` (password step)
    property bool onlyMatching: false

    spacing: LingmoUI.Units.smallSpacing

    readonly property string provider: providerOf(domain)

    function providerOf(d) {
        if (d === "gmail.com" || d === "googlemail.com") return "google"
        if (d === "yahoo.com" || d.startsWith("yahoo.") || d === "ymail.com") return "yahoo"
        if (d === "icloud.com" || d === "me.com" || d === "mac.com") return "apple"
        if (["outlook.com", "hotmail.com", "live.com", "msn.com"].indexOf(d) >= 0
                || d.startsWith("outlook.") || d.startsWith("hotmail.")) return "microsoft"
        return d ? "other" : ""
    }

    readonly property var providers: [
        {
            key: "google",
            title: qsTr("Gmail"),
            steps: [
                qsTr("Ative a verificação em duas etapas na sua Conta Google."),
                qsTr("Abra “Senhas de app”, dê um nome (por exemplo, Lingmo Mail) e clique em Criar."),
                qsTr("Copie a senha de 16 letras e use-a aqui no lugar da senha da conta. Os espaços podem ficar.")
            ],
            url: "https://myaccount.google.com/apppasswords",
            link: qsTr("Abrir Senhas de app do Google")
        },
        {
            key: "yahoo",
            title: qsTr("Yahoo"),
            steps: [
                qsTr("Abra a Segurança da conta Yahoo."),
                qsTr("Clique em “Gerar senha de app”, dê um nome e gere."),
                qsTr("Use a senha gerada aqui no lugar da senha da conta.")
            ],
            url: "https://login.yahoo.com/account/security",
            link: qsTr("Abrir Segurança do Yahoo")
        },
        {
            key: "apple",
            title: qsTr("iCloud"),
            steps: [
                qsTr("Entre na sua Conta Apple (a verificação em duas etapas precisa estar ativa)."),
                qsTr("Em Login e segurança, abra “Senhas específicas de app” e crie uma."),
                qsTr("Use essa senha aqui no lugar da senha da Conta Apple.")
            ],
            url: "https://account.apple.com/account/manage",
            link: qsTr("Abrir Conta Apple")
        },
        {
            key: "microsoft",
            title: qsTr("Outlook e Hotmail"),
            steps: [
                qsTr("Contas pessoais da Microsoft não aceitam mais senha em apps de e-mail: exigem o login da própria Microsoft, que o E-mail ainda não tem."),
                qsTr("Contas de empresa ou escola podem funcionar se o administrador tiver liberado IMAP com senha.")
            ],
            url: "",
            link: ""
        },
        {
            key: "other",
            title: qsTr("Outros provedores"),
            steps: [
                qsTr("Use seu e-mail e a senha normal da conta. Os servidores são encontrados automaticamente; se não forem, peça ao provedor os dados de IMAP e SMTP."),
                qsTr("Se a conta tiver verificação em duas etapas, o provedor pode exigir uma senha de app.")
            ],
            url: "",
            link: ""
        }
    ]

    Label {
        font.pointSize: LingmoUI.Units.fontBody
        Layout.fillWidth: true
        visible: !guide.onlyMatching
        wrapMode: Text.Wrap
        color: LingmoUI.Theme.textColor
        font.bold: true
        text: qsTr("Como configurar")
    }
    Label {
        font.pointSize: LingmoUI.Units.fontCaption
        Layout.fillWidth: true
        Layout.bottomMargin: LingmoUI.Units.smallSpacing
        visible: !guide.onlyMatching
        wrapMode: Text.Wrap
        color: LingmoUI.Theme.secondaryTextColor
        text: qsTr("Gmail, Yahoo e iCloud não aceitam a senha normal da conta em apps de e-mail. Crie uma senha de app, uma senha só para o E-mail, e use-a aqui.")
    }

    Repeater {
        model: guide.providers

        delegate: Rectangle {
            id: entry

            required property var modelData
            property bool expanded: modelData.key === guide.provider || guide.onlyMatching

            Layout.fillWidth: true
            visible: !guide.onlyMatching || modelData.key === guide.provider
            implicitHeight: content.implicitHeight + LingmoUI.Units.largeSpacing * 2
            radius: LingmoUI.Theme.mediumRadius
            color: header.containsMouse && !guide.onlyMatching
                   ? LingmoUI.Theme.hoverColor
                   : LingmoUI.Theme.alternateBackgroundColor
            Behavior on color { ColorAnimation { duration: LingmoUI.Units.shortDuration } }

            // Opening the guide of the typed provider, closing the others
            Connections {
                target: guide
                function onProviderChanged() { entry.expanded = entry.modelData.key === guide.provider }
            }

            ColumnLayout {
                id: content
                anchors.fill: parent
                anchors.margins: LingmoUI.Units.largeSpacing
                spacing: LingmoUI.Units.smallSpacing

                Item {
                    Layout.fillWidth: true
                    implicitHeight: titleRow.implicitHeight
                    visible: !guide.onlyMatching

                    RowLayout {
                        id: titleRow
                        anchors.fill: parent
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.fillWidth: true
                            text: entry.modelData.title
                            color: LingmoUI.Theme.textColor
                            font.bold: entry.expanded
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontCaption
                            text: entry.expanded ? "▾" : "▸"
                            color: LingmoUI.Theme.secondaryTextColor
                        }
                    }
                    MouseArea {
                        id: header
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: entry.expanded = !entry.expanded
                    }
                }

                Repeater {
                    model: entry.expanded ? entry.modelData.steps : []
                    delegate: RowLayout {
                        required property string modelData
                        required property int index
                        Layout.fillWidth: true
                        spacing: LingmoUI.Units.smallSpacing
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.alignment: Qt.AlignTop
                            text: (index + 1) + "."
                            color: LingmoUI.Theme.highlightColor
                            font.bold: true
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: modelData
                            color: LingmoUI.Theme.textColor
                        }
                    }
                }

                LingmoUI.ActionButton {
                    Layout.topMargin: LingmoUI.Units.smallSpacing
                    visible: entry.expanded && entry.modelData.url !== ""
                    text: entry.modelData.link
                    // Fixed https pages of the providers only
                    onClicked: Qt.openUrlExternally(entry.modelData.url)
                }
            }
        }
    }
}
