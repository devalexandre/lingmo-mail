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

// Events grouped by day, from `from` on: the "Agenda" view and the side panel
ListView {
    id: list

    property var events: []
    property date from: new Date()
    property int maxDays: 30
    property bool compact: false
    property var hidden: ({})
    property string emptyText: qsTr("Nada marcado.")
    signal eventClicked(var event)

    readonly property var locale: Qt.locale()

    function dayTitle(day) {
        const today = Util.dayOnly(new Date())
        if (Util.sameDay(day, today))
            return qsTr("Hoje")
        if (Util.sameDay(day, Util.addDays(today, 1)))
            return qsTr("Amanhã")
        return locale.toString(day, compact ? "ddd, d MMM" : "dddd, d 'de' MMMM")
    }

    function rows() {
        const map = Util.byDay(events.filter(e => !hidden[e.calendarId]))
        const out = []
        const start = Util.dayOnly(from)
        for (let i = 0; i < maxDays; ++i) {
            const day = Util.addDays(start, i)
            const items = map[Util.isoDay(day)]
            if (!items || !items.length)
                continue
            out.push({ header: true, title: dayTitle(day), day: day })
            for (let k = 0; k < items.length; ++k)
                out.push({ header: false, event: items[k], day: day })
        }
        return out
    }

    model: rows()
    clip: true
    spacing: 2
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {}

    LingmoUI.WheelHandler { target: list }

    LingmoUI.EmptyState {
        anchors.centerIn: parent
        width: parent.width - LingmoUI.Units.largeSpacing * 2
        visible: list.count === 0
        iconName: list.compact ? "" : "view-calendar"
        iconSize: LingmoUI.Units.iconSizes.large
        text: list.emptyText
    }

    delegate: Item {
        id: row
        required property var modelData
        width: ListView.view.width - list.leftMargin - list.rightMargin
        implicitHeight: modelData.header ? headerLabel.implicitHeight + LingmoUI.Units.smallSpacing * 2
                                         : card.implicitHeight

        Label {
            id: headerLabel
            font.pointSize: LingmoUI.Units.fontBody
            visible: row.modelData.header
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            leftPadding: LingmoUI.Units.smallSpacing
            text: row.modelData.header ? Util.capitalize(row.modelData.title) : ""
            font.bold: true
            color: LingmoUI.Theme.textColor
        }

        LingmoUI.RoundedRect {
            id: card
            visible: !row.modelData.header
            anchors.left: parent.left
            anchors.right: parent.right
            readonly property var event: row.modelData.event || ({})
            readonly property color tone: Util.tone(event.color, LingmoUI.Theme)
            implicitHeight: cardRow.implicitHeight + LingmoUI.Units.smallSpacing * 2
            radius: LingmoUI.Theme.smallRadius
            color: cardHover.hovered ? LingmoUI.Theme.alternateBackgroundColor
                                     : list.compact ? "transparent" : LingmoUI.Theme.secondBackgroundColor

            HoverHandler { id: cardHover }
            TapHandler { onTapped: list.eventClicked(card.event) }

            RowLayout {
                id: cardRow
                anchors.fill: parent
                anchors.leftMargin: LingmoUI.Units.smallSpacing
                anchors.rightMargin: LingmoUI.Units.smallSpacing
                spacing: LingmoUI.Units.smallSpacing

                Rectangle {
                    Layout.preferredWidth: 4
                    Layout.fillHeight: true
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    radius: 2
                    color: card.tone
                }
                Label {
                    Layout.preferredWidth: LingmoUI.Units.fontMetrics.advanceWidth("00:00") + 4
                    Layout.alignment: Qt.AlignTop
                    text: {
                        const e = card.event
                        if (!e.start)
                            return ""
                        const s = Util.parse(e.start)
                        if (e.allDay || !Util.sameDay(s, row.modelData.day))
                            return qsTr("dia")
                        return Util.hhmm(s)
                    }
                    color: LingmoUI.Theme.secondaryTextColor
                    font.pointSize: LingmoUI.Units.fontCaption
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        Layout.fillWidth: true
                        text: card.event.title || ""
                        elide: Text.ElideRight
                        color: LingmoUI.Theme.textColor
                        textFormat: Text.PlainText
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: {
                            const e = card.event
                            if (!e.start)
                                return ""
                            const parts = []
                            if (!e.allDay && !list.compact)
                                parts.push(Util.hhmm(Util.parse(e.start)) + " – " + Util.hhmm(Util.parse(e.end)))
                            if (e.location)
                                parts.push(e.location)
                            return parts.join(" · ")
                        }
                        elide: Text.ElideRight
                        color: LingmoUI.Theme.secondaryTextColor
                        font.pointSize: LingmoUI.Units.fontCaption
                        textFormat: Text.PlainText
                    }
                }
                LingmoUI.IconItem {
                    visible: !!card.event.recurring
                    Layout.preferredWidth: 14
                    Layout.preferredHeight: 14
                    source: "view-refresh"
                    opacity: 0.6
                }
            }
        }
    }
}
