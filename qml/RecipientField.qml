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
import Lingmo.Mail

// Recipients separated by commas, completing the one being typed from the
// address book (saved contacts first, then the collected ones)
TextField {
    id: control

    readonly property bool suggesting: popup.visible
    property var suggestions: []

    inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
    selectByMouse: true

    function currentToken() {
        const upto = text.substring(0, cursorPosition)
        const start = Math.max(upto.lastIndexOf(","), upto.lastIndexOf(";")) + 1
        return { start: start, value: upto.substring(start).trim() }
    }

    function update() {
        const token = currentToken()
        suggestions = token.value.length > 0 ? Mail.contactSuggestions(token.value, 6) : []
        list.currentIndex = 0
        if (suggestions.length > 0 && activeFocus)
            popup.open()
        else
            popup.close()
    }

    function accept(index) {
        const choice = suggestions[index]
        if (!choice)
            return
        const token = currentToken()
        let rest = text.substring(cursorPosition)
        const next = rest.search(/[,;]/)
        rest = next >= 0 ? rest.substring(next + 1).trim() : ""
        const before = text.substring(0, token.start).trim()
        const head = (before ? before + " " : "") + choice.recipient + ", "
        text = head + rest
        cursorPosition = head.length
        popup.close()
    }

    onTextEdited: update()
    onActiveFocusChanged: if (!activeFocus) popup.close()

    Keys.onPressed: (event) => {
        if (!popup.visible)
            return
        if (event.key === Qt.Key_Down) {
            list.currentIndex = Math.min(list.count - 1, list.currentIndex + 1)
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            list.currentIndex = Math.max(0, list.currentIndex - 1)
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
            control.accept(list.currentIndex)
            event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            popup.close()
            event.accepted = true
        }
    }

    Popup {
        id: popup
        y: control.height + 2
        width: Math.max(control.width, 280)
        padding: LingmoUI.Units.smallSpacing
        focus: false
        closePolicy: Popup.CloseOnPressOutsideParent

        background: Rectangle {
            radius: LingmoUI.Theme.mediumRadius
            color: LingmoUI.Theme.secondBackgroundColor
            border.width: 1
            border.color: LingmoUI.Theme.borderColor
        }

        contentItem: ListView {
            id: list
            implicitHeight: contentHeight
            interactive: false
            model: control.suggestions
            currentIndex: 0

            delegate: Item {
                id: entry
                required property var modelData
                required property int index
                readonly property bool lit: ListView.isCurrentItem || hover.containsMouse
                width: ListView.view.width
                height: column.implicitHeight + LingmoUI.Units.smallSpacing * 2

                Rectangle {
                    anchors.fill: parent
                    radius: LingmoUI.Theme.smallRadius
                    color: entry.ListView.isCurrentItem ? LingmoUI.Theme.highlightColor
                         : hover.containsMouse ? LingmoUI.Theme.hoverColor
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: LingmoUI.Units.veryShortDuration } }
                }
                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: control.accept(entry.index)
                }
                ColumnLayout {
                    id: column
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: LingmoUI.Units.largeSpacing
                    anchors.rightMargin: LingmoUI.Units.largeSpacing
                    spacing: 0
                    Label {
                        font.pointSize: LingmoUI.Units.fontBody
                        Layout.fillWidth: true
                        text: entry.modelData.name || entry.modelData.address
                        color: entry.ListView.isCurrentItem ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: !!entry.modelData.name
                        text: entry.modelData.address + (entry.modelData.collected ? "  ·  " + qsTr("coletado") : "")
                        color: entry.ListView.isCurrentItem ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.secondaryTextColor
                        font.pointSize: LingmoUI.Units.fontCaption
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                }
            }
        }
    }
}
