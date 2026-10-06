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
import "CalendarUtil.js" as Util

// New local calendar, or name/colour of an existing one
MailPopup {
    id: dialog

    property var calendar: null
    property string color: "blue"
    signal deleteRequested(var calendar)

    width: Math.min(440, parent ? parent.width - 80 : 440)
    title: calendar ? qsTr("Editar calendário") : qsTr("Novo calendário")
    closePolicy: Popup.CloseOnEscape

    function create() {
        calendar = null
        nameField.text = ""
        color = Util.colorKeys[Calendar.calendars.length % Util.colorKeys.length]
        defaultBox.checked = false
        open()
        nameField.forceActiveFocus()
    }

    function edit(item) {
        calendar = item
        nameField.text = item.name
        color = item.color || "blue"
        defaultBox.checked = Calendar.defaultCalendarId === item.id
        open()
    }

    ColumnLayout {
        width: parent.width
        spacing: LingmoUI.Units.largeSpacing

        Label { text: qsTr("Nome"); color: LingmoUI.Theme.textColor }
        TextField {
            id: nameField
            Layout.fillWidth: true
            maximumLength: 120
            placeholderText: qsTr("Por exemplo, Trabalho")
            onAccepted: saveButton.clicked()
        }
        Label {
            Layout.fillWidth: true
            visible: !!(dialog.calendar && dialog.calendar.source === "caldav")
            wrapMode: Text.Wrap
            text: qsTr("O novo nome vale só neste computador.")
            color: LingmoUI.Theme.disabledTextColor
            font.pointSize: LingmoUI.Theme.fontSize * 0.9
        }

        Label { text: qsTr("Cor"); color: LingmoUI.Theme.textColor }
        RowLayout {
            spacing: LingmoUI.Units.smallSpacing
            Repeater {
                model: Util.colorKeys
                delegate: Rectangle {
                    required property string modelData
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: 14
                    color: Util.tone(modelData, LingmoUI.Theme)
                    border.width: dialog.color === modelData ? 3 : 0
                    border.color: LingmoUI.Theme.textColor
                    Accessible.role: Accessible.RadioButton
                    Accessible.checked: dialog.color === modelData
                    TapHandler { onTapped: dialog.color = parent.modelData }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
            }
        }

        CheckBox {
            id: defaultBox
            visible: !dialog.calendar || !dialog.calendar.readOnly
            text: qsTr("Usar para novos eventos")
        }
    }

    buttons: [
        ActionButton {
            visible: !!(dialog.calendar && dialog.calendar.source === "local")
            text: qsTr("Excluir")
            destructive: true
            onClicked: {
                dialog.close()
                dialog.deleteRequested(dialog.calendar)
            }
        },
        Item { Layout.fillWidth: true },
        ActionButton {
            text: qsTr("Cancelar")
            onClicked: dialog.close()
        },
        ActionButton {
            id: saveButton
            primary: true
            text: dialog.calendar ? qsTr("Salvar") : qsTr("Criar")
            enabled: nameField.text.trim().length > 0
            onClicked: {
                const data = { name: nameField.text.trim(), color: dialog.color, makeDefault: defaultBox.checked }
                if (dialog.calendar)
                    data.id = dialog.calendar.id
                Calendar.saveCalendar(data)
                dialog.close()
            }
        }
    ]
}
