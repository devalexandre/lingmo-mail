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

// Create or edit one rule: conditions (all / any) -> actions
MailPopup {
    id: dialog

    property string ruleId: ""
    property var conditions: []
    property var actions: []
    property string errorText: ""

    title: ruleId ? qsTr("Editar regra") : qsTr("Nova regra")
    width: Math.min(640, parent ? parent.width - 80 : 640)
    height: Math.min(600, parent ? parent.height - 60 : 600)
    closePolicy: Popup.CloseOnEscape

    readonly property var fieldModel: [
        { value: "from", text: qsTr("De contém") },
        { value: "to", text: qsTr("Para contém") },
        { value: "subject", text: qsTr("Assunto contém") },
        { value: "attachment", text: qsTr("Tem anexo") }
    ]
    readonly property var actionModel: [
        { value: "move", text: qsTr("Mover para a pasta") },
        { value: "read", text: qsTr("Marcar como lida") },
        { value: "star", text: qsTr("Marcar com estrela") },
        { value: "delete", text: qsTr("Apagar (mover para a Lixeira)") }
    ]
    readonly property var folderModel: {
        const out = []
        for (const f of Mail.folders) {
            if (f.path !== "INBOX")
                out.push({ value: f.path, text: Mail.folderTitle(f), role: f.role || "" })
        }
        return out
    }
    // A sensible first choice: the user's own folders or the archive, not Drafts or Sent
    readonly property string defaultFolder: {
        const own = folderModel.find(f => f.role === "" || f.role === "archive")
        return own ? own.value : (folderModel.length ? folderModel[0].value : "")
    }

    function edit(rule) {
        rule = rule || {}
        ruleId = rule.id || ""
        nameField.text = rule.name || ""
        matchBox.currentIndex = rule.match === "any" ? 1 : 0
        conditions = JSON.parse(JSON.stringify(rule.conditions || [{ field: "from", value: "" }]))
        actions = JSON.parse(JSON.stringify(rule.actions || [{ type: "move", folder: defaultFolder }]))
        errorText = ""
        open()
        nameField.forceActiveFocus()
    }

    // "Criar regra a partir desta mensagem"
    function fromMessage(message) {
        const address = message.senderAddress || Mail.addressOf(message.sender || "")
        edit({ name: qsTr("Mensagens de %1").arg(address),
               conditions: [{ field: "from", value: address }] })
    }

    function setCondition(index, key, value) {
        const next = conditions.slice()
        next[index] = Object.assign({}, next[index])
        next[index][key] = value
        conditions = next
    }

    function setAction(index, key, value) {
        const next = actions.slice()
        next[index] = Object.assign({}, next[index])
        next[index][key] = value
        if (key === "type" && value === "move" && !next[index].folder)
            next[index].folder = defaultFolder
        actions = next
    }

    function submit() {
        errorText = ""
        const rule = { id: ruleId, name: nameField.text.trim() || qsTr("Regra"), enabled: true,
                       match: matchBox.currentIndex === 1 ? "any" : "all",
                       conditions: conditions, actions: actions }
        const list = []
        let replaced = false
        for (const r of Mail.rules) {
            if (r.id === ruleId) {
                rule.enabled = r.enabled
                list.push(rule)
                replaced = true
            } else {
                list.push(r)
            }
        }
        if (!replaced)
            list.push(rule)
        Mail.saveRules(list)
    }

    Connections {
        target: Mail
        enabled: dialog.visible
        function onRulesSaved() { dialog.close() }
        function onRulesFailed(error) { dialog.errorText = error }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: LingmoUI.Units.largeSpacing

        Banner {
            Layout.fillWidth: true
            text: dialog.errorText
            onClosed: dialog.errorText = ""
        }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: form.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            ColumnLayout {
                id: form
                width: flick.width
                spacing: LingmoUI.Units.largeSpacing

                LingmoUI.RoundedRect {
                    Layout.fillWidth: true
                    implicitHeight: nameRow.implicitHeight + LingmoUI.Units.largeSpacing * 2
                    radius: LingmoUI.Theme.mediumRadius
                    color: LingmoUI.Theme.backgroundColor

                    GridLayout {
                        id: nameRow
                        anchors.fill: parent
                        anchors.margins: LingmoUI.Units.largeSpacing
                        columns: 2
                        columnSpacing: LingmoUI.Units.largeSpacing
                        Label { text: qsTr("Nome:"); color: LingmoUI.Theme.disabledTextColor }
                        TextField {
                            id: nameField
                            Layout.fillWidth: true
                            maximumLength: 120
                            selectByMouse: true
                            placeholderText: qsTr("Ex.: Boletos do banco")
                            validator: RegularExpressionValidator { regularExpression: /[^\r\n]*/ }
                        }
                        Label { text: qsTr("Aplicar se:"); color: LingmoUI.Theme.disabledTextColor }
                        ComboBox {
                            id: matchBox
                            Layout.fillWidth: true
                            model: [qsTr("Todas as condições forem verdadeiras"), qsTr("Qualquer condição for verdadeira")]
                        }
                    }
                }

                Label {
                    text: qsTr("Condições")
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                }

                Repeater {
                    model: dialog.conditions
                    delegate: RowLayout {
                        id: condRow
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        spacing: LingmoUI.Units.smallSpacing

                        ComboBox {
                            Layout.preferredWidth: 180
                            textRole: "text"
                            valueRole: "value"
                            model: dialog.fieldModel
                            Component.onCompleted: currentIndex = indexOfValue(condRow.modelData.field)
                            onActivated: dialog.setCondition(condRow.index, "field", currentValue)
                        }
                        TextField {
                            Layout.fillWidth: true
                            visible: condRow.modelData.field !== "attachment"
                            text: condRow.modelData.value || ""
                            maximumLength: 200
                            selectByMouse: true
                            placeholderText: condRow.modelData.field === "from" ? qsTr("banco.com.br") : qsTr("texto")
                            validator: RegularExpressionValidator { regularExpression: /[^\r\n]*/ }
                            // Edited in place: rebuilding the list would take the focus away
                            onTextEdited: dialog.conditions[condRow.index].value = text
                        }
                        Item { Layout.fillWidth: true; visible: condRow.modelData.field === "attachment" }
                        IconButton {
                            iconName: "edit-delete"
                            tipText: qsTr("Remover condição")
                            enabled: dialog.conditions.length > 1
                            onClicked: {
                                const next = dialog.conditions.slice()
                                next.splice(condRow.index, 1)
                                dialog.conditions = next
                            }
                        }
                    }
                }

                ActionButton {
                    text: qsTr("Adicionar condição")
                    enabled: dialog.conditions.length < 10
                    onClicked: dialog.conditions = dialog.conditions.concat([{ field: "subject", value: "" }])
                }

                Label {
                    Layout.topMargin: LingmoUI.Units.smallSpacing
                    text: qsTr("Ações")
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                }

                Repeater {
                    model: dialog.actions
                    delegate: RowLayout {
                        id: actRow
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        spacing: LingmoUI.Units.smallSpacing

                        ComboBox {
                            Layout.preferredWidth: 240
                            textRole: "text"
                            valueRole: "value"
                            model: dialog.actionModel
                            Component.onCompleted: currentIndex = indexOfValue(actRow.modelData.type)
                            onActivated: dialog.setAction(actRow.index, "type", currentValue)
                        }
                        ComboBox {
                            id: folderBox
                            Layout.fillWidth: true
                            visible: actRow.modelData.type === "move"
                            textRole: "text"
                            valueRole: "value"
                            model: {
                                const list = dialog.folderModel.slice()
                                const wanted = actRow.modelData.folder
                                if (wanted && !list.some(f => f.value === wanted))
                                    list.push({ value: wanted, text: qsTr("%1 (não encontrada)").arg(wanted) })
                                return list
                            }
                            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(actRow.modelData.folder))
                            onActivated: dialog.setAction(actRow.index, "folder", currentValue)
                        }
                        Item { Layout.fillWidth: true; visible: actRow.modelData.type !== "move" }
                        IconButton {
                            iconName: "edit-delete"
                            tipText: qsTr("Remover ação")
                            enabled: dialog.actions.length > 1
                            onClicked: {
                                const next = dialog.actions.slice()
                                next.splice(actRow.index, 1)
                                dialog.actions = next
                            }
                        }
                    }
                }

                ActionButton {
                    text: qsTr("Adicionar ação")
                    enabled: dialog.actions.length < 4
                    onClicked: {
                        const used = dialog.actions.map(a => a.type)
                        const free = ["read", "star", "move", "delete"].find(t => used.indexOf(t) < 0)
                        if (free)
                            dialog.actions = dialog.actions.concat([{ type: free, folder: free === "move" ? dialog.defaultFolder : "" }])
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: qsTr("As regras valem para mensagens novas na caixa de entrada desta conta, na ordem da lista. Mover ou apagar encerra a verificação da mensagem.")
                    color: LingmoUI.Theme.disabledTextColor
                    font.pointSize: LingmoUI.Theme.fontSize * 0.9
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    buttons: [
        Item { Layout.fillWidth: true },
        ActionButton {
            text: qsTr("Cancelar")
            onClicked: dialog.close()
        },
        ActionButton {
            primary: true
            text: qsTr("Salvar")
            onClicked: dialog.submit()
        }
    ]
}
