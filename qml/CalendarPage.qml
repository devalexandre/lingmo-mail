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
import QtQuick.Dialogs
import QtQuick.Layouts
import LingmoUI.CompatibleModule 3.0 as LingmoUI
import Lingmo.Mail
import "CalendarUtil.js" as Util

// Calendar: month, week, day and agenda views, calendar list and upcoming events
Item {
    id: page

    property date cursor: Util.dayOnly(new Date())
    property string view: "month"           // month | week | day | agenda

    readonly property var locale: Qt.locale()
    readonly property var hidden: {
        const map = {}
        for (let i = 0; i < Calendar.calendars.length; ++i)
            if (Calendar.calendars[i].hidden)
                map[Calendar.calendars[i].id] = true
        return map
    }
    readonly property var dayMap: Util.byDay(Calendar.events.filter(e => !page.hidden[e.calendarId]))

    function range() {
        if (view === "month") {
            const start = Util.monthGridStart(cursor, locale)
            return [start, Util.addDays(start, 42)]
        }
        if (view === "week") {
            const start = Util.weekStart(cursor, locale)
            return [start, Util.addDays(start, 7)]
        }
        if (view === "day")
            return [cursor, Util.addDays(cursor, 1)]
        return [cursor, Util.addDays(cursor, 31)]
    }

    function refresh() {
        const r = range()
        Calendar.loadRange(Util.isoDay(r[0]), Util.isoDay(r[1]))
    }

    function move(step) {
        if (view === "month")
            cursor = Util.addMonths(cursor, step)
        else if (view === "week")
            cursor = Util.addDays(cursor, 7 * step)
        else if (view === "day")
            cursor = Util.addDays(cursor, step)
        else
            cursor = Util.addDays(cursor, 30 * step)
    }

    function title() {
        const r = range()
        if (view === "month")
            return locale.standaloneMonthName(cursor.getMonth(), Locale.LongFormat) + " " + cursor.getFullYear()
        if (view === "week") {
            const last = Util.addDays(r[1], -1)
            if (r[0].getMonth() === last.getMonth())
                return qsTr("%1 – %2").arg(r[0].getDate()).arg(locale.toString(last, "d 'de' MMMM 'de' yyyy"))
            return qsTr("%1 – %2").arg(locale.toString(r[0], "d MMM")).arg(locale.toString(last, "d MMM yyyy"))
        }
        if (view === "day")
            return locale.toString(cursor, "dddd, d 'de' MMMM")
        return qsTr("A partir de %1").arg(locale.toString(cursor, "d 'de' MMMM"))
    }

    // Quick create: a day from the month (next round hour today, 9:00 otherwise) or a slot
    function createAt(start, allDay, pickHour) {
        let when = start
        if (!allDay && (pickHour || (Util.minutesOfDay(start) === 0 && view === "month"))) {
            const now = new Date()
            when = Util.sameDay(start, now)
                ? new Date(now.getFullYear(), now.getMonth(), now.getDate(), Math.min(23, now.getHours() + 1))
                : new Date(start.getFullYear(), start.getMonth(), start.getDate(), 9)
        }
        eventDialog.create(when, allDay)
    }

    onCursorChanged: Qt.callLater(refresh)
    onViewChanged: Qt.callLater(refresh)
    Component.onCompleted: refresh()

    Connections {
        target: Calendar
        // A new day while the app stays open
        function onUpcomingChanged() {
            if (!Util.sameDay(todayTimer.today, new Date()))
                todayTimer.today = new Date()
        }
    }
    Timer {
        id: todayTimer
        property date today: new Date()
        interval: 60000
        repeat: true
        running: page.visible
        onTriggered: if (!Util.sameDay(today, new Date())) { today = new Date(); Calendar.reload() }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.rightMargin: LingmoUI.Units.largeSpacing * 1.5
        anchors.bottomMargin: LingmoUI.Units.largeSpacing * 1.5
        spacing: LingmoUI.Units.largeSpacing

        // ---------- Side panel
        LingmoUI.Card {
            Layout.preferredWidth: 270
            Layout.fillHeight: true

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
                    spacing: LingmoUI.Units.smallSpacing

                    LingmoUI.ActionButton {
                        Layout.fillWidth: true
                        primary: true
                        text: qsTr("Novo evento")
                        onClicked: page.createAt(page.cursor, false, true)
                    }

                    CalendarMiniMonth {
                        Layout.fillWidth: true
                        Layout.topMargin: LingmoUI.Units.smallSpacing
                        selected: page.cursor
                        marks: page.dayMap
                        onPicked: (day) => page.cursor = day
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: LingmoUI.Units.smallSpacing
                        implicitHeight: 1
                        color: LingmoUI.Theme.dividerColor
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.fillWidth: true
                            text: qsTr("Calendários")
                            font.bold: true
                            color: LingmoUI.Theme.textColor
                        }
                        LingmoUI.IconButton {
                            id: addButton
                            size: 26
                            iconName: "list-add"
                            tipText: qsTr("Adicionar")
                            onClicked: addMenu.popup(addButton, 0, addButton.height)
                        }
                    }
                    Menu {
                        id: addMenu
                        MenuItem { text: qsTr("Novo calendário"); onTriggered: calendarDialog.create() }
                        MenuItem {
                            text: qsTr("Adicionar conta (iCloud, Yahoo, CalDAV)…")
                            onTriggered: {
                                accountDialog.reset()
                                accountDialog.open()
                            }
                        }
                        MenuItem { text: qsTr("Importar arquivo .ics…"); onTriggered: importDialog.open() }
                    }

                    CalendarList {
                        Layout.fillWidth: true
                        onEditRequested: (calendar) => calendarDialog.edit(calendar)
                        onRemoveAccountRequested: (account) => {
                            confirm.action = function () { Calendar.removeCalDavAccount(account.id) }
                            confirm.title = qsTr("Remover conta?")
                            confirm.text = qsTr("Os calendários de %1 deixam de aparecer neste computador. Os eventos continuam no servidor.").arg(account.name || account.username)
                            confirm.acceptText = qsTr("Remover")
                            confirm.open()
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: LingmoUI.Units.smallSpacing
                        implicitHeight: 1
                        color: LingmoUI.Theme.dividerColor
                    }

                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        text: qsTr("Próximos")
                        font.bold: true
                        color: LingmoUI.Theme.textColor
                    }
                    CalendarAgendaList {
                        Layout.fillWidth: true
                        implicitHeight: Math.max(contentHeight, 60)
                        interactive: false
                        compact: true
                        events: Calendar.upcoming
                        hidden: page.hidden
                        from: todayTimer.today
                        maxDays: 15
                        emptyText: qsTr("Nada marcado para os próximos dias.")
                        onEventClicked: (event) => eventDialog.edit(event)
                    }
                }
            }
        }

        // ---------- Main area
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: LingmoUI.Units.largeSpacing

            LingmoUI.Banner {
                type: LingmoUI.Banner.Error
                Layout.fillWidth: true
                text: Calendar.error
                onClosed: Calendar.clearError()
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: LingmoUI.Units.smallSpacing

                LingmoUI.ActionButton {
                    text: qsTr("Hoje")
                    onClicked: page.cursor = Util.dayOnly(new Date())
                }
                LingmoUI.IconButton {
                    iconName: "go-previous"
                    tipText: qsTr("Anterior")
                    onClicked: page.move(-1)
                }
                LingmoUI.IconButton {
                    iconName: "go-next"
                    tipText: qsTr("Próximo")
                    onClicked: page.move(1)
                }
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: LingmoUI.Units.smallSpacing
                    text: Util.capitalize(page.title())
                    font.pointSize: LingmoUI.Units.fontHeading
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                    elide: Text.ElideRight
                }

                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.maximumWidth: 260
                    elide: Text.ElideRight
                    color: LingmoUI.Theme.secondaryTextColor
                    text: Calendar.syncing ? qsTr("Sincronizando…") : Calendar.status
                    visible: text.length > 0
                }
                LingmoUI.Spinner {
                    size: 16
                    running: Calendar.busy || Calendar.syncing
                }
                LingmoUI.IconButton {
                    visible: Calendar.accounts.length > 0
                    enabled: !Calendar.syncing
                    iconName: "view-refresh"
                    tipText: Calendar.lastSync
                             ? qsTr("Sincronizar (última vez: %1)").arg(page.locale.toString(Util.parse(Calendar.lastSync), "d MMM HH:mm"))
                             : qsTr("Sincronizar")
                    onClicked: Calendar.sync()
                }

                // View switch
                LingmoUI.SegmentedControl {
                    readonly property var keys: ["day", "week", "month", "agenda"]
                    model: [qsTr("Dia"), qsTr("Semana"), qsTr("Mês"), qsTr("Agenda")]
                    currentIndex: keys.indexOf(page.view)
                    onActivated: (index) => page.view = keys[index]
                }
            }

            LingmoUI.Card {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                StackLayout {
                    anchors.fill: parent
                    anchors.margins: LingmoUI.Units.smallSpacing
                    currentIndex: ["month", "week", "day", "agenda"].indexOf(page.view)

                    CalendarMonthView {
                        cursor: page.cursor
                        dayMap: page.dayMap
                        onCreateRequested: (day) => page.createAt(day, false)
                        onEventClicked: (event) => eventDialog.edit(event)
                        onDayOpened: (day) => {
                            page.cursor = day
                            page.view = "day"
                        }
                    }
                    CalendarWeekView {
                        startDate: Util.weekStart(page.cursor, page.locale)
                        days: 7
                        dayMap: page.dayMap
                        onCreateRequested: (start, allDay) => page.createAt(start, allDay)
                        onEventClicked: (event) => eventDialog.edit(event)
                        onDayOpened: (day) => {
                            page.cursor = day
                            page.view = "day"
                        }
                    }
                    CalendarWeekView {
                        startDate: page.cursor
                        days: 1
                        dayMap: page.dayMap
                        onCreateRequested: (start, allDay) => page.createAt(start, allDay)
                        onEventClicked: (event) => eventDialog.edit(event)
                    }
                    CalendarAgendaList {
                        topMargin: LingmoUI.Units.smallSpacing
                        leftMargin: LingmoUI.Units.largeSpacing
                        rightMargin: LingmoUI.Units.largeSpacing
                        events: Calendar.events
                        hidden: page.hidden
                        from: page.cursor
                        maxDays: 31
                        emptyText: qsTr("Nenhum evento nos próximos 30 dias.")
                        onEventClicked: (event) => eventDialog.edit(event)
                    }
                }
            }
        }
    }

    EventDialog {
        id: eventDialog
        scopeDialog: scopeDialog
    }

    CalendarScopeDialog {
        id: scopeDialog
    }

    CalendarEditDialog {
        id: calendarDialog
        onDeleteRequested: (calendar) => {
            confirm.action = function () { Calendar.deleteCalendar(calendar.id) }
            confirm.title = qsTr("Excluir calendário?")
            confirm.text = qsTr("O calendário %1 e todos os seus eventos e tarefas serão apagados deste computador.").arg(calendar.name)
            confirm.acceptText = qsTr("Excluir")
            confirm.open()
        }
    }

    CalendarAccountDialog {
        id: accountDialog
    }

    ConfirmDialog {
        id: confirm
        property var action: null
        destructive: true
        onAccepted: if (action) action()
    }

    FileDialog {
        id: importDialog
        title: qsTr("Importar calendário")
        nameFilters: [qsTr("Calendário (*.ics *.ical *.ifb)"), qsTr("Todos os arquivos (*)")]
        onAccepted: Calendar.importIcsFile(selectedFile, Calendar.defaultCalendarId)
    }
}
