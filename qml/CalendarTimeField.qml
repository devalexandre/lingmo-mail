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

// "HH:MM" entry; `minutes` is -1 while the text isn't a valid time
TextField {
    id: field

    readonly property int minutes: {
        const m = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(text.trim())
        return m ? parseInt(m[1], 10) * 60 + parseInt(m[2], 10) : -1
    }

    function setMinutes(value) {
        const h = Math.floor(value / 60) % 24
        const m = value % 60
        text = (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
    }

    implicitWidth: 80
    horizontalAlignment: Text.AlignHCenter
    placeholderText: "09:00"
    inputMethodHints: Qt.ImhTime
    maximumLength: 5
    color: minutes < 0 && text.length > 0 ? LingmoUI.Theme.redColor : LingmoUI.Theme.textColor
}
