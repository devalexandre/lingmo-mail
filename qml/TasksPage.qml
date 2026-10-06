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

// Tasks (VTODO) from local and synced lists
Item {
    id: page

    property string filter: "today"     // today | upcoming | overdue | all | done | list
    property string listId: ""

    property date today: Util.dayOnly(new Date())

    function dueDay(task) {
        return task.due ? Util.dayOnly(Util.parse(task.due)) : null
    }

    function matches(task, kind) {
        const day = dueDay(task)
        switch (kind) {
        case "today": return !task.done && !!day && day.getTime() === today.getTime()
        case "upcoming": return !task.done && !!day && day > today
        case "overdue": return !task.done && !!day && day < today
        case "all": return !task.done
        case "done": return !!task.done
        case "list": return task.calendarId === listId
        }
        return false
    }

    function count(kind) {
        let n = 0
        for (let i = 0; i < Calendar.tasks.length; ++i)
            if (matches(Calendar.tasks[i], kind))
                ++n
        return n
    }

    readonly property var shown: {
        const items = Calendar.tasks.filter(t => page.matches(t, page.filter))
        items.sort(function (a, b) {
            if (a.done !== b.done)
                return a.done ? 1 : -1
            if (a.done)
                return a.completed < b.completed ? 1 : a.completed > b.completed ? -1 : 0
            if (!!a.due !== !!b.due)
                return a.due ? -1 : 1
            if (a.due !== b.due)
                return a.due < b.due ? -1 : 1
            const pa = a.priority || 10, pb = b.priority || 10
            if (pa !== pb)
                return pa - pb
            return a.title.localeCompare(b.title)
        })
        return items
    }

    readonly property var views: [
        { key: "today", text: qsTr("Hoje"), icon: "view-calendar-day" },
        { key: "upcoming", text: qsTr("Próximas"), icon: "x-office-calendar" },
        { key: "overdue", text: qsTr("Atrasadas"), icon: "appointment-new" },
        { key: "all", text: qsTr("Todas"), icon: "view-calendar-tasks" },
        { key: "done", text: qsTr("Concluídas"), icon: "mail-mark-task" }
    ]

    readonly property string title: {
        if (filter === "list") {
            const cal = Calendar.calendar(listId)
            return cal.name || qsTr("Lista")
        }
        const v = views.find(v => v.key === filter)
        return v ? v.text : ""
    }

    function quickAdd() {
        const text = quickField.text.trim()
        if (!text)
            return
        const data = { title: text, notes: "", priority: 0 }
        if (filter === "list")
            data.calendarId = listId
        else
            data.calendarId = Calendar.defaultTaskListId
        if (filter === "today")
            data.due = Util.isoDay(today)
        else if (filter === "upcoming")
            data.due = Util.isoDay(Util.addDays(today, 1))
        Calendar.saveTask(data)
        quickField.text = ""
    }

    Timer {
        interval: 60000
        repeat: true
        running: page.visible
        onTriggered: if (!Util.sameDay(page.today, new Date())) page.today = Util.dayOnly(new Date())
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.rightMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.bottomMargin: LingmoUI.Units.largeSpacing * 1.5
        spacing: LingmoUI.Units.largeSpacing

        // ---------- Views and lists
        LingmoUI.RoundedRect {
            Layout.preferredWidth: 250
            Layout.fillHeight: true
            radius: LingmoUI.Theme.mediumRadius
            color: LingmoUI.Theme.secondBackgroundColor

            Flickable {
                id: side
                anchors.fill: parent
                anchors.margins: LingmoUI.Units.largeSpacing
                clip: true
                contentHeight: sideColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                LingmoUI.WheelHandler { target: side }

                ColumnLayout {
                    id: sideColumn
                    width: side.width
                    spacing: 2

                    Repeater {
                        model: page.views
                        delegate: Rectangle {
                            id: entry
                            required property var modelData
                            readonly property bool current: page.filter === modelData.key
                            readonly property int total: page.count(modelData.key)
                            Layout.fillWidth: true
                            implicitHeight: LingmoUI.Units.fontMetrics.height + LingmoUI.Units.largeSpacing * 1.2
                            radius: LingmoUI.Theme.mediumRadius
                            color: current ? LingmoUI.Theme.highlightColor
                                 : entryHover.hovered ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                                LingmoUI.Theme.textColor.b, 0.08) : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Accessible.role: Accessible.PageTab
                            Accessible.name: modelData.text
                            HoverHandler { id: entryHover }
                            TapHandler { onTapped: page.filter = entry.modelData.key }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: LingmoUI.Units.smallSpacing
                                anchors.rightMargin: LingmoUI.Units.largeSpacing
                                spacing: LingmoUI.Units.smallSpacing
                                LingmoUI.IconItem {
                                    Layout.preferredWidth: 18
                                    Layout.preferredHeight: 18
                                    source: entry.modelData.icon
                                }
                                Label {
                                    Layout.fillWidth: true
                                    text: entry.modelData.text
                                    color: entry.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                                }
                                Label {
                                    visible: entry.total > 0
                                    text: entry.total
                                    color: entry.current ? LingmoUI.Theme.highlightedTextColor
                                         : entry.modelData.key === "overdue" ? LingmoUI.Theme.redColor
                                         : LingmoUI.Theme.disabledTextColor
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: LingmoUI.Units.smallSpacing
                        Layout.bottomMargin: LingmoUI.Units.smallSpacing
                        implicitHeight: 1
                        color: Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g, LingmoUI.Theme.textColor.b, 0.08)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Listas")
                            font.bold: true
                            color: LingmoUI.Theme.textColor
                        }
                        CalendarIconButton {
                            implicitWidth: 26
                            implicitHeight: 26
                            iconName: "list-add"
                            tipText: qsTr("Nova lista")
                            onClicked: listDialog.create()
                        }
                    }

                    CalendarList {
                        Layout.fillWidth: true
                        component: "VTODO"
                        selectable: true
                        selectedId: page.filter === "list" ? page.listId : ""
                        onPicked: (id) => {
                            page.listId = id
                            page.filter = "list"
                        }
                        onEditRequested: (calendar) => listDialog.edit(calendar)
                        onRemoveAccountRequested: (account) => {
                            confirm.action = function () { Calendar.removeCalDavAccount(account.id) }
                            confirm.title = qsTr("Remover conta?")
                            confirm.text = qsTr("As listas e calendários de %1 deixam de aparecer neste computador. Os itens continuam no servidor.").arg(account.name || account.username)
                            confirm.acceptText = qsTr("Remover")
                            confirm.open()
                        }
                    }
                }
            }
        }

        // ---------- Tasks
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: LingmoUI.Units.largeSpacing

            Banner {
                Layout.fillWidth: true
                text: Calendar.error
                onClosed: Calendar.clearError()
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: LingmoUI.Units.smallSpacing
                Label {
                    Layout.fillWidth: true
                    text: page.title
                    font.pointSize: LingmoUI.Theme.fontSize * 1.4
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                    elide: Text.ElideRight
                }
                Label {
                    Layout.maximumWidth: 300
                    elide: Text.ElideRight
                    color: LingmoUI.Theme.disabledTextColor
                    text: Calendar.syncing ? qsTr("Sincronizando…") : Calendar.status
                    visible: text.length > 0
                }
                Spinner {
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    running: Calendar.busy || Calendar.syncing
                }
                CalendarIconButton {
                    visible: Calendar.accounts.length > 0
                    enabled: !Calendar.syncing
                    iconName: "view-refresh"
                    tipText: qsTr("Sincronizar")
                    onClicked: Calendar.sync()
                }
                ActionButton {
                    primary: true
                    text: qsTr("Nova tarefa")
                    onClicked: taskDialog.create(page.filter === "list" ? page.listId : "",
                                                 page.filter === "today" ? page.today : null)
                }
            }

            // Quick add
            LingmoUI.RoundedRect {
                Layout.fillWidth: true
                implicitHeight: quickRow.implicitHeight + LingmoUI.Units.smallSpacing * 2
                radius: LingmoUI.Theme.mediumRadius
                color: LingmoUI.Theme.secondBackgroundColor
                visible: page.filter !== "done"

                RowLayout {
                    id: quickRow
                    anchors.fill: parent
                    anchors.leftMargin: LingmoUI.Units.largeSpacing
                    anchors.rightMargin: LingmoUI.Units.smallSpacing
                    spacing: LingmoUI.Units.smallSpacing
                    LingmoUI.IconItem {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        source: "list-add"
                    }
                    TextField {
                        id: quickField
                        Layout.fillWidth: true
                        placeholderText: page.filter === "today" ? qsTr("Adicionar tarefa para hoje")
                                       : qsTr("Adicionar tarefa")
                        maximumLength: 500
                        onAccepted: page.quickAdd()
                    }
                    ActionButton {
                        text: qsTr("Adicionar")
                        enabled: quickField.text.trim().length > 0
                        onClicked: page.quickAdd()
                    }
                }
            }

            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: LingmoUI.Units.smallSpacing
                model: page.shown
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                LingmoUI.WheelHandler { target: list }

                delegate: TaskRow {
                    required property var modelData
                    width: ListView.view.width - (list.ScrollBar.vertical.visible ? list.ScrollBar.vertical.width : 0)
                    task: modelData
                    showList: page.filter !== "list"
                    onOpenRequested: taskDialog.edit(modelData)
                }

                ColumnLayout {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 80, 380)
                    visible: list.count === 0 && Calendar.tasksLoaded
                    spacing: LingmoUI.Units.smallSpacing
                    LingmoUI.IconItem {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: LingmoUI.Units.iconSizes.large
                        Layout.preferredHeight: LingmoUI.Units.iconSizes.large
                        source: "view-calendar-tasks"
                        opacity: 0.6
                    }
                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        color: LingmoUI.Theme.disabledTextColor
                        text: page.filter === "today" ? qsTr("Nada para hoje. Adicione uma tarefa acima ou crie uma a partir de um e-mail.")
                            : page.filter === "overdue" ? qsTr("Nenhuma tarefa atrasada.")
                            : page.filter === "done" ? qsTr("Nenhuma tarefa concluída ainda.")
                            : qsTr("Nenhuma tarefa aqui.")
                    }
                }
            }
        }
    }

    TaskDialog {
        id: taskDialog
    }

    CalendarEditDialog {
        id: listDialog
        title: calendar ? qsTr("Editar lista") : qsTr("Nova lista")
        onDeleteRequested: (calendar) => {
            confirm.action = function () {
                if (page.listId === calendar.id)
                    page.filter = "today"
                Calendar.deleteCalendar(calendar.id)
            }
            confirm.title = qsTr("Excluir lista?")
            confirm.text = qsTr("A lista %1 e todas as suas tarefas e eventos serão apagados deste computador.").arg(calendar.name)
            confirm.acceptText = qsTr("Excluir")
            confirm.open()
        }
    }

    ConfirmDialog {
        id: confirm
        property var action: null
        destructive: true
        onAccepted: if (action) action()
    }
}
