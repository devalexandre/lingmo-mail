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

// Time grid for `days` days from `startDate` (7 = week, 1 = day)
Item {
    id: view

    property date startDate: new Date()
    property int days: 7
    property var dayMap: ({})
    signal createRequested(date start, bool allDay)
    signal eventClicked(var event)
    signal dayOpened(date day)

    readonly property var locale: Qt.locale()
    readonly property int hourHeight: Math.max(44, LingmoUI.Units.fontMetrics.height * 3)
    readonly property int gutter: LingmoUI.Units.fontMetrics.advanceWidth("00:00") + LingmoUI.Units.largeSpacing
    readonly property color lineColor: LingmoUI.Theme.dividerColor
    property date now: new Date()

    function scrollToMorning() {
        const today = Util.sameDay(now, startDate) || (days > 1 && now >= startDate && now < Util.addDays(startDate, days))
        const hour = today ? Math.max(0, now.getHours() - 1) : 7
        flick.contentY = Math.min(hour * hourHeight, Math.max(0, flick.contentHeight - flick.height))
    }

    Timer {
        interval: 60000
        running: view.visible
        repeat: true
        onTriggered: view.now = new Date()
    }

    Component.onCompleted: Qt.callLater(scrollToMorning)
    onStartDateChanged: Qt.callLater(scrollToMorning)

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------- Day headers
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: view.gutter
            Layout.rightMargin: scrollBar.width
            spacing: 0
            Repeater {
                model: view.days
                delegate: Item {
                    id: head
                    required property int index
                    readonly property date day: Util.addDays(view.startDate, index)
                    readonly property bool isToday: Util.sameDay(day, view.now)
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: headRow.implicitHeight + LingmoUI.Units.smallSpacing * 2

                    RowLayout {
                        id: headRow
                        anchors.centerIn: parent
                        spacing: LingmoUI.Units.smallSpacing
                        Label {
                            font.pointSize: LingmoUI.Units.fontBody
                            text: Util.capitalize(view.locale.toString(head.day, view.days === 1 ? "dddd" : "ddd"))
                            color: head.isToday ? LingmoUI.Theme.highlightColor : LingmoUI.Theme.secondaryTextColor
                        }
                        Rectangle {
                            implicitWidth: Math.max(dayNum.implicitWidth + 10, implicitHeight)
                            implicitHeight: LingmoUI.Units.fontMetrics.height + 6
                            radius: implicitHeight / 2
                            color: head.isToday ? LingmoUI.Theme.highlightColor
                                 : headArea.containsMouse ? LingmoUI.Theme.hoverColor : "transparent"
                            Behavior on color { ColorAnimation { duration: LingmoUI.Units.veryShortDuration } }
                            Label {
                                id: dayNum
                                anchors.centerIn: parent
                                text: head.day.getDate()
                                font.bold: true
                                font.pointSize: LingmoUI.Units.fontBody
                                color: head.isToday ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                            }
                        }
                    }
                    MouseArea {
                        id: headArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: view.days > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: if (view.days > 1) view.dayOpened(head.day)
                    }
                }
            }
        }

        // ---------- All-day strip
        RowLayout {
            id: allDayRow
            Layout.fillWidth: true
            Layout.rightMargin: scrollBar.width
            spacing: 0

            Label {
                Layout.preferredWidth: view.gutter
                Layout.alignment: Qt.AlignTop
                topPadding: 3
                rightPadding: LingmoUI.Units.smallSpacing
                horizontalAlignment: Text.AlignRight
                text: qsTr("dia todo")
                color: LingmoUI.Theme.secondaryTextColor
                font.pointSize: LingmoUI.Units.fontCaption
            }
            Repeater {
                model: view.days
                delegate: Rectangle {
                    id: strip
                    required property int index
                    readonly property date day: Util.addDays(view.startDate, index)
                    readonly property var items: Util.longEvents(view.dayMap[Util.isoDay(day)] || [])
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: Math.max(LingmoUI.Units.fontMetrics.height * 1.6,
                                             stripColumn.implicitHeight + 6)
                    color: "transparent"
                    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: view.lineColor }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: view.createRequested(strip.day, true)
                    }
                    Column {
                        id: stripColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 3
                        spacing: 2
                        Repeater {
                            model: strip.items.slice(0, 4)
                            delegate: EventChip {
                                required property var modelData
                                width: parent.width
                                event: modelData
                                showTime: false
                                onClicked: view.eventClicked(modelData)
                            }
                        }
                        Label {
                            visible: strip.items.length > 4
                            text: qsTr("+%1 mais").arg(strip.items.length - 4)
                            color: LingmoUI.Theme.secondaryTextColor
                            font.pointSize: LingmoUI.Units.fontCaption
                        }
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: view.lineColor }

        // ---------- Hours
        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentHeight: view.hourHeight * 24
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { id: scrollBar }

            LingmoUI.WheelHandler { target: flick }

            Item {
                width: flick.width - scrollBar.width
                height: flick.contentHeight

                // Hour lines and labels
                Repeater {
                    model: 24
                    delegate: Item {
                        required property int index
                        y: index * view.hourHeight
                        width: parent.width
                        height: view.hourHeight
                        Label {
                            width: view.gutter - LingmoUI.Units.smallSpacing
                            y: index === 0 ? 0 : -height / 2
                            horizontalAlignment: Text.AlignRight
                            visible: index > 0
                            text: (index < 10 ? "0" : "") + index + ":00"
                            color: LingmoUI.Theme.secondaryTextColor
                            font.pointSize: LingmoUI.Units.fontCaption
                        }
                        Rectangle {
                            x: view.gutter
                            width: parent.width - view.gutter
                            height: 1
                            color: view.lineColor
                        }
                    }
                }

                Row {
                    x: view.gutter
                    width: parent.width - view.gutter
                    height: parent.height

                    Repeater {
                        model: view.days
                        delegate: Item {
                            id: column
                            required property int index
                            readonly property date day: Util.addDays(view.startDate, index)
                            readonly property var placed: Util.layoutDay(view.dayMap[Util.isoDay(day)] || [], day)
                            width: parent.width / view.days
                            height: parent.height

                            Rectangle { width: 1; height: parent.height; color: view.lineColor }

                            // Click an empty slot: new event at that half hour
                            MouseArea {
                                anchors.fill: parent
                                onClicked: (mouse) => {
                                    const minutes = Math.floor(mouse.y / view.hourHeight * 2) * 30
                                    const start = new Date(column.day.getFullYear(), column.day.getMonth(),
                                                           column.day.getDate(), Math.floor(minutes / 60), minutes % 60)
                                    view.createRequested(start, false)
                                }
                            }

                            Repeater {
                                model: column.placed
                                delegate: Rectangle {
                                    id: block
                                    required property var modelData
                                    readonly property var event: modelData.event
                                    readonly property color tone: Util.tone(event.color, LingmoUI.Theme)
                                    x: 2 + (column.width - 4) * modelData.column / modelData.columns
                                    width: (column.width - 4) / modelData.columns - 2
                                    y: modelData.top / 60 * view.hourHeight + 1
                                    height: Math.max(LingmoUI.Units.fontMetrics.height + 4,
                                                     (modelData.bottom - modelData.top) / 60 * view.hourHeight - 2)
                                    radius: 6
                                    clip: true
                                    color: Qt.rgba(tone.r, tone.g, tone.b,
                                                   (blockArea.containsMouse ? 0.32 : 0.22) * (LingmoUI.Theme.darkMode ? 1.4 : 1))
                                    opacity: event.status === "TENTATIVE" ? 0.7 : 1
                                    Behavior on color { ColorAnimation { duration: LingmoUI.Units.veryShortDuration } }

                                    Rectangle {
                                        width: 3
                                        height: parent.height
                                        radius: 1.5
                                        color: block.tone
                                    }
                                    Column {
                                        anchors.fill: parent
                                        anchors.leftMargin: 7
                                        anchors.rightMargin: 4
                                        anchors.topMargin: 2
                                        Label {
                                            width: parent.width
                                            text: block.event.title
                                            font.bold: true
                                            font.pointSize: LingmoUI.Units.fontCaption
                                            color: LingmoUI.Theme.textColor
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                        }
                                        Label {
                                            width: parent.width
                                            visible: block.height > LingmoUI.Units.fontMetrics.height * 2.2
                                            text: Util.hhmm(Util.parse(block.event.start)) + " – "
                                                  + Util.hhmm(Util.parse(block.event.end))
                                                  + (block.event.location ? " · " + block.event.location : "")
                                            font.pointSize: LingmoUI.Units.fontCaption
                                            color: LingmoUI.Theme.secondaryTextColor
                                            elide: Text.ElideRight
                                            textFormat: Text.PlainText
                                        }
                                    }
                                    MouseArea {
                                        id: blockArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: view.eventClicked(block.event)
                                    }
                                }
                            }

                            // Now
                            Rectangle {
                                visible: Util.sameDay(column.day, view.now)
                                y: Util.minutesOfDay(view.now) / 60 * view.hourHeight
                                width: parent.width
                                height: 2
                                color: LingmoUI.Theme.redColor
                                Rectangle {
                                    x: -4
                                    y: -3
                                    width: 8
                                    height: 8
                                    radius: 4
                                    color: LingmoUI.Theme.redColor
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
