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

// One task: check circle, title, due date, priority, list
LingmoUI.Card {
    id: row

    property var task: ({})
    property bool showList: true
    signal openRequested()

    readonly property date due: task.due ? Util.parse(task.due) : new Date(NaN)
    readonly property bool hasDue: !!task.due
    readonly property date today: Util.dayOnly(new Date())
    readonly property bool overdue: hasDue && !task.done
                                    && (task.dueAllDay ? due < today : due < new Date())
    readonly property color tone: Util.tone(task.color, LingmoUI.Theme)

    implicitHeight: content.implicitHeight + LingmoUI.Units.largeSpacing
    hoverEnabled: true
    TapHandler { onTapped: row.openRequested() }

    function dueText() {
        if (!hasDue)
            return ""
        const locale = Qt.locale()
        const day = Util.dayOnly(due)
        let text
        if (Util.sameDay(day, today))
            text = qsTr("Hoje")
        else if (Util.sameDay(day, Util.addDays(today, 1)))
            text = qsTr("Amanhã")
        else if (Util.sameDay(day, Util.addDays(today, -1)))
            text = qsTr("Ontem")
        else
            text = locale.toString(due, due.getFullYear() === today.getFullYear() ? "ddd, d MMM" : "d MMM yyyy")
        if (!task.dueAllDay)
            text += " " + Util.hhmm(due)
        return text
    }

    RowLayout {
        id: content
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing
        anchors.rightMargin: LingmoUI.Units.smallSpacing
        spacing: LingmoUI.Units.largeSpacing

        // Done toggle
        Rectangle {
            id: check
            Layout.preferredWidth: 22
            Layout.preferredHeight: 22
            radius: 11
            color: row.task.done ? LingmoUI.Theme.highlightColor
                 : checkHover.hovered ? Qt.rgba(LingmoUI.Theme.highlightColor.r, LingmoUI.Theme.highlightColor.g,
                                                LingmoUI.Theme.highlightColor.b, 0.15) : "transparent"
            border.width: 2
            border.color: row.task.done ? LingmoUI.Theme.highlightColor
                        : row.task.priority > 0 && row.task.priority <= 4 ? LingmoUI.Theme.redColor
                        : LingmoUI.Theme.secondaryTextColor
            Behavior on color { ColorAnimation { duration: LingmoUI.Units.shortDuration } }
            Accessible.role: Accessible.CheckBox
            Accessible.checked: !!row.task.done
            Accessible.name: qsTr("Concluída")

            Label {
                font.pointSize: LingmoUI.Units.fontBody
                anchors.centerIn: parent
                visible: !!row.task.done
                text: "✓"
                font.bold: true
                color: LingmoUI.Theme.highlightedTextColor
            }
            HoverHandler { id: checkHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                enabled: !row.task.readOnly
                onTapped: Calendar.completeTask(row.task.calendarId, row.task.file, !row.task.done)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: LingmoUI.Units.smallSpacing
            Layout.bottomMargin: LingmoUI.Units.smallSpacing
            spacing: 2

            Label {
                font.pointSize: LingmoUI.Units.fontBody
                Layout.fillWidth: true
                text: row.task.title || ""
                font.strikeout: !!row.task.done
                color: row.task.done ? LingmoUI.Theme.secondaryTextColor : LingmoUI.Theme.textColor
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Label {
                Layout.fillWidth: true
                visible: !!row.task.notes
                text: (row.task.notes || "").replace(/\s+/g, " ").trim()
                color: LingmoUI.Theme.secondaryTextColor
                font.pointSize: LingmoUI.Units.fontCaption
                elide: Text.ElideRight
                maximumLineCount: 1
                textFormat: Text.PlainText
            }
            RowLayout {
                spacing: LingmoUI.Units.largeSpacing
                visible: row.hasDue || row.showList || row.task.priority > 0
                Label {
                    visible: row.hasDue
                    text: row.dueText()
                    color: row.overdue ? LingmoUI.Theme.redColor : LingmoUI.Theme.secondaryTextColor
                    font.pointSize: LingmoUI.Units.fontCaption
                }
                Label {
                    visible: row.task.priority > 0 && !row.task.done
                    text: row.task.priority <= 4 ? qsTr("Alta") : row.task.priority === 5 ? qsTr("Média") : qsTr("Baixa")
                    color: row.task.priority <= 4 ? LingmoUI.Theme.redColor
                         : row.task.priority === 5 ? LingmoUI.Theme.orangeColor : LingmoUI.Theme.secondaryTextColor
                    font.pointSize: LingmoUI.Units.fontCaption
                }
                RowLayout {
                    visible: row.showList
                    spacing: 4
                    Rectangle {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        radius: 4
                        color: row.tone
                    }
                    Label {
                        text: row.task.listName || ""
                        color: LingmoUI.Theme.secondaryTextColor
                        font.pointSize: LingmoUI.Units.fontCaption
                        textFormat: Text.PlainText
                    }
                }
            }
        }

        LingmoUI.IconButton {
            opacity: row.hovered && !row.task.readOnly ? 1 : 0
            enabled: !row.task.readOnly
            iconName: "edit-delete"
            tipText: qsTr("Excluir tarefa")
            onClicked: Calendar.deleteTask(row.task.calendarId, row.task.file)
            Behavior on opacity { NumberAnimation { duration: LingmoUI.Units.veryShortDuration } }
        }
    }
}
