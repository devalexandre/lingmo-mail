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

// One event in a month cell or the all-day strip: filled for all-day events,
// a coloured dot and the time for the others
Rectangle {
    id: chip

    property var event: ({})
    property bool showTime: !event.allDay
    signal clicked()

    readonly property color tone: Util.tone(event.color, LingmoUI.Theme)
    readonly property bool filled: !!event.allDay
    readonly property bool tentative: event.status === "TENTATIVE"

    implicitHeight: Math.round(LingmoUI.Units.fontMetrics.height * 1.35)
    radius: 4
    color: filled ? Qt.rgba(tone.r, tone.g, tone.b, area.containsMouse ? 1.0 : 0.85)
                  : area.containsMouse ? Qt.rgba(tone.r, tone.g, tone.b, 0.18) : "transparent"
    opacity: tentative ? 0.7 : 1
    Behavior on color { ColorAnimation { duration: LingmoUI.Units.veryShortDuration } }

    Accessible.role: Accessible.Button
    Accessible.name: event.title || ""

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        spacing: 4

        Rectangle {
            visible: !chip.filled
            Layout.preferredWidth: 7
            Layout.preferredHeight: 7
            radius: 3.5
            color: chip.tone
        }
        Label {
            visible: chip.showTime && !chip.filled
            text: Util.hhmm(Util.parse(chip.event.start))
            color: LingmoUI.Theme.secondaryTextColor
            font.pointSize: LingmoUI.Units.fontCaption
        }
        Label {
            Layout.fillWidth: true
            text: chip.event.title || ""
            elide: Text.ElideRight
            color: chip.filled ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
            font.pointSize: LingmoUI.Units.fontCaption
            textFormat: Text.PlainText
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: chip.clicked()
    }

    ToolTip.visible: area.containsMouse && (chip.event.title || "").length > 18
    ToolTip.text: chip.event.title || ""
    ToolTip.delay: 600
}
