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

// "Regras": automatic rules of the open account, in order
Item {
    id: control

    signal editRequested(var rule)
    property string errorText: ""

    Connections {
        target: Mail
        function onRulesFailed(error) { control.errorText = error }
        function onRulesSaved() { control.errorText = "" }
    }

    function describe(rule) {
        const fields = { from: qsTr("De contém"), to: qsTr("Para contém"), subject: qsTr("Assunto contém"),
                         attachment: qsTr("tem anexo") }
        const conds = rule.conditions.map(c => c.field === "attachment" ? fields.attachment
                                                                        : "%1 “%2”".arg(fields[c.field]).arg(c.value))
        const acts = rule.actions.map(a => {
            if (a.type === "move") {
                const f = Mail.folders.find(x => x.path === a.folder)
                return qsTr("mover para %1").arg(f ? Mail.folderTitle(f) : a.folder)
            }
            return { read: qsTr("marcar como lida"), star: qsTr("marcar com estrela"),
                     delete: qsTr("apagar") }[a.type]
        })
        return qsTr("Se %1 → %2").arg(conds.join(rule.match === "any" ? qsTr(" ou ") : qsTr(" e ")))
                                 .arg(acts.join(", "))
    }

    function saveWith(transform) {
        const list = JSON.parse(JSON.stringify(Mail.rules))
        transform(list)
        Mail.saveRules(list)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.rightMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.bottomMargin: LingmoUI.Units.largeSpacing * 1.5
        spacing: LingmoUI.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.largeSpacing

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Label {
                    text: qsTr("Regras")
                    font.pointSize: LingmoUI.Units.fontHeading
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    text: qsTr("Organizam automaticamente as mensagens novas da caixa de entrada.")
                    color: LingmoUI.Theme.secondaryTextColor
                    wrapMode: Text.Wrap
                }
            }

            ComboBox {
                Layout.preferredWidth: 240
                visible: Mail.accounts.length > 1
                model: Mail.accounts
                textRole: "email"
                valueRole: "id"
                currentIndex: indexOfValue(Mail.currentAccountId)
                onActivated: Mail.currentAccountId = currentValue
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Conta")
                ToolTip.delay: 600
            }
        }

        LingmoUI.Banner {
            type: LingmoUI.Banner.Error
            Layout.fillWidth: true
            text: control.errorText
            onClosed: control.errorText = ""
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.largeSpacing
            visible: Mail.currentIsImap

            LingmoUI.ActionButton {
                primary: true
                text: qsTr("Nova regra")
                onClicked: control.editRequested({})
            }
            LingmoUI.ActionButton {
                text: Mail.applyingRules ? qsTr("Aplicando…") : qsTr("Aplicar agora às mensagens existentes")
                enabled: !Mail.applyingRules && Mail.rules.some(r => r.enabled)
                onClicked: Mail.applyRulesNow()
            }
            LingmoUI.Spinner {
                size: 20
                running: Mail.applyingRules
            }
            Item { Layout.fillWidth: true }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: LingmoUI.Units.smallSpacing
            model: Mail.currentIsImap ? Mail.rules : []
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            LingmoUI.WheelHandler { target: list }

            delegate: LingmoUI.Card {
                id: card
                required property var modelData
                required property int index
                width: ListView.view.width
                implicitHeight: cardRow.implicitHeight + LingmoUI.Units.largeSpacing * 2
                hoverEnabled: true

                RowLayout {
                    id: cardRow
                    anchors.fill: parent
                    anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
                    anchors.rightMargin: LingmoUI.Units.largeSpacing
                    anchors.topMargin: LingmoUI.Units.largeSpacing
                    anchors.bottomMargin: LingmoUI.Units.largeSpacing
                    spacing: LingmoUI.Units.largeSpacing

                    Switch {
                        checked: card.modelData.enabled
                        onToggled: {
                            const wanted = checked
                            control.saveWith(list => list[card.index].enabled = wanted)
                        }
                        Accessible.name: qsTr("Regra ativa")
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.fillWidth: true
                            text: card.modelData.name
                            font.bold: true
                            color: card.modelData.enabled ? LingmoUI.Theme.textColor : LingmoUI.Theme.disabledTextColor
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontCaption
                            Layout.fillWidth: true
                            text: control.describe(card.modelData)
                            color: LingmoUI.Theme.secondaryTextColor
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                        }
                    }

                    LingmoUI.IconButton {
                        iconName: "go-up"
                        tipText: qsTr("Subir")
                        enabled: card.index > 0
                        onClicked: control.saveWith(list => list.splice(card.index - 1, 0, list.splice(card.index, 1)[0]))
                    }
                    LingmoUI.IconButton {
                        iconName: "go-down"
                        tipText: qsTr("Descer")
                        enabled: card.index < list.count - 1
                        onClicked: control.saveWith(list => list.splice(card.index + 1, 0, list.splice(card.index, 1)[0]))
                    }
                    LingmoUI.IconButton {
                        iconName: "document-edit"
                        tipText: qsTr("Editar")
                        onClicked: control.editRequested(card.modelData)
                    }
                    LingmoUI.IconButton {
                        iconName: "edit-delete"
                        tipText: qsTr("Apagar regra")
                        onClicked: {
                            deleteConfirm.ruleIndex = card.index
                            deleteConfirm.text = qsTr("A regra “%1” será apagada. As mensagens já organizadas não mudam.")
                                                 .arg(card.modelData.name)
                            deleteConfirm.open()
                        }
                    }
                }
            }

            LingmoUI.EmptyState {
                anchors.centerIn: parent
                width: Math.min(parent.width - 40, 420)
                visible: list.count === 0
                busy: Mail.currentIsImap && !Mail.rulesLoaded
                iconName: "view-filter"
                iconSize: LingmoUI.Units.iconSizes.large
                text: Mail.currentAccountId === "" ? qsTr("Adicione uma conta para criar regras")
                    : !Mail.currentIsImap ? qsTr("Regras precisam de uma conta IMAP: contas POP3 só baixam a caixa de entrada.")
                    : !Mail.rulesLoaded ? qsTr("Carregando regras…")
                    : qsTr("Nenhuma regra ainda. Crie uma aqui ou, ao ler uma mensagem, use “Criar regra a partir desta mensagem”.")
            }
        }
    }

    ConfirmDialog {
        id: deleteConfirm
        property int ruleIndex: -1
        title: qsTr("Apagar regra?")
        acceptText: qsTr("Apagar")
        destructive: true
        onAccepted: {
            const index = ruleIndex
            control.saveWith(list => list.splice(index, 1))
        }
    }
}
