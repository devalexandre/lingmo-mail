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

// Modal sheet in the style of the store's dialogs: title, content, buttons
Popup {
    id: control

    property string title: ""
    default property alias content: body.data
    property alias buttons: buttonRow.data

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(560, parent ? parent.width - 80 : 560)
    modal: true
    focus: true
    padding: LingmoUI.Units.largeSpacing * 2
    closePolicy: Popup.CloseOnEscape

    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, LingmoUI.Theme.darkMode ? 0.45 : 0.25)
    }

    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: LingmoUI.Units.veryShortDuration }
        NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: LingmoUI.Units.veryShortDuration; easing.type: LingmoUI.Units.easing }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: LingmoUI.Units.veryShortDuration }
    }

    background: Rectangle {
        radius: LingmoUI.Theme.hugeRadius
        color: LingmoUI.Theme.secondBackgroundColor
        border.width: 1
        border.color: LingmoUI.Theme.borderColor
    }

    contentItem: ColumnLayout {
        spacing: LingmoUI.Units.largeSpacing

        Label {
            Layout.fillWidth: true
            visible: control.title.length > 0
            text: control.title
            font.pointSize: LingmoUI.Units.fontSubheading
            font.bold: true
            color: LingmoUI.Theme.textColor
            wrapMode: Text.Wrap
        }

        Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitHeight: children.length > 0 ? children[0].implicitHeight : 0
        }

        RowLayout {
            id: buttonRow
            Layout.fillWidth: true
            Layout.topMargin: LingmoUI.Units.smallSpacing
            spacing: LingmoUI.Units.largeSpacing
        }
    }
}
