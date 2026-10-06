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
import LingmoUI.CompatibleModule 3.0 as LingmoUI

// Rounded push button; `primary` uses the accent color, `destructive` the red one
Button {
    id: control

    property bool primary: false
    property bool destructive: false

    implicitHeight: 34
    leftPadding: LingmoUI.Units.largeSpacing * 1.5
    rightPadding: LingmoUI.Units.largeSpacing * 1.5
    opacity: enabled ? 1.0 : 0.5
    hoverEnabled: true

    readonly property bool filled: primary || destructive

    contentItem: Label {
        text: control.text
        font.pointSize: LingmoUI.Theme.fontSize
        color: control.filled ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        radius: LingmoUI.Theme.smallRadius
        color: {
            const base = control.destructive ? LingmoUI.Theme.redColor
                       : control.primary ? LingmoUI.Theme.highlightColor
                       : LingmoUI.Theme.alternateBackgroundColor
            if (control.pressed)
                return Qt.darker(base, 1.15)
            if (control.hovered)
                return control.filled ? Qt.lighter(base, 1.1) : Qt.darker(base, LingmoUI.Theme.darkMode ? 0.85 : 1.05)
            return base
        }
        border.width: control.filled ? 0 : 1
        border.color: LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.08)

        Behavior on color { ColorAnimation { duration: 120 } }
    }
}
