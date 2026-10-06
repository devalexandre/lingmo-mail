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

// Small icon-only button (theme icon) with an animated hover background
AbstractButton {
    id: control

    property string iconName
    property string tipText
    property int iconSize: LingmoUI.Units.iconSizes.small

    implicitWidth: LingmoUI.Units.iconSizes.medium
    implicitHeight: LingmoUI.Units.iconSizes.medium
    hoverEnabled: true
    opacity: enabled ? 1.0 : 0.5
    Accessible.name: tipText

    background: Rectangle {
        radius: LingmoUI.Theme.smallRadius
        color: control.pressed ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                         LingmoUI.Theme.textColor.b, 0.15)
             : control.hovered || control.checked ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                            LingmoUI.Theme.textColor.b, 0.08)
             : "transparent"

        Behavior on color { ColorAnimation { duration: 120 } }
    }

    contentItem: Item {
        LingmoUI.IconItem {
            anchors.centerIn: parent
            width: control.iconSize
            height: width
            source: control.iconName
            smooth: true
        }
    }

    ToolTip.visible: hovered && tipText.length > 0
    ToolTip.text: tipText
    ToolTip.delay: 500
}
