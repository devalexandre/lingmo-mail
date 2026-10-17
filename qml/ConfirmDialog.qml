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

// A small modal question, as in the store
MailPopup {
    id: control

    property string text: ""
    property string acceptText: qsTr("OK")
    property string rejectText: qsTr("Cancelar")
    property bool destructive: false
    signal accepted()

    width: Math.min(460, parent ? parent.width - 80 : 460)
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Label {
        font.pointSize: LingmoUI.Units.fontCaption
        width: parent.width
        text: control.text
        color: LingmoUI.Theme.secondaryTextColor
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    buttons: [
        Item { Layout.fillWidth: true },
        LingmoUI.ActionButton {
            text: control.rejectText
            onClicked: control.close()
        },
        LingmoUI.ActionButton {
            text: control.acceptText
            primary: true
            destructive: control.destructive
            onClicked: {
                control.close()
                control.accepted()
            }
        }
    ]
}
