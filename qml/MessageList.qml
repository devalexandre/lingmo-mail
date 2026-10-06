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

// Middle pane: the open folder, with server-side search, quick filters, pagination
// and multi-selection (Ctrl/Shift + click)
Item {
    id: control

    implicitWidth: 340

    // id -> true
    property var selected: ({})
    property int anchorRow: -1
    readonly property var selectedIds: Object.keys(selected)
    readonly property bool imap: Mail.currentIsImap
    readonly property bool inTrash: Mail.currentFolderRole === "trash"

    signal moveRequested(var ids, Item anchor)
    signal rulesRequested()

    // What actions apply to: the selection, else the open message
    function targetIds() {
        if (selectedIds.length > 0)
            return selectedIds
        return Mail.currentMessageId !== "" ? [Mail.currentMessageId] : []
    }

    function clearSelection() {
        selected = ({})
        anchorRow = -1
    }

    function rowClicked(row, id, modifiers) {
        if (modifiers & Qt.ShiftModifier && anchorRow >= 0) {
            const next = (modifiers & Qt.ControlModifier) ? Object.assign({}, selected) : ({})
            for (const key of Mail.idsBetween(anchorRow, row))
                next[key] = true
            selected = next
            return
        }
        if (modifiers & Qt.ControlModifier) {
            const next = Object.assign({}, selected)
            if (Object.keys(next).length === 0 && Mail.currentMessageId !== "")
                next[Mail.currentMessageId] = true
            if (next[id])
                delete next[id]
            else
                next[id] = true
            selected = next
            anchorRow = row
            return
        }
        const only = {}
        only[id] = true
        selected = only
        anchorRow = row
        Mail.openMessage(id)
        list.currentIndex = row
    }

    function selectAll() {
        const next = {}
        for (const key of Mail.idsBetween(0, list.count - 1))
            next[key] = true
        selected = next
    }

    function anyUnread(ids) {
        for (const id of ids) {
            const m = Mail.messageAt(Mail.rowOf(id))
            if (m.unread)
                return true
        }
        return false
    }

    function allStarred(ids) {
        for (const id of ids) {
            if (!Mail.messageAt(Mail.rowOf(id)).starred)
                return false
        }
        return ids.length > 0
    }

    // ---------- Actions (also used by the window's shortcuts)
    function toggleRead() {
        const ids = targetIds()
        if (imap && ids.length)
            Mail.markRead(ids, anyUnread(ids))
    }
    function toggleStar() {
        const ids = targetIds()
        if (imap && ids.length)
            Mail.setStarred(ids, !allStarred(ids))
    }
    function archiveSelected() {
        const ids = targetIds()
        if (imap && ids.length) {
            Mail.archive(ids)
            clearSelection()
        }
    }
    function deleteSelected() {
        const ids = targetIds()
        if (imap && ids.length) {
            Mail.deleteMessages(ids, false)
            clearSelection()
        }
    }
    function moveSelected(target) {
        const ids = targetIds()
        if (imap && ids.length) {
            Mail.moveMessages(ids, target)
            clearSelection()
        }
    }
    function step(delta) {
        const row = Math.max(0, Math.min(list.count - 1, (Mail.rowOf(Mail.currentMessageId) >= 0
                                                           ? Mail.rowOf(Mail.currentMessageId) : -1) + delta))
        const m = Mail.messageAt(row)
        if (m.id) {
            rowClicked(row, m.id, 0)
            list.positionViewAtIndex(row, ListView.Contain)
        }
    }

    // A new search, filter or order starts at the top once its results arrive
    property bool scrollToTop: false

    Connections {
        target: Mail
        function onQueryChanged() { control.scrollToTop = true }
        function onMessagesChanged() {
            if (control.scrollToTop && !Mail.loadingInbox) {
                control.scrollToTop = false
                list.positionViewAtBeginning()
            }
        }
        function onFolderChanged() {
            control.clearSelection()
            search.text = ""
        }
        function onCurrentAccountChanged() { control.clearSelection() }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: LingmoUI.Units.largeSpacing
        spacing: LingmoUI.Units.smallSpacing * 1.5

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.smallSpacing

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Label {
                    Layout.fillWidth: true
                    text: Mail.folderTitle(Mail.currentFolderInfo)
                    font.pointSize: LingmoUI.Theme.fontSize * 1.3
                    font.bold: true
                    color: LingmoUI.Theme.textColor
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Label {
                    Layout.fillWidth: true
                    text: {
                        const email = Mail.currentAccount.email || ""
                        if (!Mail.inboxLoaded)
                            return email
                        return Mail.total === 1 ? qsTr("%1 · 1 mensagem").arg(email)
                                                : qsTr("%1 · %2 mensagens").arg(email).arg(Mail.total)
                    }
                    color: LingmoUI.Theme.disabledTextColor
                    font.pointSize: LingmoUI.Theme.fontSize * 0.85
                    elide: Text.ElideRight
                }
            }

            Spinner {
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                running: Mail.loadingInbox && Mail.inboxLoaded
            }

            IconButton {
                visible: control.imap
                iconName: "view-filter"
                tipText: qsTr("Regras automáticas")
                onClicked: control.rulesRequested()
            }

            IconButton {
                visible: control.imap
                iconName: Mail.newestFirst ? "view-sort-descending" : "view-sort-ascending"
                tipText: Mail.newestFirst ? qsTr("Mais recentes primeiro (clique para inverter)")
                                          : qsTr("Mais antigas primeiro (clique para inverter)")
                onClicked: Mail.setNewestFirst(!Mail.newestFirst)
            }

            IconButton {
                iconName: "view-refresh"
                tipText: qsTr("Buscar mensagens novas (F5)")
                enabled: Mail.currentAccountId !== "" && !Mail.loadingInbox
                onClicked: Mail.refresh()
            }
        }

        // ---------- Server-side search
        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.smallSpacing
            visible: control.imap

            TextField {
                id: search
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                placeholderText: qsTr("Buscar no servidor…")
                selectByMouse: true
                leftPadding: LingmoUI.Units.largeSpacing
                color: LingmoUI.Theme.textColor
                placeholderTextColor: LingmoUI.Theme.disabledTextColor
                font.pointSize: LingmoUI.Theme.fontSize
                validator: RegularExpressionValidator { regularExpression: /[^\r\n]{0,200}/ }
                onAccepted: Mail.search(searchField.currentValue, text)
                onTextChanged: if (text === "" && Mail.searchQuery !== "") Mail.search(searchField.currentValue, "")
                Keys.onEscapePressed: text = ""

                // Pill-shaped, like the store's search field
                background: Rectangle {
                    radius: height / 2
                    color: LingmoUI.Theme.darkMode ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(0, 0, 0, 0.05)
                    border.width: search.activeFocus ? 2 : 0
                    border.color: LingmoUI.Theme.highlightColor
                }
            }

            ComboBox {
                id: searchField
                Layout.preferredWidth: 104
                Layout.preferredHeight: 34
                textRole: "text"
                valueRole: "value"
                model: [
                    { value: "text", text: qsTr("Tudo") },
                    { value: "from", text: qsTr("De") },
                    { value: "subject", text: qsTr("Assunto") }
                ]
                onActivated: if (search.text.trim()) Mail.search(currentValue, search.text)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Onde buscar")
                ToolTip.delay: 600
            }
        }

        // ---------- Quick filters and order
        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.smallSpacing
            visible: control.imap

            Flow {
                Layout.fillWidth: true
                spacing: LingmoUI.Units.smallSpacing
                Repeater {
                    model: [
                        { key: "all", label: qsTr("Todas") },
                        { key: "unread", label: qsTr("Não lidas") },
                        { key: "flagged", label: qsTr("Com estrela") },
                        { key: "attachment", label: qsTr("Com anexo") }
                    ]
                    delegate: AbstractButton {
                        id: chip
                        required property var modelData
                        readonly property bool active: Mail.filter === modelData.key
                        implicitHeight: 26
                        implicitWidth: chipLabel.implicitWidth + LingmoUI.Units.largeSpacing * 1.5
                        hoverEnabled: true
                        checkable: false
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.label
                        Accessible.checked: active
                        onClicked: Mail.setFilter(modelData.key)
                        background: Rectangle {
                            radius: height / 2
                            color: chip.active ? LingmoUI.Theme.highlightColor
                                 : chip.hovered ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                          LingmoUI.Theme.textColor.b, 0.1)
                                 : LingmoUI.Theme.alternateBackgroundColor
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                        contentItem: Label {
                            id: chipLabel
                            text: chip.modelData.label
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            font.pointSize: LingmoUI.Theme.fontSize * 0.9
                            color: chip.active ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                        }
                    }
                }
            }

        }

        // ---------- Bulk actions
        LingmoUI.RoundedRect {
            Layout.fillWidth: true
            implicitHeight: bulkRow.implicitHeight + LingmoUI.Units.smallSpacing * 2
            visible: control.selectedIds.length > 1 && control.imap
            radius: LingmoUI.Theme.smallRadius
            color: LingmoUI.Theme.alternateBackgroundColor

            RowLayout {
                id: bulkRow
                anchors.fill: parent
                anchors.leftMargin: LingmoUI.Units.largeSpacing
                anchors.rightMargin: LingmoUI.Units.smallSpacing
                spacing: 2

                Label {
                    Layout.fillWidth: true
                    text: qsTr("%1 selecionadas").arg(control.selectedIds.length)
                    color: LingmoUI.Theme.textColor
                    elide: Text.ElideRight
                }
                IconButton {
                    iconName: control.anyUnread(control.selectedIds) ? "mail-mark-read" : "mail-mark-unread"
                    tipText: control.anyUnread(control.selectedIds) ? qsTr("Marcar como lidas (Ctrl+U)")
                                                                    : qsTr("Marcar como não lidas (Ctrl+U)")
                    onClicked: control.toggleRead()
                }
                IconButton {
                    iconName: "rating"
                    tipText: qsTr("Estrela (S)")
                    onClicked: control.toggleStar()
                }
                IconButton {
                    iconName: "mail-archive"
                    tipText: qsTr("Arquivar (E)")
                    onClicked: control.archiveSelected()
                }
                IconButton {
                    id: bulkMove
                    iconName: "folder"
                    tipText: qsTr("Mover para…")
                    onClicked: control.moveRequested(control.selectedIds, bulkMove)
                }
                IconButton {
                    iconName: "edit-delete"
                    tipText: control.inTrash ? qsTr("Apagar definitivamente (Del)") : qsTr("Mover para a Lixeira (Del)")
                    onClicked: control.deleteSelected()
                }
                IconButton {
                    iconName: "edit-clear"
                    tipText: qsTr("Limpar seleção")
                    onClicked: control.clearSelection()
                }
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: Mail.messageModel
            currentIndex: -1
            highlightFollowsCurrentItem: false
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            LingmoUI.WheelHandler { target: list }

            delegate: Item {
                id: row
                required property string messageId
                required property string subject
                required property string senderName
                required property string when
                required property bool unread
                required property bool starred
                required property bool hasAttachment
                required property int index
                readonly property bool current: messageId === Mail.currentMessageId
                readonly property bool picked: !!control.selected[messageId]
                readonly property bool hovered: area.containsMouse

                width: ListView.view.width
                height: 64
                Accessible.role: Accessible.ListItem
                Accessible.name: (unread ? qsTr("Não lida") + ", " : "") + senderName + ", " + subject

                Rectangle {
                    anchors.fill: parent
                    radius: LingmoUI.Theme.mediumRadius
                    color: row.current ? LingmoUI.Theme.highlightColor
                         : row.picked && control.selectedIds.length > 1
                           ? Qt.rgba(LingmoUI.Theme.highlightColor.r, LingmoUI.Theme.highlightColor.g,
                                     LingmoUI.Theme.highlightColor.b, 0.25)
                         : row.hovered ? Qt.rgba(LingmoUI.Theme.textColor.r, LingmoUI.Theme.textColor.g,
                                                 LingmoUI.Theme.textColor.b, 0.1)
                         : "transparent"
                    Behavior on color { ColorAnimation { duration: 150; easing.type: Easing.OutCubic } }
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.RightButton) {
                            if (!row.picked)
                                control.rowClicked(row.index, row.messageId, 0)
                            if (control.imap)
                                rowMenu.popup()
                            return
                        }
                        control.rowClicked(row.index, row.messageId, mouse.modifiers)
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: LingmoUI.Units.smallSpacing * 1.5
                    anchors.rightMargin: LingmoUI.Units.largeSpacing
                    anchors.topMargin: LingmoUI.Units.smallSpacing
                    anchors.bottomMargin: LingmoUI.Units.smallSpacing
                    spacing: LingmoUI.Units.smallSpacing

                    // Unread dot
                    Rectangle {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 6
                        radius: 4
                        color: row.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.highlightColor
                        opacity: row.unread ? 1 : 0
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            Label {
                                Layout.fillWidth: true
                                text: row.senderName || qsTr("(Sem remetente)")
                                font.bold: row.unread
                                color: row.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                            Label {
                                text: row.when || ""
                                font.bold: row.unread
                                color: row.current ? LingmoUI.Theme.highlightedTextColor
                                     : row.unread ? LingmoUI.Theme.highlightColor : LingmoUI.Theme.disabledTextColor
                                font.pointSize: LingmoUI.Theme.fontSize * 0.85
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: LingmoUI.Units.smallSpacing
                            Label {
                                Layout.fillWidth: true
                                text: row.subject
                                font.bold: row.unread
                                color: row.current ? LingmoUI.Theme.highlightedTextColor : LingmoUI.Theme.textColor
                                opacity: row.unread ? 1 : 0.85
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                            LingmoUI.IconItem {
                                visible: row.hasAttachment
                                Layout.preferredWidth: LingmoUI.Units.iconSizes.small
                                Layout.preferredHeight: LingmoUI.Units.iconSizes.small
                                source: "mail-attachment"
                                smooth: true
                                Accessible.name: qsTr("Com anexo")
                            }
                            IconButton {
                                visible: control.imap && (row.starred || row.hovered)
                                implicitWidth: 22
                                implicitHeight: 22
                                iconName: row.starred ? "rating" : "rating-unrated"
                                tipText: row.starred ? qsTr("Remover estrela") : qsTr("Marcar com estrela")
                                onClicked: Mail.setStarred([row.messageId], !row.starred)
                            }
                        }
                    }
                }

                Menu {
                    id: rowMenu
                    MenuItem {
                        text: control.anyUnread(control.targetIds()) ? qsTr("Marcar como lida") : qsTr("Marcar como não lida")
                        onTriggered: control.toggleRead()
                    }
                    MenuItem {
                        text: control.allStarred(control.targetIds()) ? qsTr("Remover estrela") : qsTr("Marcar com estrela")
                        onTriggered: control.toggleStar()
                    }
                    MenuSeparator {}
                    MenuItem {
                        text: qsTr("Arquivar")
                        onTriggered: control.archiveSelected()
                    }
                    MenuItem {
                        text: qsTr("Mover para…")
                        onTriggered: control.moveRequested(control.targetIds(), row)
                    }
                    MenuItem {
                        text: control.inTrash ? qsTr("Apagar definitivamente…") : qsTr("Mover para a Lixeira")
                        onTriggered: control.deleteSelected()
                    }
                }
            }

            footer: Item {
                width: list.width
                height: Mail.hasMore ? loadMore.implicitHeight + LingmoUI.Units.largeSpacing * 2 : 0
                visible: Mail.hasMore
                ActionButton {
                    id: loadMore
                    anchors.centerIn: parent
                    text: Mail.loadingMore ? qsTr("Carregando…") : qsTr("Carregar mais")
                    enabled: !Mail.loadingInbox
                    onClicked: Mail.loadMore()
                }
            }

            // ---------- Empty and loading states
            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - LingmoUI.Units.largeSpacing * 2
                spacing: LingmoUI.Units.largeSpacing
                visible: list.count === 0

                Spinner {
                    Layout.alignment: Qt.AlignHCenter
                    running: Mail.loadingInbox && !Mail.inboxLoaded
                }
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: LingmoUI.Theme.disabledTextColor
                    text: {
                        if (Mail.currentAccountId === "")
                            return qsTr("Adicione uma conta para ver suas mensagens")
                        if (Mail.loadingInbox && !Mail.inboxLoaded)
                            return qsTr("Carregando mensagens…")
                        if (!Mail.inboxLoaded)
                            return qsTr("Não foi possível carregar esta pasta")
                        if (Mail.searchQuery !== "" || Mail.filter !== "all")
                            return qsTr("Nenhuma mensagem encontrada")
                        return qsTr("Nenhuma mensagem nesta pasta")
                    }
                }
                ActionButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: Mail.currentAccountId !== "" && !Mail.inboxLoaded && !Mail.loadingInbox
                    text: qsTr("Tentar novamente")
                    onClicked: Mail.refresh()
                }
            }
        }
    }
}
