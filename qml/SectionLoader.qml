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

// A page provided by another part of the app (calendar, tasks). While it isn't
// there, a neutral placeholder is shown instead.
Loader {
    id: control

    property string title: ""
    // Loaded the first time the section is shown, then kept
    property bool wanted: false
    property bool everLoaded: false

    active: wanted || everLoaded
    onLoaded: everLoaded = true

    Item {
        anchors.fill: parent
        visible: control.status !== Loader.Ready

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 80, 420)
            spacing: LingmoUI.Units.largeSpacing

            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: control.title
                font.pointSize: LingmoUI.Theme.fontSize * 1.5
                font.bold: true
                color: LingmoUI.Theme.textColor
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: control.status === Loader.Loading ? qsTr("Carregando…")
                                                       : qsTr("Esta seção ainda não está disponível nesta versão.")
                color: LingmoUI.Theme.disabledTextColor
            }
        }
    }
}
