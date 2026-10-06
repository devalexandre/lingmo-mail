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

#pragma once

#include <QHash>
#include <QObject>
#include <QVariant>

class QProcess;
class QTimer;

// Talks to backend.py: one python3 process per request, JSON line in, JSON line out.
// Nothing here blocks the UI and nothing sensitive (passwords, bodies) is logged.
class MailBridge : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY accountsChanged)
    Q_PROPERTY(bool accountsLoaded READ accountsLoaded NOTIFY accountsChanged)
    Q_PROPERTY(QString currentAccountId READ currentAccountId WRITE setCurrentAccountId NOTIFY currentAccountChanged)
    Q_PROPERTY(QVariantMap currentAccount READ currentAccount NOTIFY currentAccountChanged)
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(bool inboxLoaded READ inboxLoaded NOTIFY messagesChanged)
    Q_PROPERTY(QString currentMessageId READ currentMessageId NOTIFY messageChanged)
    Q_PROPERTY(QVariantMap message READ message NOTIFY messageChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool loadingInbox READ loadingInbox NOTIFY busyChanged)
    Q_PROPERTY(bool loadingMessage READ loadingMessage NOTIFY busyChanged)
    Q_PROPERTY(bool sending READ sending NOTIFY busyChanged)
    Q_PROPERTY(bool setupBusy READ setupBusy NOTIFY busyChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // "Entrar com Google" only works with an OAuth client ID configured
    Q_PROPERTY(bool googleAvailable READ googleAvailable CONSTANT)

public:
    explicit MailBridge(QObject *parent = nullptr);
    ~MailBridge() override;

    QVariantList accounts() const { return m_accounts; }
    bool accountsLoaded() const { return m_accountsLoaded; }
    QString currentAccountId() const { return m_currentAccountId; }
    void setCurrentAccountId(const QString &id);
    QVariantMap currentAccount() const;
    QVariantList messages() const { return m_messages; }
    bool inboxLoaded() const { return m_inboxLoaded; }
    QString currentMessageId() const { return m_currentMessageId; }
    QVariantMap message() const { return m_message; }
    bool busy() const { return !m_running.isEmpty(); }
    bool loadingInbox() const { return m_running.contains(QStringLiteral("inbox")); }
    bool loadingMessage() const { return m_running.contains(QStringLiteral("read")); }
    bool sending() const { return m_running.contains(QStringLiteral("send")); }
    bool setupBusy() const;
    QString error() const { return m_error; }
    QString status() const { return m_status; }

    bool googleAvailable() const;

    Q_INVOKABLE void reloadAccounts();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void openMessage(const QString &messageId);
    Q_INVOKABLE void closeMessage();
    Q_INVOKABLE void discover(const QString &email);
    Q_INVOKABLE void saveAccount(const QVariantMap &account, const QString &password);
    Q_INVOKABLE void signInWithGoogle();
    Q_INVOKABLE void cancelSetup();
    Q_INVOKABLE void removeAccount(const QString &id);
    Q_INVOKABLE void send(const QVariantMap &draft);
    Q_INVOKABLE void clearError();

    // Prefilled drafts for the composer, from the open message
    Q_INVOKABLE QVariantMap replyDraft() const;
    Q_INVOKABLE QVariantMap forwardDraft() const;
    // Display helpers
    Q_INVOKABLE static QString displayName(const QString &address);
    Q_INVOKABLE static QString addressOf(const QString &address);

    static QString shortDate(const QString &rfc2822);
    static QString longDate(const QString &rfc2822);

Q_SIGNALS:
    void accountsChanged();
    void currentAccountChanged();
    void messagesChanged();
    void messageChanged();
    void busyChanged();
    void errorChanged();
    void statusChanged();

    void discovered(const QVariantMap &account);
    void discoverFailed(const QString &error);
    void accountSaved(const QVariantMap &account);
    void setupFailed(const QString &error);
    void sent();
    void sendFailed(const QString &error);

private:
    using Handler = void (MailBridge::*)(bool ok, const QVariant &data, const QString &error);

    void request(const QString &kind, const QVariantMap &payload, int timeoutMs, Handler handler);
    void cancel(const QString &kind);
    void finish(QProcess *process, bool ok, const QVariant &data, const QString &error);
    void handleLine(QProcess *process, const QByteArray &line);
    void setError(const QString &error);
    void setStatus(const QString &status);
    void setMessages(const QVariantList &messages, bool loaded);
    void setMessage(const QString &id, const QVariantMap &message);
    void setAccounts(const QVariantList &accounts);
    QString backendPath() const;

    void onAccounts(bool ok, const QVariant &data, const QString &error);
    void onInbox(bool ok, const QVariant &data, const QString &error);
    void onRead(bool ok, const QVariant &data, const QString &error);
    void onDiscover(bool ok, const QVariant &data, const QString &error);
    void onSave(bool ok, const QVariant &data, const QString &error);
    void onRemove(bool ok, const QVariant &data, const QString &error);
    void onSend(bool ok, const QVariant &data, const QString &error);

    struct Job {
        QString kind;
        Handler handler = nullptr;
        QTimer *timer = nullptr;
        QByteArray buffer;
        QVariantMap reply;
        bool done = false;
    };

    QHash<QString, QProcess *> m_running;   // kind -> process (one of each kind at a time)
    QHash<QProcess *, Job> m_jobs;

    QVariantList m_accounts;
    bool m_accountsLoaded = false;
    QString m_currentAccountId;
    QVariantList m_messages;
    bool m_inboxLoaded = false;
    QString m_currentMessageId;
    QVariantMap m_message;
    QString m_error;
    QString m_status;
    QString m_selectAfterReload;
};
