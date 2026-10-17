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
import "CalendarUtil.js" as Util

// Small month grid: picks a day
ColumnLayout {
    id: control

    property date selected: new Date()
    property date shown: selected          // month on display
    // Days with something on them ("YYYY-MM-DD" -> true)
    property var marks: ({})
    signal picked(date day)

    readonly property var locale: Qt.locale()
    readonly property date gridStart: Util.monthGridStart(shown, locale)

    spacing: LingmoUI.Units.smallSpacing

    onSelectedChanged: {
        if (selected.getMonth() !== shown.getMonth() || selected.getFullYear() !== shown.getFullYear())
            shown = selected
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 0
        Label {
            font.pointSize: LingmoUI.Units.fontBody
            Layout.fillWidth: true
            Layout.leftMargin: LingmoUI.Units.smallSpacing
            text: Util.capitalize(control.locale.standaloneMonthName(control.shown.getMonth(), Locale.LongFormat))
                  + " " + control.shown.getFullYear()
            font.bold: true
            color: LingmoUI.Theme.textColor
            elide: Text.ElideRight
        }
        LingmoUI.IconButton {
            iconName: "go-previous"
            tipText: qsTr("Mês anterior")
            size: 26
            onClicked: control.shown = Util.addMonths(control.shown, -1)
        }
        LingmoUI.IconButton {
            iconName: "go-next"
            tipText: qsTr("Próximo mês")
            size: 26
            onClicked: control.shown = Util.addMonths(control.shown, 1)
        }
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 7
        rowSpacing: 2
        columnSpacing: 0

        Repeater {
            model: 7
            delegate: Label {
                required property int index
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: control.locale.dayName((Util.firstWeekday(control.locale) + index) % 7, Locale.NarrowFormat)
                color: LingmoUI.Theme.secondaryTextColor
                font.pointSize: LingmoUI.Units.fontCaption
            }
        }

        Repeater {
            model: 42
            delegate: Item {
                id: cell
                required property int index
                readonly property date day: Util.addDays(control.gridStart, index)
                readonly property bool inMonth: day.getMonth() === control.shown.getMonth()
                readonly property bool isToday: Util.sameDay(day, new Date())
                readonly property bool isSelected: Util.sameDay(day, control.selected)

                Layout.fillWidth: true
                implicitHeight: 26

                Rectangle {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    radius: 12
                    color: cell.isSelected ? LingmoUI.Theme.highlightColor
                         : area.containsMouse ? LingmoUI.Theme.hoverColor
                         : "transparent"
                    border.width: cell.isToday && !cell.isSelected ? 1 : 0
                    border.color: LingmoUI.Theme.highlightColor
                    Behavior on color { ColorAnimation { duration: LingmoUI.Units.veryShortDuration } }

                    Label {
                        anchors.centerIn: parent
                        text: cell.day.getDate()
                        font.pointSize: LingmoUI.Units.fontCaption
                        font.bold: cell.isToday
                        color: cell.isSelected ? LingmoUI.Theme.highlightedTextColor
                             : cell.inMonth ? LingmoUI.Theme.textColor : LingmoUI.Theme.secondaryTextColor
                    }
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: 4
                    height: 4
                    radius: 2
                    visible: !cell.isSelected && !!control.marks[Util.isoDay(cell.day)]
                    color: LingmoUI.Theme.highlightColor
                }
                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: control.picked(cell.day)
                }
            }
        }
    }
}
