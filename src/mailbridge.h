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

#include <QAbstractListModel>
#include <QHash>
#include <QObject>
#include <QVariant>

class QProcess;
class QTimer;

// The open folder's messages. Updated in place (rows changed, inserted or removed)
// so the list keeps its scroll position across refreshes and actions.
class MessageModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        SubjectRole,
        SenderRole,
        SenderNameRole,
        ToRole,
        WhenRole,
        FullDateRole,
        UnreadRole,
        StarredRole,
        AttachmentRole,
        AnsweredRole,
    };

    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    int count() const { return int(m_items.size()); }

    void setItems(const QVariantList &items);
    void update(const QString &id, const QVariantMap &changes);
    void remove(const QStringList &ids);
    int indexOf(const QString &id) const;
    QVariantMap at(int row) const { return row >= 0 && row < m_items.size() ? m_items.at(row) : QVariantMap(); }
    QVariantList items() const;

Q_SIGNALS:
    void countChanged();

private:
    QList<QVariantMap> m_items;
};

// Talks to backend.py: one python3 process per request, JSON line in, JSON line out.
// Nothing here blocks the UI and nothing sensitive (passwords, bodies) is logged.
class MailBridge : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY accountsChanged)
    Q_PROPERTY(bool accountsLoaded READ accountsLoaded NOTIFY accountsChanged)
    Q_PROPERTY(QString currentAccountId READ currentAccountId WRITE setCurrentAccountId NOTIFY currentAccountChanged)
    Q_PROPERTY(QVariantMap currentAccount READ currentAccount NOTIFY currentAccountChanged)
    Q_PROPERTY(bool currentIsImap READ currentIsImap NOTIFY currentAccountChanged)
    // Folders of every account seen so far: accountId -> [{path, name, role, depth, unread}]
    Q_PROPERTY(QVariantMap folderCache READ folderCache NOTIFY foldersChanged)
    Q_PROPERTY(QVariantList folders READ folders NOTIFY foldersChanged)
    Q_PROPERTY(QString currentFolder READ currentFolder NOTIFY folderChanged)
    Q_PROPERTY(QVariantMap currentFolderInfo READ currentFolderInfo NOTIFY foldersChanged)
    Q_PROPERTY(QString currentFolderRole READ currentFolderRole NOTIFY foldersChanged)
    Q_PROPERTY(QObject *messageModel READ messageModel CONSTANT)
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(bool inboxLoaded READ inboxLoaded NOTIFY messagesChanged)
    Q_PROPERTY(int total READ total NOTIFY messagesChanged)
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY messagesChanged)
    Q_PROPERTY(QString filter READ filter NOTIFY queryChanged)
    Q_PROPERTY(bool newestFirst READ newestFirst NOTIFY queryChanged)
    Q_PROPERTY(QString searchField READ searchField NOTIFY queryChanged)
    Q_PROPERTY(QString searchQuery READ searchQuery NOTIFY queryChanged)
    Q_PROPERTY(QString currentMessageId READ currentMessageId NOTIFY messageChanged)
    Q_PROPERTY(QVariantMap message READ message NOTIFY messageChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool loadingInbox READ loadingInbox NOTIFY busyChanged)
    Q_PROPERTY(bool loadingMore READ loadingMore NOTIFY busyChanged)
    Q_PROPERTY(bool loadingMessage READ loadingMessage NOTIFY busyChanged)
    Q_PROPERTY(bool sending READ sending NOTIFY busyChanged)
    Q_PROPERTY(bool setupBusy READ setupBusy NOTIFY busyChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // "Entrar com Google" only works with an OAuth client ID configured
    Q_PROPERTY(bool googleAvailable READ googleAvailable CONSTANT)
    // Address book (local)
    Q_PROPERTY(QVariantList contacts READ contacts NOTIFY contactsChanged)
    Q_PROPERTY(bool contactsLoaded READ contactsLoaded NOTIFY contactsChanged)
    // Rules of the current account
    Q_PROPERTY(QVariantList rules READ rules NOTIFY rulesChanged)
    Q_PROPERTY(bool rulesLoaded READ rulesLoaded NOTIFY rulesChanged)
    Q_PROPERTY(bool applyingRules READ applyingRules NOTIFY busyChanged)
    // Minutes between automatic refreshes (0 = off)
    Q_PROPERTY(int refreshMinutes READ refreshMinutes CONSTANT)

public:
    explicit MailBridge(QObject *parent = nullptr);
    ~MailBridge() override;

    QVariantList accounts() const { return m_accounts; }
    bool accountsLoaded() const { return m_accountsLoaded; }
    QString currentAccountId() const { return m_currentAccountId; }
    void setCurrentAccountId(const QString &id);
    QVariantMap currentAccount() const;
    bool currentIsImap() const;
    QVariantMap folderCache() const { return m_folderCache; }
    QVariantList folders() const { return m_folderCache.value(m_currentAccountId).toList(); }
    QString currentFolder() const { return m_currentFolder; }
    QVariantMap currentFolderInfo() const;
    QString currentFolderRole() const { return currentFolderInfo().value(QStringLiteral("role")).toString(); }
    QObject *messageModel() const { return m_model; }
    QVariantList messages() const { return m_model->items(); }
    bool inboxLoaded() const { return m_inboxLoaded; }
    int total() const { return m_total; }
    bool hasMore() const { return m_hasMore; }
    QString filter() const { return m_filter; }
    bool newestFirst() const { return m_newestFirst; }
    QString searchField() const { return m_searchField; }
    QString searchQuery() const { return m_searchQuery; }
    QString currentMessageId() const { return m_currentMessageId; }
    QVariantMap message() const { return m_message; }
    bool busy() const { return !m_running.isEmpty(); }
    bool loadingInbox() const { return m_running.contains(QStringLiteral("inbox")); }
    bool loadingMore() const { return loadingInbox() && m_loadingMore; }
    bool loadingMessage() const { return m_running.contains(QStringLiteral("read")); }
    bool sending() const { return m_running.contains(QStringLiteral("send")); }
    bool applyingRules() const { return m_running.contains(QStringLiteral("applyRules")); }
    bool setupBusy() const;
    QString error() const { return m_error; }
    QString status() const { return m_status; }
    QVariantList contacts() const { return m_contacts; }
    bool contactsLoaded() const { return m_contactsLoaded; }
    QVariantList rules() const { return m_rules; }
    bool rulesLoaded() const { return m_rulesLoaded; }
    int refreshMinutes() const;

    bool googleAvailable() const;

    Q_INVOKABLE void reloadAccounts();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void openFolder(const QString &accountId, const QString &path);
    Q_INVOKABLE void loadMore();
    Q_INVOKABLE void setFilter(const QString &filter);
    Q_INVOKABLE void setNewestFirst(bool newestFirst);
    Q_INVOKABLE void search(const QString &field, const QString &query);
    Q_INVOKABLE void openMessage(const QString &messageId);
    Q_INVOKABLE void closeMessage();
    Q_INVOKABLE void discover(const QString &email);
    Q_INVOKABLE void saveAccount(const QVariantMap &account, const QString &password);
    Q_INVOKABLE void signInWithGoogle();
    Q_INVOKABLE void cancelSetup();
    Q_INVOKABLE void removeAccount(const QString &id);
    Q_INVOKABLE void send(const QVariantMap &draft);
    Q_INVOKABLE void clearError();

    // Actions on messages of the open folder (IMAP)
    Q_INVOKABLE void markRead(const QStringList &ids, bool read);
    Q_INVOKABLE void setStarred(const QStringList &ids, bool starred);
    Q_INVOKABLE void archive(const QStringList &ids);
    Q_INVOKABLE void moveMessages(const QStringList &ids, const QString &target);
    // Moves to the Trash; inside the Trash (or without one) asks via deleteNeedsConfirm first
    Q_INVOKABLE void deleteMessages(const QStringList &ids, bool permanent = false);
    Q_INVOKABLE QStringList idsBetween(int from, int to) const;
    Q_INVOKABLE QVariantMap messageAt(int row) const { return m_model->at(row); }
    Q_INVOKABLE int rowOf(const QString &id) const { return m_model->indexOf(id); }
    Q_INVOKABLE QString folderTitle(const QVariantMap &folder) const;
    Q_INVOKABLE QString folderIcon(const QString &role) const;
    Q_INVOKABLE QVariantList moveTargets() const;

    // Contacts
    Q_INVOKABLE void reloadContacts();
    Q_INVOKABLE void saveContact(const QVariantMap &contact);
    Q_INVOKABLE void deleteContact(const QString &id);
    Q_INVOKABLE QVariantList contactSuggestions(const QString &text, int limit = 8) const;

    // Rules
    Q_INVOKABLE void reloadRules();
    Q_INVOKABLE void saveRules(const QVariantList &rules);
    Q_INVOKABLE void applyRulesNow();

    // For the calendar side: answers an invitation (text + text/calendar; method=REPLY)
    Q_INVOKABLE void sendCalendarReply(const QString &accountId, const QString &to, const QString &subject,
                                       const QString &icsText);

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
    void foldersChanged();
    void folderChanged();
    void messagesChanged();
    void queryChanged();
    void messageChanged();
    void busyChanged();
    void errorChanged();
    void statusChanged();
    void contactsChanged();
    void rulesChanged();

    void discovered(const QVariantMap &account);
    void discoverFailed(const QString &error);
    void accountSaved(const QVariantMap &account);
    void setupFailed(const QString &error);
    void sent();
    void sendFailed(const QString &error);
    void deleteNeedsConfirm(const QStringList &ids);
    void contactSaved();
    void contactFailed(const QString &error);
    void rulesSaved();
    void rulesFailed(const QString &error);
    void calendarReplySent();
    void calendarReplyFailed(const QString &error);

private:
    using Handler = void (MailBridge::*)(bool ok, const QVariant &data, const QString &error);

    void request(const QString &kind, const QVariantMap &payload, int timeoutMs, Handler handler,
                 const QVariantMap &context = {});
    void cancel(const QString &kind);
    void finish(QProcess *process, bool ok, const QVariant &data, const QString &error);
    void handleLine(QProcess *process, const QByteArray &line);
    void setError(const QString &error);
    void setStatus(const QString &status);
    void setMessage(const QString &id, const QVariantMap &message);
    void setAccounts(const QVariantList &accounts);
    void selectAccount(const QString &id, const QString &folder);
    void resetFolderState();
    void list(bool silent);
    void act(const QString &action, const QStringList &ids, const QVariantMap &extra = {});
    void checkOtherAccounts();
    void setFolders(const QString &accountId, const QVariantList &folders);
    void adjustUnread(const QString &path, int delta);
    void notifyNewMail(const QString &accountId, const QVariantMap &newMail);
    QVariantMap decorate(QVariantMap message) const;
    QVariantMap accountById(const QString &id) const;
    QVariantMap folderByRole(const QString &role) const;
    QString backendPath() const;

    void onAccounts(bool ok, const QVariant &data, const QString &error);
    void onInbox(bool ok, const QVariant &data, const QString &error);
    void onCheck(bool ok, const QVariant &data, const QString &error);
    void onRead(bool ok, const QVariant &data, const QString &error);
    void onAct(bool ok, const QVariant &data, const QString &error);
    void onDiscover(bool ok, const QVariant &data, const QString &error);
    void onSave(bool ok, const QVariant &data, const QString &error);
    void onRemove(bool ok, const QVariant &data, const QString &error);
    void onSend(bool ok, const QVariant &data, const QString &error);
    void onContacts(bool ok, const QVariant &data, const QString &error);
    void onContactSaved(bool ok, const QVariant &data, const QString &error);
    void onRules(bool ok, const QVariant &data, const QString &error);
    void onRulesSaved(bool ok, const QVariant &data, const QString &error);
    void onApplyRules(bool ok, const QVariant &data, const QString &error);
    void onCalendarReply(bool ok, const QVariant &data, const QString &error);

    struct Job {
        QString kind;
        Handler handler = nullptr;
        QTimer *timer = nullptr;
        QByteArray buffer;
        QVariantMap reply;
        QVariantMap context;
        bool done = false;
    };

    QHash<QString, QProcess *> m_running;   // kind -> process (one of each kind at a time)
    QHash<QProcess *, Job> m_jobs;
    QVariantMap m_context;                  // context of the job whose handler is running
    quint64 m_serial = 0;

    QVariantList m_accounts;
    bool m_accountsLoaded = false;
    bool m_checkedOthers = false;
    QString m_currentAccountId;
    QString m_currentFolder = QStringLiteral("INBOX");
    QVariantMap m_folderCache;
    MessageModel *m_model = nullptr;
    bool m_inboxLoaded = false;
    int m_total = 0;
    bool m_hasMore = false;
    int m_limit = 50;
    bool m_loadingMore = false;
    QString m_filter = QStringLiteral("all");
    bool m_newestFirst = true;
    QString m_searchField = QStringLiteral("text");
    QString m_searchQuery;
    QString m_currentMessageId;
    QVariantMap m_message;
    QString m_error;
    QString m_status;
    QString m_selectAfterReload;
    QVariantList m_contacts;
    bool m_contactsLoaded = false;
    QVariantList m_rules;
    bool m_rulesLoaded = false;
    QTimer *m_refreshTimer = nullptr;
};
