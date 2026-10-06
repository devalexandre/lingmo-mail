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

#include <QObject>
#include <QVariant>

class CalendarBridge;
class QFileSystemWatcher;
class QLockFile;
class QTimer;

// Desktop notifications for event alarms and task due dates.
//
// Runs inside the app and in the background mode (`lingmo-mail --reminders`,
// started from XDG autostart). Only the process holding the owner lock
// notifies, and fired alarms are remembered in a shared state file, so the
// same reminder never shows twice.
class ReminderService : public QObject
{
    Q_OBJECT

public:
    explicit ReminderService(CalendarBridge *bridge, QObject *parent = nullptr);
    ~ReminderService() override;

    static bool requested(int argc, char **argv);
    static int runHeadless(int argc, char **argv);

public Q_SLOTS:
    void start();
    void refresh();

private:
    bool acquire();
    void check();
    void fireDue();
    void watch();
    void notify(const QVariantMap &alarm);
    bool remember(const QString &key);
    QString stateDir() const;
    static QString describe(const QVariantMap &alarm);

    CalendarBridge *m_bridge;
    QLockFile *m_owner = nullptr;
    bool m_isOwner = false;
    QTimer *m_minute = nullptr;
    QTimer *m_next = nullptr;
    QTimer *m_debounce = nullptr;
    QFileSystemWatcher *m_watcher = nullptr;
    QVariantList m_alarms;
};
