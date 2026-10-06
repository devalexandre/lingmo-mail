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
#include <QUrl>
#include <QVariant>
#include <functional>

class QFileSystemWatcher;
class QProcess;
class QTimer;
class ReminderService;

// Calendar and tasks for QML (singleton `Calendar` in Lingmo.Mail). Talks to
// calendar_backend.py: one python3 process per request, JSON line in, JSON
// line out. Nothing here blocks the UI and nothing sensitive is logged.
class CalendarBridge : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool loaded READ loaded NOTIFY calendarsChanged)
    Q_PROPERTY(QVariantList calendars READ calendars NOTIFY calendarsChanged)
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY calendarsChanged)
    Q_PROPERTY(QString defaultCalendarId READ defaultCalendarId NOTIFY calendarsChanged)
    Q_PROPERTY(QString defaultTaskListId READ defaultTaskListId NOTIFY calendarsChanged)
    Q_PROPERTY(QVariantList events READ events NOTIFY eventsChanged)
    Q_PROPERTY(QString rangeStart READ rangeStart NOTIFY eventsChanged)
    Q_PROPERTY(QString rangeEnd READ rangeEnd NOTIFY eventsChanged)
    Q_PROPERTY(QVariantList upcoming READ upcoming NOTIFY upcomingChanged)
    Q_PROPERTY(QVariantList tasks READ tasks NOTIFY tasksChanged)
    Q_PROPERTY(bool tasksLoaded READ tasksLoaded NOTIFY tasksChanged)
    Q_PROPERTY(QVariantList mailAccounts READ mailAccounts NOTIFY mailAccountsChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool syncing READ syncing NOTIFY busyChanged)
    Q_PROPERTY(bool setupBusy READ setupBusy NOTIFY busyChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString lastSync READ lastSync NOTIFY lastSyncChanged)

public:
    enum Mode { Interactive, Headless };

    explicit CalendarBridge(QObject *parent = nullptr, Mode mode = Interactive);
    ~CalendarBridge() override;

    using Callback = std::function<void(bool ok, const QVariant &data, const QString &error)>;
    // One worker request; a new request of the same `kind` cancels the previous one
    void call(const QString &kind, const QVariantMap &payload, int timeoutMs, Callback callback);
    QString calendarsPath() const;

    bool loaded() const { return m_loaded; }
    QVariantList calendars() const { return m_calendars; }
    QVariantList accounts() const { return m_accounts; }
    QString defaultCalendarId() const { return m_defaultCalendar; }
    QString defaultTaskListId() const { return m_defaultTaskList; }
    QVariantList events() const { return m_events; }
    QString rangeStart() const { return m_rangeStart; }
    QString rangeEnd() const { return m_rangeEnd; }
    QVariantList upcoming() const { return m_upcoming; }
    QVariantList tasks() const { return m_tasks; }
    bool tasksLoaded() const { return m_tasksLoaded; }
    QVariantList mailAccounts() const { return m_mailAccounts; }
    bool busy() const;
    bool syncing() const { return m_running.contains(QStringLiteral("sync")); }
    bool setupBusy() const;
    QString error() const { return m_error; }
    QString status() const { return m_status; }
    QString lastSync() const { return m_lastSync; }

    // Data
    Q_INVOKABLE void reload();
    Q_INVOKABLE void loadRange(const QString &startDay, const QString &endDay);
    Q_INVOKABLE QVariantMap calendar(const QString &id) const;

    // Events
    Q_INVOKABLE void saveEvent(const QVariantMap &event);
    Q_INVOKABLE void deleteEvent(const QVariantMap &event, const QString &scope);
    Q_INVOKABLE void importIcsFile(const QUrl &file, const QString &calendarId);

    // Calendars
    Q_INVOKABLE void saveCalendar(const QVariantMap &calendar);
    Q_INVOKABLE void setCalendarHidden(const QString &id, bool hidden);
    Q_INVOKABLE void deleteCalendar(const QString &id);
    Q_INVOKABLE void setDefaultCalendar(const QString &id, bool tasks = false);

    // Tasks
    Q_INVOKABLE void saveTask(const QVariantMap &task);
    Q_INVOKABLE void completeTask(const QString &calendarId, const QString &file, bool done);
    Q_INVOKABLE void deleteTask(const QString &calendarId, const QString &file);
    // From the mail reader: a task in the default list. dueIso: "", "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"
    Q_INVOKABLE void createTask(const QString &title, const QString &notes, const QString &dueIso);

    // Invitations (results arrive by requestId)
    Q_INVOKABLE void parseInvite(const QString &requestId, const QString &icsText, const QString &email);
    Q_INVOKABLE void respondInvite(const QString &requestId, const QString &icsText, const QString &partstat,
                                   const QString &email, const QString &name);
    Q_INVOKABLE void cancelInvite(const QString &requestId, const QString &icsText);
    Q_INVOKABLE void applyInviteReply(const QString &requestId, const QString &icsText);
    // METHOD:PUBLISH (or no reply wanted): just add it to the default calendar
    Q_INVOKABLE void addInvite(const QString &requestId, const QString &icsText);

    // CalDAV
    Q_INVOKABLE void loadMailAccounts();
    Q_INVOKABLE void discoverCalDav(const QVariantMap &account, const QString &password);
    Q_INVOKABLE void addCalDavAccount(const QVariantMap &account, const QString &password);
    Q_INVOKABLE void cancelSetup();
    Q_INVOKABLE void removeCalDavAccount(const QString &id);
    Q_INVOKABLE void sync();

    Q_INVOKABLE void clearError();

