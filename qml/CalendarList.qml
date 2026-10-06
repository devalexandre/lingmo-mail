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
import "CalendarUtil.js" as Util

// Calendars with show/hide toggles, grouped by where they live
ColumnLayout {
    id: control

    // "VEVENT" for the calendar, "VTODO" for task lists
    property string component: "VEVENT"
    property string selectedId: ""      // task lists: the open list
    property bool selectable: false
    signal editRequested(var calendar)
    signal removeAccountRequested(var account)
    signal picked(string id)

    spacing: 2

    readonly property var groups: {
        const out = []
        const cals = Calendar.calendars.filter(c => (c.components || []).indexOf(control.component) >= 0)
        const local = cals.filter(c => c.source === "local")
        if (local.length)
            out.push({ title: qsTr("Neste computador"), account: null, items: local })
        for (let i = 0; i < Calendar.accounts.length; ++i) {
            const account = Calendar.accounts[i]
            const items = cals.filter(c => c.accountId === account.id)
            out.push({ title: account.name || account.username, account: account, items: items })
        }
        return out
    }

    Repeater {
        model: control.groups
        delegate: ColumnLayout {
            id: group
            required property var modelData
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: LingmoUI.Units.smallSpacing
                spacing: LingmoUI.Units.smallSpacing
                Label {
                    Layout.fillWidth: true
                    leftPadding: LingmoUI.Units.smallSpacing
                    text: group.modelData.title
                    color: LingmoUI.Theme.disabledTextColor
                    font.pointSize: LingmoUI.Theme.fontSize * 0.9
                    elide: Text.ElideRight
                }
                LingmoUI.IconItem {
                    visible: !!(group.modelData.account && group.modelData.account.lastError)
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    source: "dialog-warning"
                    HoverHandler { id: warnHover }
                    ToolTip.visible: warnHover.hovered
                    ToolTip.text: group.modelData.account ? group.modelData.account.lastError || "" : ""
                }
                CalendarIconButton {
                    visible: !!group.modelData.account
                    implicitWidth: 24
                    implicitHeight: 24
                    iconName: "edit-delete"
                    tipText: qsTr("Remover esta conta")
                    onClicked: control.removeAccountRequested(group.modelData.account)
                }
            }

            Label {
                visible: group.modelData.items.length === 0
                leftPadding: LingmoUI.Units.smallSpacing
                text: control.component === "VTODO" ? qsTr("Sem listas de tarefas") : qsTr("Sem calendários")
                color: LingmoUI.Theme.disabledTextColor
                font.pointSize: LingmoUI.Theme.fontSize * 0.9
            }

            Repeater {
                model: group.modelData.items
                delegate: Rectangle {
                    id: item
                    required property var modelData
                    readonly property color tone: Util.tone(modelData.color, LingmoUI.Theme)
                    readonly property bool current: control.selectable && control.selectedId === modelData.id
                    Layout.fillWidth: true
                    implicitHeight: LingmoUI.Units.fontMetrics.height + LingmoUI.Units.largeSpacing
                    radius: LingmoUI.Theme.smallRadius
                    color: current ? LingmoUI.Theme.highlightColor
                         : rowHover.hovered ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                      LingmoUI.Theme.textColor.b, 0.08) : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    HoverHandler { id: rowHover }
                    TapHandler {
                        onTapped: {
                            if (control.selectable)
                                control.picked(item.modelData.id)
                            else
                                Calendar.setCalendarHidden(item.modelData.id, !item.modelData.hidden)
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: LingmoUI.Units.smallSpacing
                        anchors.rightMargin: 2
                        spacing: LingmoUI.Units.smallSpacing

                        // Visibility toggle in the calendar's colour
                        Rectangle {
                            Layout.preferredWidth: 16
                            Layout.preferredHeight: 16
                            radius: control.selectable ? 8 : 4
                            color: item.modelData.hidden && !control.selectable ? "transparent" : item.tone
                            border.width: 2
                            border.color: item.current ? LingmoUI.Theme.highlightedTextColor : item.tone
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Label {
                                anchors.centerIn: parent
                                visible: !control.selectable && !item.modelData.hidden
                                text: "✓"
                                font.pointSize: LingmoUI.Theme.fontSize * 0.7
                                font.bold: true
                                color: LingmoUI.Theme.highlightedTextColor
                            }
                            TapHandler {
                                onTapped: Calendar.setCalendarHidden(item.modelData.id, !item.modelData.hidden)
                                enabled: !control.selectable
                            }
                            Accessible.role: Accessible.CheckBox
                            Accessible.checked: !item.modelData.hidden
                            Accessible.name: item.modelData.name
                        }
                        Label {
                            Layout.fillWidth: true
                            text: item.modelData.name
                            elide: Text.ElideRight
                            color: item.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                            textFormat: Text.PlainText
                        }
                        Label {
                            visible: !!item.modelData.readOnly
                            text: qsTr("leitura")
                            color: item.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.disabledTextColor
                            font.pointSize: LingmoUI.Theme.fontSize * 0.8
                        }
                        CalendarIconButton {
                            implicitWidth: 24
                            implicitHeight: 24
                            opacity: rowHover.hovered ? 1 : 0
                            iconName: "document-edit"
                            tipText: qsTr("Editar")
                            onClicked: control.editRequested(item.modelData)
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }
                    }
                }
            }
        }
    }
}
