import QtQuick
import Lingmo.Mail 1.0
import LingmoUI.CompatibleModule 3.0 as LingmoUI

// Sending an email in the status bar's Island (com.lingmo.Island, see
// docs/island-api.md): "Enviando…" while the message goes out, then "Enviado".
// MailBridge clears `sending` before it says sent()/sendFailed(), so the
// activity follows its own flag and ends on those signals.
LingmoUI.IslandActivity {
    id: island

    property bool sendingNow: false

    appId: "lingmo-mail"
    active: sendingNow
    kind: "mail"
    title: qsTr("Enviando e-mail")
    subtitle: qsTr("Sua mensagem está saindo")
    iconName: "mail-send"
    progress: -1
    hints: ({ indeterminate: true })

    readonly property Connections _mail: Connections {
        target: Mail
        // `sending` has no signal of its own: busyChanged covers every job
        function onBusyChanged() {
            if (Mail.sending) {
                _settle.stop()
                island.finishMessage = ""
                island.sendingNow = true
            } else if (island.sendingNow && !_settle.running) {
                // Neither sent() nor sendFailed() came (cancelled): just go away
                _settle.restart()
            }
        }
        function onSent() {
            _settle.stop()
            island.finishMessage = qsTr("Enviado")
            island.sendingNow = false
        }
        function onSendFailed(error) {
            _settle.stop()
            island.finishMessage = qsTr("Falha no envio")
            island.sendingNow = false
        }
    }

    readonly property Timer _settle: Timer {
        id: _settle
        interval: 1500
        onTriggered: island.sendingNow = false
    }
}
