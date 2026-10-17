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

// Repeating event: change or delete only this occurrence, or all of them
MailPopup {
    id: dialog

    property bool deleting: false
    property var pendingCallback: null
    signal chosen(string scope)

    width: Math.min(460, parent ? parent.width - 80 : 460)
    title: deleting ? qsTr("Excluir evento repetido") : qsTr("Alterar evento repetido")
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    function ask(isDelete, callback) {
        deleting = isDelete
        pendingCallback = callback
        open()
    }

    function pick(scope) {
        const callback = pendingCallback
        pendingCallback = null
        close()
        if (callback)
            callback(scope)
        chosen(scope)
    }

    Label {
        font.pointSize: LingmoUI.Units.fontCaption
        width: parent.width
        wrapMode: Text.Wrap
        color: LingmoUI.Theme.secondaryTextColor
        text: dialog.deleting ? qsTr("Este evento se repete. O que você quer excluir?")
                              : qsTr("Este evento se repete. Onde a alteração deve valer?")
    }

    buttons: [
        Item { Layout.fillWidth: true },
        LingmoUI.ActionButton {
            text: qsTr("Cancelar")
            onClicked: dialog.close()
        },
        LingmoUI.ActionButton {
            text: qsTr("Só esta ocorrência")
            onClicked: dialog.pick("this")
        },
        LingmoUI.ActionButton {
            text: qsTr("Todas")
            primary: !dialog.deleting
            destructive: dialog.deleting
            onClicked: dialog.pick("all")
        }
    ]
}
