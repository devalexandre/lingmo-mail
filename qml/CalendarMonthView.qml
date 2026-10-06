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

// Six weeks of the month around `cursor`; events from `dayMap`
Item {
    id: view

    property date cursor: new Date()
    property var dayMap: ({})
    signal createRequested(date day)
    signal eventClicked(var event)
    signal dayOpened(date day)

    readonly property var locale: Qt.locale()
    readonly property date gridStart: Util.monthGridStart(cursor, locale)
    readonly property color lineColor: Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                               LingmoUI.Theme.textColor.b, 0.08)

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Weekday names
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: LingmoUI.Units.fontMetrics.height + LingmoUI.Units.largeSpacing
            spacing: 0
            Repeater {
                model: 7
                delegate: Label {
                    required property int index
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    horizontalAlignment: Text.AlignHCenter
                    text: Util.capitalize(view.locale.dayName((Util.firstWeekday(view.locale) + index) % 7, Locale.ShortFormat))
                    color: LingmoUI.Theme.disabledTextColor
                }
            }
        }

        Grid {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 7
            rows: 6

            Repeater {
                model: 42
                delegate: Rectangle {
                    id: cell
                    required property int index
                    readonly property date day: Util.addDays(view.gridStart, index)
                    readonly property string key: Util.isoDay(day)
                    readonly property bool inMonth: day.getMonth() === view.cursor.getMonth()
                    readonly property bool isToday: Util.sameDay(day, new Date())
                    readonly property var items: view.dayMap[key] || []
                    readonly property int room: Math.max(0, Math.floor((height - dayLabel.height - 8)
                                                                       / (LingmoUI.Units.fontMetrics.height * 1.35 + 2)))
                    readonly property int shownCount: items.length > room ? Math.max(0, room - 1) : items.length

                    width: grid.width / 7
                    height: grid.height / 6
                    color: hover.hovered ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                   LingmoUI.Theme.textColor.b, 0.04) : "transparent"
                    border.width: 0
                    Behavior on color { ColorAnimation { duration: 120 } }

                    HoverHandler { id: hover }

                    // Grid lines: top and left of each cell
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: view.lineColor }
                    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: view.lineColor; visible: cell.index % 7 !== 0 }

                    // Empty space: new event on that day
                    MouseArea {
                        anchors.fill: parent
                        onClicked: view.createRequested(cell.day)
                    }

                    Rectangle {
                        id: dayLabel
                        x: 4
                        y: 4
                        width: Math.max(dayNumber.implicitWidth + 10, height)
                        height: LingmoUI.Units.fontMetrics.height + 4
                        radius: height / 2
                        color: cell.isToday ? LingmoUI.Theme.highlightColor
                             : dayArea.containsMouse ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                               LingmoUI.Theme.textColor.b, 0.1) : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }

                        Label {
                            id: dayNumber
                            anchors.centerIn: parent
                            text: cell.day.getDate() === 1
                                  ? view.locale.toString(cell.day, "d MMM") : cell.day.getDate()
                            font.bold: cell.isToday
                            color: cell.isToday ? LingmoUI.Theme.highlightedTextColor
                                 : cell.inMonth ? LingmoUI.Theme.textColor : LingmoUI.Theme.disabledTextColor
                        }
                        MouseArea {
                            id: dayArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: view.dayOpened(cell.day)
                        }
                        ToolTip.visible: dayArea.containsMouse
                        ToolTip.text: qsTr("Ver o dia")
                        ToolTip.delay: 700
                    }

                    Column {
                        anchors.top: dayLabel.bottom
                        anchors.topMargin: 2
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 3
                        anchors.rightMargin: 3
                        spacing: 2

                        Repeater {
                            model: cell.items.slice(0, cell.shownCount)
                            delegate: EventChip {
                                required property var modelData
                                width: parent.width
                                event: modelData
                                onClicked: view.eventClicked(modelData)
                            }
                        }
                        Label {
                            visible: cell.items.length > cell.shownCount
                            leftPadding: 4
                            text: qsTr("+%1 mais").arg(cell.items.length - cell.shownCount)
                            color: moreArea.containsMouse ? LingmoUI.Theme.highlightColor : LingmoUI.Theme.disabledTextColor
                            font.pointSize: LingmoUI.Theme.fontSize * 0.85
                            MouseArea {
                                id: moreArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: view.dayOpened(cell.day)
                            }
                        }
                    }
                }
            }
        }
    }
}
