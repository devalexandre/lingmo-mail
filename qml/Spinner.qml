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
import LingmoUI.CompatibleModule 3.0 as LingmoUI

// A spinning arc: something is loading
Item {
    id: control

    property bool running: true
    property color color: LingmoUI.Theme.highlightColor

    implicitWidth: 28
    implicitHeight: 28
    visible: running

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.lineWidth = Math.max(2, width / 9)
            ctx.lineCap = "round"
            ctx.strokeStyle = control.color
            ctx.beginPath()
            ctx.arc(width / 2, height / 2, width / 2 - ctx.lineWidth, 0, Math.PI * 1.5)
            ctx.stroke()
        }

        RotationAnimator on rotation {
            from: 0
            to: 360
            duration: 900
            loops: Animation.Infinite
            running: control.running && control.visible
        }
    }

    onColorChanged: canvas.requestPaint()
}
