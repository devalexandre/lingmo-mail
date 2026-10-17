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

// A calendar invitation inside a message: details, conflicts and the answer
LingmoUI.RoundedRect {
    id: card

    property string icsText: ""
    property string accountId: ""
    property string organizerReplyTo: ""

    property var info: null
    property string errorText: ""
    property string doneText: ""
    property bool working: false
    property string pending: ""          // partstat being sent
    readonly property string requestId: "c" + Math.floor(Math.random() * 1e9)

    readonly property var account: {
        if (typeof Mail === "undefined" || !Mail.accounts)
            return null
        for (let i = 0; i < Mail.accounts.length; ++i)
            if (Mail.accounts[i].id === accountId)
                return Mail.accounts[i]
        return null
    }
    readonly property string myEmail: account ? account.email || "" : ""
    readonly property string myName: account ? account.name || "" : ""
    readonly property string method: info ? info.method : ""
    readonly property string answer: info ? (info.existing && info.existing.partstat) || info.myStatus || "" : ""

    implicitHeight: content.implicitHeight + LingmoUI.Units.largeSpacing * 2
    radius: LingmoUI.Theme.mediumRadius
    color: LingmoUI.Theme.alternateBackgroundColor

    function load() {
        if (!icsText)
            return
        errorText = ""
        Calendar.parseInvite(requestId, icsText, myEmail)
    }

    function when() {
        if (!info)
            return ""
        const locale = Qt.locale()
        const s = Util.parse(info.start)
        let e = Util.parse(info.end)
        if (info.allDay) {
            e = Util.addDays(e, -1)
            const first = locale.toString(s, "ddd, d 'de' MMM 'de' yyyy")
            return Util.sameDay(s, e) ? qsTr("%1 (dia inteiro)").arg(first)
                                      : qsTr("%1 a %2").arg(first).arg(locale.toString(e, "ddd, d 'de' MMM"))
        }
        if (Util.sameDay(s, e))
            return locale.toString(s, "ddd, d 'de' MMM 'de' yyyy, HH:mm") + " – " + Util.hhmm(e)
        return locale.toString(s, "ddd, d MMM HH:mm") + " – " + locale.toString(e, "ddd, d MMM HH:mm")
    }

    function respond(partstat) {
        if (!myEmail) {
            errorText = qsTr("Não foi possível identificar a sua conta para responder.")
            return
        }
        working = true
        pending = partstat
        errorText = ""
        Calendar.respondInvite(requestId, icsText, partstat, myEmail, myName)
    }

    Component.onCompleted: load()
    onIcsTextChanged: load()

    // Another card or the calendar changed the event: show the current state
    Timer {
        id: reloadLater
        interval: 300
        onTriggered: if (!card.working) card.load()
    }

    Connections {
        target: Calendar
        function onUpcomingChanged() { reloadLater.restart() }
        function onInviteParsed(id, data) {
            if (id === card.requestId) {
                card.info = data
                card.working = false
            }
        }
        function onInviteFailed(id, error) {
            if (id === card.requestId) {
                card.working = false
                card.errorText = error
            }
        }
        function onInviteCancelled(id, removed) {
            if (id !== card.requestId)
                return
            card.working = false
            card.doneText = removed ? qsTr("Evento removido do calendário.") : qsTr("O evento não estava no calendário.")
            card.load()
        }
        function onInviteResponded(id, result) {
            if (id !== card.requestId)
                return
            card.working = false
            if (result.replyIcs) {
                // The organizer from the invitation; the message's Reply-To/sender otherwise
                const to = result.organizer || card.organizerReplyTo
                if (typeof Mail !== "undefined" && typeof Mail.sendCalendarReply === "function" && to) {
                    Mail.sendCalendarReply(card.accountId, to, result.subject, result.replyIcs)
                    card.doneText = card.pending === "DECLINED" ? qsTr("Resposta enviada. O evento não foi adicionado.")
                                                               : qsTr("Resposta enviada e evento salvo no calendário.")
                } else {
                    card.doneText = qsTr("Evento salvo no calendário, mas não foi possível enviar a resposta ao organizador.")
                }
            } else if (result.updated !== undefined) {
                card.doneText = result.updated ? qsTr("Resposta registrada no evento.") : qsTr("Nada para atualizar.")
            } else {
                card.doneText = qsTr("Adicionado ao calendário.")
            }
            card.pending = ""
            card.load()
        }
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: LingmoUI.Units.largeSpacing
        spacing: LingmoUI.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: LingmoUI.Units.largeSpacing

            LingmoUI.IconItem {
                Layout.preferredWidth: LingmoUI.Units.iconSizes.medium
                Layout.preferredHeight: LingmoUI.Units.iconSizes.medium
                Layout.alignment: Qt.AlignTop
                source: "x-office-calendar"
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    Layout.fillWidth: true
                    text: !card.info ? qsTr("Convite de calendário")
                          : card.method === "CANCEL" ? qsTr("Cancelado: %1").arg(card.info.title)
                          : card.info.title
                    font.bold: true
                    font.pointSize: LingmoUI.Units.fontBody
                    font.strikeout: card.method === "CANCEL"
                    color: LingmoUI.Theme.textColor
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontBody
                    Layout.fillWidth: true
                    visible: !!card.info
                    text: card.when() + (card.info && card.info.recurring && card.info.ruleText ? " · " + card.info.ruleText : "")
                    color: LingmoUI.Theme.textColor
                    wrapMode: Text.Wrap
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    visible: !!(card.info && card.info.location)
                    text: card.info ? qsTr("Local: %1").arg(card.info.location) : ""
                    color: LingmoUI.Theme.secondaryTextColor
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    visible: !!(card.info && card.info.organizer)
                    text: card.info && card.info.organizer
                          ? qsTr("Organizador: %1").arg(card.info.organizer.name
                                                         ? card.info.organizer.name + " <" + card.info.organizer.email + ">"
                                                         : card.info.organizer.email)
                          : ""
                    color: LingmoUI.Theme.secondaryTextColor
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                Label {
                    font.pointSize: LingmoUI.Units.fontCaption
                    Layout.fillWidth: true
                    visible: !!(card.info && card.info.attendees && card.info.attendees.length)
                    text: card.info && card.info.attendees ? qsTr("%n convidado(s)", "", card.info.attendees.length) : ""
                    color: LingmoUI.Theme.secondaryTextColor
                }
            }

            LingmoUI.Spinner {
                size: 20
                Layout.alignment: Qt.AlignTop
                running: card.working || (!card.info && !card.errorText)
            }
        }

        // Conflicts with what's already on the calendar
        Rectangle {
            Layout.fillWidth: true
            visible: !!(card.info && card.info.conflicts && card.info.conflicts.length && card.method !== "CANCEL")
            implicitHeight: conflictText.implicitHeight + LingmoUI.Units.smallSpacing * 2
            radius: LingmoUI.Theme.smallRadius
            color: Qt.rgba(LingmoUI.Theme.orangeColor.r, LingmoUI.Theme.orangeColor.g, LingmoUI.Theme.orangeColor.b,
                           LingmoUI.Theme.darkMode ? 0.22 : 0.12)
            Label {
                id: conflictText
                font.pointSize: LingmoUI.Units.fontBody
                anchors.fill: parent
                anchors.margins: LingmoUI.Units.smallSpacing
                anchors.leftMargin: LingmoUI.Units.largeSpacing
                wrapMode: Text.Wrap
                color: LingmoUI.Theme.textColor
                textFormat: Text.PlainText
                text: {
                    if (!card.info || !card.info.conflicts)
                        return ""
                    const names = card.info.conflicts.map(c => c.title + " (" + Util.hhmm(Util.parse(c.start)) + ")")
                    return qsTr("Conflita com: %1").arg(names.join(", "))
                }
            }
        }

        Label {
            font.pointSize: LingmoUI.Units.fontCaption
            Layout.fillWidth: true
            visible: text.length > 0
            wrapMode: Text.Wrap
            color: LingmoUI.Theme.secondaryTextColor
            text: {
                if (!card.info)
                    return ""
                if (card.info.outdated)
                    return qsTr("Há uma versão mais nova deste convite no seu calendário.")
                if (card.method === "CANCEL")
                    return card.info.existing ? qsTr("O organizador cancelou este evento.")
                                              : qsTr("O organizador cancelou este evento. Ele não está no seu calendário.")
                if (card.method === "REPLY") {
                    const a = (card.info.attendees || [])[0]
                    if (!a)
                        return ""
                    const word = a.partstat === "ACCEPTED" ? qsTr("aceitou") : a.partstat === "DECLINED" ? qsTr("recusou")
                               : a.partstat === "TENTATIVE" ? qsTr("respondeu talvez") : qsTr("respondeu")
                    return qsTr("%1 %2 o convite.").arg(a.name || a.email).arg(word)
                }
                if (card.info.updated)
                    return qsTr("O organizador atualizou este convite.")
                if (card.answer === "ACCEPTED")
                    return qsTr("Você aceitou.")
                if (card.answer === "TENTATIVE")
                    return qsTr("Você respondeu talvez.")
                if (card.answer === "DECLINED")
                    return qsTr("Você recusou.")
                if (card.info.existing)
                    return qsTr("Já está no calendário %1.").arg(card.info.existing.calendarName)
                return ""
            }
        }

        LingmoUI.Banner {
            type: LingmoUI.Banner.Error
            Layout.fillWidth: true
            text: card.errorText
            onClosed: card.errorText = ""
        }
        LingmoUI.Banner {
            Layout.fillWidth: true
            type: LingmoUI.Banner.Success
            text: card.doneText
            onClosed: card.doneText = ""
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: LingmoUI.Units.smallSpacing
            spacing: LingmoUI.Units.smallSpacing
            visible: !!card.info && !card.info.outdated

            // REQUEST: answer
            LingmoUI.ActionButton {
                visible: card.method === "REQUEST"
                enabled: !card.working
                primary: card.answer !== "ACCEPTED"
                text: card.answer === "ACCEPTED" ? qsTr("Aceito") : qsTr("Aceitar")
                onClicked: card.respond("ACCEPTED")
            }
            LingmoUI.ActionButton {
                visible: card.method === "REQUEST"
                enabled: !card.working
                text: qsTr("Talvez")
                onClicked: card.respond("TENTATIVE")
            }
            LingmoUI.ActionButton {
                visible: card.method === "REQUEST"
                enabled: !card.working
                text: qsTr("Recusar")
                onClicked: card.respond("DECLINED")
            }

            // PUBLISH: just add
            LingmoUI.ActionButton {
                visible: card.method === "PUBLISH" || card.method === "ADD"
                enabled: !card.working
                primary: true
                text: card.info && card.info.existing ? qsTr("Atualizar no calendário") : qsTr("Adicionar ao calendário")
                onClicked: {
                    card.working = true
                    Calendar.addInvite(card.requestId, card.icsText)
                }
            }

            // CANCEL: offer to remove
            LingmoUI.ActionButton {
                visible: card.method === "CANCEL" && !!(card.info && card.info.existing)
                enabled: !card.working
                destructive: true
                text: qsTr("Remover do calendário")
                onClicked: {
                    card.working = true
                    Calendar.cancelInvite(card.requestId, card.icsText)
                }
            }

            // REPLY (we organized it): record the answer
            LingmoUI.ActionButton {
                visible: card.method === "REPLY" && !!(card.info && card.info.existing)
                enabled: !card.working
                text: qsTr("Atualizar no calendário")
                onClicked: {
                    card.working = true
                    Calendar.applyInviteReply(card.requestId, card.icsText)
                }
            }
            Item { Layout.fillWidth: true }
        }
    }
}
