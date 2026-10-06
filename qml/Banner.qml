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

// An inline message: red for errors, accent color for information
Rectangle {
    id: control

    property string text: ""
    property bool error: true
    property bool closable: true
    signal closed()

    visible: text.length > 0
    implicitHeight: visible ? row.implicitHeight + LingmoUI.Units.largeSpacing * 1.5 : 0
    radius: LingmoUI.Theme.smallRadius
    readonly property color tone: error ? LingmoUI.Theme.redColor : LingmoUI.Theme.highlightColor
    color: Qt.rgba(tone.r, tone.g, tone.b, LingmoUI.Theme.darkMode ? 0.22 : 0.12)
    border.width: 1
    border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.35)

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: LingmoUI.Units.largeSpacing
        anchors.rightMargin: LingmoUI.Units.largeSpacing
        spacing: LingmoUI.Units.largeSpacing

        Rectangle {
            Layout.preferredWidth: 6
            Layout.preferredHeight: 6
            radius: 3
            color: control.tone
        }

        Label {
            Layout.fillWidth: true
            text: control.text
            wrapMode: Text.Wrap
            color: LingmoUI.Theme.textColor
            textFormat: Text.PlainText
        }

        Rectangle {
            id: closeButton
            visible: control.closable
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            radius: width / 2
            color: closeArea.containsMouse ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                     LingmoUI.Theme.textColor.b, 0.12) : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Fechar aviso")

            Label {
                anchors.centerIn: parent
                text: "\u2715"
                color: LingmoUI.Theme.textColor
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: control.closed()
            }
        }
    }
}