Q_SIGNALS:
    void calendarsChanged();
    void eventsChanged();
    void upcomingChanged();
    void tasksChanged();
    void mailAccountsChanged();
    void busyChanged();
    void errorChanged();
    void statusChanged();
    void lastSyncChanged();

    void eventSaved(const QVariantMap &result);
    void eventSaveFailed(const QString &error);
    void taskCreated(const QString &title);
    void imported(int count);

    void inviteParsed(const QString &requestId, const QVariantMap &info);
    void inviteResponded(const QString &requestId, const QVariantMap &result);
    void inviteCancelled(const QString &requestId, bool removed);
    void inviteFailed(const QString &requestId, const QString &error);

    void calDavDiscovered(const QVariantList &calendars);
    void calDavAdded(const QVariantMap &account);
    void setupFailed(const QString &error);

private:
    struct Job {
        QString kind;
        Callback callback;
        QTimer *timer = nullptr;
        QByteArray buffer;
        QVariantMap reply;
    };

    void finish(QProcess *process, bool ok, const QVariant &data, const QString &error);
    void cancel(const QString &kind);
    QString backendPath() const;
    void setError(const QString &error);
    void setStatus(const QString &status);
    void scheduleReload();
    void reloadData();
    void loadCalendars();
    void loadUpcoming();
    void loadTasks();
    void watchFolders();
    void write(const QString &op, const QVariantMap &payload, const QString &done, const QString &calendarId);
    bool isCalDav(const QString &calendarId) const;
    QVariantMap account(const QVariantMap &input) const;

    Mode m_mode;
    QHash<QString, QProcess *> m_running;
    QHash<QProcess *, Job> m_jobs;
    int m_serial = 0;

    bool m_loaded = false;
    QVariantList m_calendars;
    QVariantList m_accounts;
    QString m_defaultCalendar;
    QString m_defaultTaskList;
    QVariantList m_events;
    QString m_rangeStart;
    QString m_rangeEnd;
    QVariantList m_upcoming;
    QVariantList m_tasks;
    bool m_tasksLoaded = false;
    QVariantList m_mailAccounts;
    QString m_error;
    QString m_status;
    QString m_lastSync;

    QTimer *m_reloadTimer = nullptr;
    QTimer *m_syncTimer = nullptr;
    QTimer *m_pushTimer = nullptr;
    QTimer *m_statusTimer = nullptr;
    QFileSystemWatcher *m_watcher = nullptr;
    ReminderService *m_reminders = nullptr;
};
