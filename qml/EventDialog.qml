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

// Create or edit an event
MailPopup {
    id: dialog

    property var event: null              // the occurrence being edited, null for a new one
    readonly property bool editing: !!(event && event.file)
    readonly property bool readOnly: !!(event && event.readOnly)
    property string errorText: ""
    property bool saving: false
    property bool repeatTouched: false
    property real durationMs: 3600000
    property var scopeDialog: null       // CalendarScopeDialog from the page

    width: Math.min(640, parent ? parent.width - 80 : 640)
    height: Math.min(implicitHeight, parent ? parent.height - 48 : implicitHeight)
    title: readOnly ? qsTr("Evento") : editing ? qsTr("Editar evento") : qsTr("Novo evento")
    closePolicy: Popup.CloseOnEscape

    readonly property var writableCalendars: Calendar.calendars.filter(
        c => (c.components || []).indexOf("VEVENT") >= 0 && (!c.readOnly || (dialog.event && c.id === dialog.event.calendarId)))

    readonly property var timedAlarms: [
        { text: qsTr("Sem lembrete"), value: -1 },
        { text: qsTr("Na hora do evento"), value: 0 },
        { text: qsTr("5 minutos antes"), value: 5 },
        { text: qsTr("10 minutos antes"), value: 10 },
        { text: qsTr("15 minutos antes"), value: 15 },
        { text: qsTr("30 minutos antes"), value: 30 },
        { text: qsTr("1 hora antes"), value: 60 },
        { text: qsTr("2 horas antes"), value: 120 },
        { text: qsTr("1 dia antes"), value: 1440 }
    ]
    readonly property var allDayAlarms: [
        { text: qsTr("Sem lembrete"), value: -1 },
        { text: qsTr("No dia, às 9h"), value: -540 },
        { text: qsTr("Na véspera, às 9h"), value: 900 },
        { text: qsTr("Dois dias antes, às 9h"), value: 2340 }
    ]
    property var alarmOptions: timedAlarms

    readonly property var freqs: ["NONE", "DAILY", "WEEKLY", "MONTHLY", "YEARLY"]
    readonly property var weekdays: ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
    property var byday: []
    property bool keepRule: false          // complex rule from another app: keep as is

    function setAlarmOptions(allDay, value) {
        let options = (allDay ? allDayAlarms : timedAlarms).slice()
        if (value !== undefined && value !== -1 && !options.some(o => o.value === value))
            options.push({ text: value >= 0 ? qsTr("%1 minutos antes").arg(value) : qsTr("%1 minutos depois do início").arg(-value),
                           value: value })
        alarmOptions = options
        const index = options.findIndex(o => o.value === value)
        alarmBox.currentIndex = index >= 0 ? index : 0
    }

    function startDate() {
        const d = startField.value
        if (allDaySwitch.checked)
            return new Date(d.getFullYear(), d.getMonth(), d.getDate())
        const m = Math.max(0, startTime.minutes)
        return new Date(d.getFullYear(), d.getMonth(), d.getDate(), Math.floor(m / 60), m % 60)
    }

    function endDate() {
        const d = endField.value
        if (allDaySwitch.checked)
            return new Date(d.getFullYear(), d.getMonth(), d.getDate())
        const m = Math.max(0, endTime.minutes)
        return new Date(d.getFullYear(), d.getMonth(), d.getDate(), Math.floor(m / 60), m % 60)
    }

    function setTimes(start, end) {
        startField.value = start
        endField.value = end
        startTime.setMinutes(Util.minutesOfDay(start))
        endTime.setMinutes(Util.minutesOfDay(end))
        durationMs = Math.max(0, end.getTime() - start.getTime())
    }

    function resetRepeat(rule, start) {
        repeatTouched = false
        keepRule = !!(rule && rule.complex)
        const freq = rule ? rule.freq : "NONE"
        repeatBox.currentIndex = keepRule ? 5 : Math.max(0, freqs.indexOf(freq))
        intervalBox.value = rule && rule.interval ? rule.interval : 1
        byday = rule && rule.byday && rule.byday.length ? rule.byday.slice() : [weekdays[(start.getDay() + 6) % 7]]
        if (rule && rule.count) {
            endBox.currentIndex = 2
            countBox.value = rule.count
        } else if (rule && rule.until) {
            endBox.currentIndex = 1
            untilField.value = Util.parse(rule.until)
        } else {
            endBox.currentIndex = 0
            countBox.value = 10
            untilField.value = Util.addMonths(start, 3)
        }
    }

    function create(start, allDay) {
        event = null
        errorText = ""
        saving = false
        titleField.text = ""
        locationField.text = ""
        notesField.text = ""
        allDaySwitch.checked = !!allDay
        const s = allDay ? Util.dayOnly(start) : start
        setTimes(s, allDay ? s : new Date(s.getTime() + 3600000))
        resetRepeat(null, s)
        setAlarmOptions(!!allDay, allDay ? -1 : 15)
        const ids = writableCalendars.map(c => c.id)
        calendarBox.currentIndex = Math.max(0, ids.indexOf(Calendar.defaultCalendarId))
        open()
        titleField.forceActiveFocus()
    }

    function edit(ev) {
        event = ev
        errorText = ""
        saving = false
        titleField.text = ev.title
        locationField.text = ev.location || ""
        notesField.text = ev.notes || ""
        allDaySwitch.checked = ev.allDay
        const start = Util.parse(ev.start)
        let end = Util.parse(ev.end)
        if (ev.allDay)
            end = Util.addDays(end, -1)   // the dialog shows the last day, not the day after
        setTimes(start, end)
        resetRepeat(ev.rrule, start)
        setAlarmOptions(ev.allDay, ev.alarm)
        calendarBox.currentIndex = Math.max(0, writableCalendars.map(c => c.id).indexOf(ev.calendarId))
        open()
    }

    function rule() {
        const freq = freqs[repeatBox.currentIndex] || "NONE"
        return {
            freq: freq,
            interval: intervalBox.value,
            byday: freq === "WEEKLY" ? byday : [],
            count: endBox.currentIndex === 2 ? countBox.value : 0,
            until: endBox.currentIndex === 1 ? Util.isoDay(untilField.value) : ""
        }
    }

    function payload(scope) {
        const allDay = allDaySwitch.checked
        const start = startDate()
        const end = endDate()
        const cal = writableCalendars[calendarBox.currentIndex]
        const data = {
            calendarId: cal ? cal.id : Calendar.defaultCalendarId,
            title: titleField.text.trim(),
            location: locationField.text.trim(),
            notes: notesField.text,
            allDay: allDay,
            start: allDay ? Util.isoDay(start) : Util.isoMinute(start),
            end: allDay ? Util.isoDay(end) : Util.isoMinute(end),
            alarm: alarmOptions[alarmBox.currentIndex] ? alarmOptions[alarmBox.currentIndex].value : -1,
            scope: scope
        }
        if (!editing || (repeatTouched && !keepRule))
            data.rrule = rule()
        else if (repeatTouched && keepRule && repeatBox.currentIndex !== 5)
            data.rrule = rule()
        if (editing) {
            data.file = event.file
            data.uid = event.uid
            data.originalCalendarId = event.calendarId
            data.recurrenceId = event.recurrenceId
            data.occurrenceStart = event.start
        }
        return data
    }

    function validate() {
        if (!allDaySwitch.checked && (startTime.minutes < 0 || endTime.minutes < 0))
            return qsTr("Informe os horários no formato 14:30.")
        if (endDate() < startDate())
            return qsTr("O fim precisa ser depois do início.")
        return ""
    }

    function save() {
        errorText = validate()
        if (errorText)
            return
        const recurring = editing && event.recurring
        const cal = writableCalendars[calendarBox.currentIndex]
        const moved = editing && cal && cal.id !== event.calendarId
        if (recurring && !repeatTouched && !moved && scopeDialog) {
            scopeDialog.ask(false, function (scope) {
                saving = true
                Calendar.saveEvent(payload(scope))
            })
            return
        }
        saving = true
        Calendar.saveEvent(payload("all"))
    }

    function remove() {
        if (event.recurring && scopeDialog) {
            scopeDialog.ask(true, function (scope) {
                Calendar.deleteEvent(event, scope)
                dialog.close()
            })
            return
        }
        Calendar.deleteEvent(event, "all")
        close()
    }

    Connections {
        target: Calendar
        enabled: dialog.visible
        function onEventSaved(result) {
            dialog.saving = false
            dialog.close()
        }
        function onEventSaveFailed(error) {
            dialog.saving = false
            dialog.errorText = error
        }
    }

    ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        implicitHeight: Math.min(form.implicitHeight, 560)

        ColumnLayout {
            id: form
            width: scroll.availableWidth
            spacing: LingmoUI.Units.largeSpacing
            enabled: !dialog.readOnly

            LingmoUI.Banner {
                type: LingmoUI.Banner.Error
                Layout.fillWidth: true
                text: dialog.errorText
                onClosed: dialog.errorText = ""
            }
            LingmoUI.Banner {
                Layout.fillWidth: true
                type: LingmoUI.Banner.Info
                closable: false
                text: dialog.readOnly ? qsTr("Este calendário é somente leitura.") : ""
            }

            TextField {
                id: titleField
                Layout.fillWidth: true
                placeholderText: qsTr("Título")
                font.pointSize: LingmoUI.Units.fontBody
                maximumLength: 500
                onAccepted: if (saveButton.enabled) dialog.save()
            }
            TextField {
                id: locationField
                Layout.fillWidth: true
                placeholderText: qsTr("Local")
                maximumLength: 500
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 3
                columnSpacing: LingmoUI.Units.largeSpacing
                rowSpacing: LingmoUI.Units.smallSpacing

                Label { text: qsTr("Dia inteiro"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                Switch {
                    id: allDaySwitch
                    Layout.columnSpan: 2
                    onToggled: {
                        dialog.setAlarmOptions(checked, checked ? -1 : 15)
                        if (!checked && startTime.minutes < 0) {
                            startTime.setMinutes(9 * 60)
                            endTime.setMinutes(10 * 60)
                        }
                    }
                }

                Label { text: qsTr("Início"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                CalendarDateField {
                    id: startField
                    Layout.fillWidth: true
                    onEdited: (value) => {
                        const end = new Date(dialog.startDate().getTime() + dialog.durationMs)
                        endField.value = end
                        if (!allDaySwitch.checked)
                            endTime.setMinutes(Util.minutesOfDay(end))
                    }
                }
                CalendarTimeField {
                    id: startTime
                    visible: !allDaySwitch.checked
                    onEditingFinished: {
                        if (minutes < 0)
                            return
                        const end = new Date(dialog.startDate().getTime() + dialog.durationMs)
                        endField.value = end
                        endTime.setMinutes(Util.minutesOfDay(end))
                    }
                }
                Item { visible: allDaySwitch.checked; implicitWidth: startTime.implicitWidth }

                Label { text: qsTr("Fim"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                CalendarDateField {
                    id: endField
                    Layout.fillWidth: true
                    onEdited: dialog.durationMs = Math.max(0, dialog.endDate().getTime() - dialog.startDate().getTime())
                }
                CalendarTimeField {
                    id: endTime
                    visible: !allDaySwitch.checked
                    onEditingFinished: if (minutes >= 0)
                                           dialog.durationMs = Math.max(0, dialog.endDate().getTime() - dialog.startDate().getTime())
                }
                Item { visible: allDaySwitch.checked; implicitWidth: endTime.implicitWidth }

                Label { text: qsTr("Repetir"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                ComboBox {
                    id: repeatBox
                    Layout.fillWidth: true
                    Layout.columnSpan: 2
                    model: {
                        const items = [qsTr("Não repete"), qsTr("Todos os dias"), qsTr("Toda semana"),
                                       qsTr("Todo mês"), qsTr("Todo ano")]
                        if (dialog.keepRule && dialog.event)
                            items.push(dialog.event.rrule.text || qsTr("Regra personalizada"))
                        return items
                    }
                    onActivated: dialog.repeatTouched = true
                }

                // Weekdays for weekly events
                Item { visible: repeatBox.currentIndex === 2; implicitHeight: 1 }
                Flow {
                    Layout.fillWidth: true
                    Layout.columnSpan: 2
                    visible: repeatBox.currentIndex === 2
                    spacing: 4
                    Repeater {
                        model: dialog.weekdays
                        delegate: Rectangle {
                            id: dayToggle
                            required property string modelData
                            required property int index
                            readonly property bool on: dialog.byday.indexOf(modelData) >= 0
                            width: 34
                            height: 30
                            radius: LingmoUI.Theme.smallRadius
                            color: on ? LingmoUI.Theme.highlightColor : LingmoUI.Theme.alternateBackgroundColor
                            Behavior on color { ColorAnimation { duration: LingmoUI.Units.veryShortDuration } }
                            Accessible.role: Accessible.CheckBox
                            Accessible.checked: on
                            Accessible.name: Qt.locale().dayName((index + 1) % 7, Locale.LongFormat)
                            Label {
                                font.pointSize: LingmoUI.Units.fontBody
                                anchors.centerIn: parent
                                text: Qt.locale().dayName((dayToggle.index + 1) % 7, Locale.NarrowFormat)
                                color: dayToggle.on ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                            }
                            TapHandler {
                                onTapped: {
                                    const list = dialog.byday.slice()
                                    const at = list.indexOf(dayToggle.modelData)
                                    if (at >= 0 && list.length > 1)
                                        list.splice(at, 1)
                                    else if (at < 0)
                                        list.push(dayToggle.modelData)
                                    dialog.byday = list
                                    dialog.repeatTouched = true
                                }
                            }
                        }
                    }
                }

                Item { visible: repeatBox.currentIndex > 0 && repeatBox.currentIndex < 5; implicitHeight: 1 }
                RowLayout {
                    Layout.columnSpan: 2
                    visible: repeatBox.currentIndex > 0 && repeatBox.currentIndex < 5
                    spacing: LingmoUI.Units.smallSpacing
                    Label { text: qsTr("A cada"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                    SpinBox {
                        id: intervalBox
                        from: 1
                        to: 99
                        editable: true
                        onValueModified: dialog.repeatTouched = true
                    }
                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        text: [qsTr("dia(s)"), qsTr("dia(s)"), qsTr("semana(s)"), qsTr("mês(es)"), qsTr("ano(s)")][repeatBox.currentIndex] || ""
                        color: LingmoUI.Theme.textColor
                    }
                }

                Item { visible: repeatBox.currentIndex > 0 && repeatBox.currentIndex < 5; implicitHeight: 1 }
                RowLayout {
                    Layout.columnSpan: 2
                    visible: repeatBox.currentIndex > 0 && repeatBox.currentIndex < 5
                    spacing: LingmoUI.Units.smallSpacing
                    ComboBox {
                        id: endBox
                        model: [qsTr("Sem fim"), qsTr("Até"), qsTr("Depois de")]
                        onActivated: dialog.repeatTouched = true
                    }
                    CalendarDateField {
                        id: untilField
                        visible: endBox.currentIndex === 1
                        onEdited: dialog.repeatTouched = true
                    }
                    SpinBox {
                        id: countBox
                        visible: endBox.currentIndex === 2
                        from: 1
                        to: 999
                        editable: true
                        onValueModified: dialog.repeatTouched = true
                    }
                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        visible: endBox.currentIndex === 2
                        text: qsTr("vezes")
                        color: LingmoUI.Theme.textColor
                    }
                }

                Label { text: qsTr("Lembrete"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                ComboBox {
                    id: alarmBox
                    Layout.fillWidth: true
                    Layout.columnSpan: 2
                    model: dialog.alarmOptions
                    textRole: "text"
                }

                Label { text: qsTr("Calendário"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                ComboBox {
                    id: calendarBox
                    Layout.fillWidth: true
                    Layout.columnSpan: 2
                    model: dialog.writableCalendars
                    textRole: "name"
                }
            }

            Label { text: qsTr("Notas"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
            TextArea {
                id: notesField
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(90, implicitHeight)
                wrapMode: TextEdit.Wrap
                placeholderText: qsTr("Detalhes, links, pauta…")
                textFormat: TextEdit.PlainText
            }

            // ---------- People (from invitations; shown only)
            ColumnLayout {
                Layout.fillWidth: true
                visible: !!(dialog.event && (dialog.event.organizer || (dialog.event.attendees || []).length))
                spacing: 2
                Label { text: qsTr("Convidados"); color: LingmoUI.Theme.textColor; font.pointSize: LingmoUI.Units.fontBody }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    visible: !!(dialog.event && dialog.event.organizer)
                    text: dialog.event && dialog.event.organizer
                          ? qsTr("Organizador: %1").arg(dialog.event.organizer.name || dialog.event.organizer.email) : ""
                    color: LingmoUI.Theme.secondaryTextColor
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Repeater {
                    model: dialog.event ? (dialog.event.attendees || []) : []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: LingmoUI.Units.smallSpacing
                        Rectangle {
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: modelData.partstat === "ACCEPTED" ? LingmoUI.Theme.greenColor
                                 : modelData.partstat === "DECLINED" ? LingmoUI.Theme.redColor
                                 : modelData.partstat === "TENTATIVE" ? LingmoUI.Theme.orangeColor
                                 : LingmoUI.Theme.greyColor
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            Layout.fillWidth: true
                            text: modelData.name ? modelData.name + " <" + modelData.email + ">" : modelData.email
                            elide: Text.ElideRight
                            color: LingmoUI.Theme.textColor
                            textFormat: Text.PlainText
                        }
                        Label {
                            font.pointSize: LingmoUI.Units.fontCaption
                            text: modelData.partstat === "ACCEPTED" ? qsTr("aceitou")
                                : modelData.partstat === "DECLINED" ? qsTr("recusou")
                                : modelData.partstat === "TENTATIVE" ? qsTr("talvez")
                                : qsTr("sem resposta")
                            color: LingmoUI.Theme.secondaryTextColor
                        }
                    }
                }
            }
        }
    }

    buttons: [
        LingmoUI.ActionButton {
            visible: dialog.editing && !dialog.readOnly
            text: qsTr("Excluir")
            destructive: true
            onClicked: dialog.remove()
        },
        Item { Layout.fillWidth: true },
        LingmoUI.Spinner {
                        running: dialog.saving
        },
        LingmoUI.ActionButton {
            text: dialog.readOnly ? qsTr("Fechar") : qsTr("Cancelar")
            onClicked: dialog.close()
        },
        LingmoUI.ActionButton {
            id: saveButton
            visible: !dialog.readOnly
            primary: true
            text: qsTr("Salvar")
            enabled: !dialog.saving
            onClicked: dialog.save()
        }
    ]
}
