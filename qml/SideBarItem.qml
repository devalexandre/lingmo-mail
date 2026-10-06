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

// One row of the sidebar, drawn like Lingmo Settings' sidebar items:
// colored tile, title, hover tint, accent highlight when selected
Item {
    id: control

    property string title: ""
    property string tileText: ""
    // A theme icon instead of the coloured tile (folders)
    property string iconName: ""
    property int indent: 0
    property bool strongTrailing: false
    property color tileColor: LingmoUI.Theme.highlightColor
    property string trailing: ""
    property bool isCurrent: false
    property bool emphasized: false
    property alias hovered: mouseArea.containsMouse
    default property alias extra: extraRow.data
    signal clicked()

    implicitHeight: LingmoUI.Units.fontMetrics.height + LingmoUI.Units.largeSpacing * 1.5

    Rectangle {
        anchors.fill: parent
        radius: LingmoUI.Theme.mediumRadius
        color: control.isCurrent ? LingmoUI.Theme.highlightColor
             : mouseArea.containsMouse ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                 LingmoUI.Theme.textColor.b, 0.1)
             : "transparent"
        smooth: true
        Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onClicked: control.clicked()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing + control.indent
        anchors.rightMargin: LingmoUI.Units.smallSpacing
        spacing: LingmoUI.Units.smallSpacing * 1.5

        // macOS-style tile, as in Settings
        LingmoUI.IconItem {
            visible: control.iconName.length > 0 && control.tileText.length === 0
            Layout.preferredWidth: LingmoUI.Units.iconSizes.small
            Layout.preferredHeight: LingmoUI.Units.iconSizes.small
            Layout.leftMargin: 5
            Layout.rightMargin: 5
            Layout.alignment: Qt.AlignVCenter
            source: control.iconName
            smooth: true
        }

        Rectangle {
            id: tile
            visible: control.tileText.length > 0
            Layout.preferredWidth: 26
            Layout.preferredHeight: 26
            Layout.alignment: Qt.AlignVCenter
            radius: 7
            readonly property color base: LingmoUI.Theme.darkMode ? Qt.lighter(control.tileColor, 1.12)
                                                                  : Qt.darker(control.tileColor, 1.04)
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.lighter(tile.base, LingmoUI.Theme.darkMode ? 1.18 : 1.12) }
                GradientStop { position: 1.0; color: tile.base }
            }
            border.width: 1
            border.color: LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, control.isCurrent ? 0.55 : 0.18)
                                                  : Qt.rgba(0, 0, 0, control.isCurrent ? 0.0 : 0.10)
            Label {
                anchors.centerIn: parent
                text: control.tileText
                color: LingmoUI.Theme.highlightedTextColor
                font.bold: true
            }
        }

        Label {
            Layout.fillWidth: true
            text: control.title
            font.bold: control.emphasized
            color: control.isCurrent ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }

        Label {
            visible: control.trailing.length > 0
            text: control.trailing
            font.bold: control.strongTrailing
            color: control.isCurrent ? LingmoUI.Theme.highlightedTextColor
                 : control.strongTrailing ? LingmoUI.Theme.highlightColor : LingmoUI.Theme.disabledTextColor
        }

        RowLayout {
            id: extraRow
            spacing: 0
        }
    }
}
