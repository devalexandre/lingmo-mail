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

// A date shown as text; clicking opens a small month to pick another
AbstractButton {
    id: control

    property date value: new Date()
    signal edited(date value)

    implicitWidth: Math.max(150, label.implicitWidth + LingmoUI.Units.largeSpacing * 2)
    implicitHeight: 34
    hoverEnabled: true

    background: Rectangle {
        radius: LingmoUI.Theme.smallRadius
        color: control.hovered ? Qt.darker(LingmoUI.Theme.alternateBackgroundColor, LingmoUI.Theme.darkMode ? 0.85 : 1.05)
                               : LingmoUI.Theme.alternateBackgroundColor
        border.width: 1
        border.color: popup.visible ? LingmoUI.Theme.highlightColor
                                    : LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.08)
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    contentItem: Label {
        id: label
        text: Qt.locale().toString(control.value, "ddd, d MMM yyyy")
        color: control.enabled ? LingmoUI.Theme.textColor : LingmoUI.Theme.disabledTextColor
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    onClicked: popup.open()

    Popup {
        id: popup
        y: control.height + 4
        width: 260
        padding: LingmoUI.Units.largeSpacing
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        background: Rectangle {
            radius: LingmoUI.Theme.mediumRadius
            color: LingmoUI.Theme.secondBackgroundColor
            border.width: 1
            border.color: LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.12)
        }

        contentItem: CalendarMiniMonth {
            selected: control.value
            onPicked: (day) => {
                control.value = day
                control.edited(day)
                popup.close()
            }
        }
    }
}
