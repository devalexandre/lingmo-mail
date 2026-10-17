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

// Create or edit a task
MailPopup {
    id: dialog

    property var task: null
    readonly property bool editing: !!(task && task.file)
    readonly property bool readOnly: !!(task && task.readOnly)

    width: Math.min(520, parent ? parent.width - 80 : 520)
    title: readOnly ? qsTr("Tarefa") : editing ? qsTr("Editar tarefa") : qsTr("Nova tarefa")
    closePolicy: Popup.CloseOnEscape

    readonly property var lists: Calendar.calendars.filter(
        c => (c.components || []).indexOf("VTODO") >= 0 && (!c.readOnly || (dialog.task && c.id === dialog.task.calendarId)))
    readonly property var priorities: [
        { text: qsTr("Nenhuma"), value: 0 },
        { text: qsTr("Alta"), value: 1 },
        { text: qsTr("Média"), value: 5 },
        { text: qsTr("Baixa"), value: 9 }
    ]

    function create(listId, dueDay) {
        task = null
        titleField.text = ""
        notesField.text = ""
        dueSwitch.checked = !!dueDay
        dueField.value = dueDay || Util.addDays(Util.dayOnly(new Date()), 1)
        timeSwitch.checked = false
        dueTime.setMinutes(9 * 60)
        priorityBox.currentIndex = 0
        doneBox.checked = false
        listBox.currentIndex = Math.max(0, lists.map(l => l.id).indexOf(listId || Calendar.defaultTaskListId))
        open()
        titleField.forceActiveFocus()
    }

    function edit(item) {
        task = item
        titleField.text = item.title
        notesField.text = item.notes || ""
        dueSwitch.checked = !!item.due
        const due = item.due ? Util.parse(item.due) : Util.addDays(Util.dayOnly(new Date()), 1)
        dueField.value = due
        timeSwitch.checked = !!item.due && !item.dueAllDay
        dueTime.setMinutes(item.due && !item.dueAllDay ? Util.minutesOfDay(due) : 9 * 60)
        const p = item.priority || 0
        priorityBox.currentIndex = p === 0 ? 0 : p <= 4 ? 1 : p === 5 ? 2 : 3
        doneBox.checked = !!item.done
        listBox.currentIndex = Math.max(0, lists.map(l => l.id).indexOf(item.calendarId))
        open()
    }

    function save() {
        const list = lists[listBox.currentIndex]
        let due = ""
        if (dueSwitch.checked) {
            const d = dueField.value
            if (timeSwitch.checked && dueTime.minutes >= 0)
                due = Util.isoMinute(new Date(d.getFullYear(), d.getMonth(), d.getDate(),
                                              Math.floor(dueTime.minutes / 60), dueTime.minutes % 60))
            else
                due = Util.isoDay(d)
        }
        const data = {
            title: titleField.text.trim(),
            notes: notesField.text,
            due: due,
            priority: priorities[priorityBox.currentIndex].value,
            done: doneBox.checked,
            calendarId: list ? list.id : Calendar.defaultTaskListId
        }
        if (editing) {
            data.file = task.file
            data.originalCalendarId = task.calendarId
        }
        Calendar.saveTask(data)
        close()
    }

    ColumnLayout {
        width: parent.width
        spacing: LingmoUI.Units.largeSpacing
        enabled: !dialog.readOnly

        TextField {
            id: titleField
            Layout.fillWidth: true
            placeholderText: qsTr("O que precisa ser feito?")
            font.pointSize: LingmoUI.Units.fontBody
            maximumLength: 500
            onAccepted: if (saveButton.enabled) dialog.save()
        }
        TextArea {
            id: notesField
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(80, implicitHeight)
            wrapMode: TextEdit.Wrap
            placeholderText: qsTr("Notas")
            textFormat: TextEdit.PlainText
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: LingmoUI.Units.largeSpacing
            rowSpacing: LingmoUI.Units.smallSpacing

            Label { text: qsTr("Prazo"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
            RowLayout {
                spacing: LingmoUI.Units.smallSpacing
                Switch { id: dueSwitch }
                CalendarDateField {
                    id: dueField
                    visible: dueSwitch.checked
                }
            }

            Label { visible: dueSwitch.checked; text: qsTr("Horário"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
            RowLayout {
                visible: dueSwitch.checked
                spacing: LingmoUI.Units.smallSpacing
                Switch { id: timeSwitch }
                CalendarTimeField {
                    id: dueTime
                    visible: timeSwitch.checked
                }
                Label {
                    Layout.fillWidth: true
                    visible: !timeSwitch.checked
                    text: qsTr("Lembrete às 9h do dia")
                    color: LingmoUI.Theme.secondaryTextColor
                    font.pointSize: LingmoUI.Units.fontCaption
                }
            }

            Label { text: qsTr("Prioridade"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
            ComboBox {
                id: priorityBox
                Layout.fillWidth: true
                model: dialog.priorities
                textRole: "text"
            }

            Label { text: qsTr("Lista"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
            ComboBox {
                id: listBox
                Layout.fillWidth: true
                model: dialog.lists
                textRole: "name"
            }

            Item { implicitHeight: 1 }
            CheckBox {
                id: doneBox
                text: qsTr("Concluída")
            }
        }
    }

    buttons: [
        LingmoUI.ActionButton {
            visible: dialog.editing && !dialog.readOnly
            text: qsTr("Excluir")
            destructive: true
            onClicked: {
                Calendar.deleteTask(dialog.task.calendarId, dialog.task.file)
                dialog.close()
            }
        },
        Item { Layout.fillWidth: true },
        LingmoUI.ActionButton {
            text: dialog.readOnly ? qsTr("Fechar") : qsTr("Cancelar")
            onClicked: dialog.close()
        },
        LingmoUI.ActionButton {
            id: saveButton
            visible: !dialog.readOnly
            primary: true
            text: qsTr("Salvar")
            enabled: titleField.text.trim().length > 0 && dialog.lists.length > 0
                     && (!timeSwitch.checked || !dueSwitch.checked || dueTime.minutes >= 0)
            onClicked: dialog.save()
        }
    ]
}
