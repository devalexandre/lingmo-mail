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

#include "reminderservice.h"
#include "calendarbridge.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QLockFile>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTimer>

namespace {
// Reminders missed by up to this much (suspend, login) still show
constexpr qint64 CatchUpSecs = 15 * 60;
constexpr qint64 LookAheadSecs = 26 * 3600;
// Fired keys are kept this long
constexpr qint64 KeepSecs = 3 * 24 * 3600;
} // namespace

ReminderService::ReminderService(CalendarBridge *bridge, QObject *parent)
    : QObject(parent)
    , m_bridge(bridge)
{
    m_minute = new QTimer(this);
    m_minute->setInterval(60 * 1000);
    connect(m_minute, &QTimer::timeout, this, &ReminderService::check);

    m_next = new QTimer(this);
    m_next->setSingleShot(true);
    connect(m_next, &QTimer::timeout, this, &ReminderService::fireDue);

    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(1500);
    connect(m_debounce, &QTimer::timeout, this, &ReminderService::check);
}

ReminderService::~ReminderService()
{
    if (m_owner) {
        if (m_isOwner)
            m_owner->unlock();
        delete m_owner;
    }
}

bool ReminderService::requested(int argc, char **argv)
{
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--reminders") == 0)
            return true;
    }
    return false;
}

int ReminderService::runHeadless(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("lingmoos"));
    app.setApplicationName(QStringLiteral("lingmo-mail"));

    // One background instance per session
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation)
        + QStringLiteral("/lingmo-mail");
    QDir().mkpath(dir);
    QLockFile instance(dir + QStringLiteral("/reminders-daemon.lock"));
    instance.setStaleLockTime(0);
    if (!instance.tryLock(0))
        return 0;

    CalendarBridge bridge(nullptr, CalendarBridge::Headless);
    return app.exec();
}

QString ReminderService::stateDir() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation)
        + QStringLiteral("/lingmo-mail");
    QDir().mkpath(dir);
    QFile::setPermissions(dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    return dir;
}

void ReminderService::start()
{
    m_minute->start();
    watch();
    check();
}

void ReminderService::refresh()
{
    m_debounce->start();
}

bool ReminderService::acquire()
{
    if (m_isOwner)
        return true;
    if (!m_owner) {
        m_owner = new QLockFile(stateDir() + QStringLiteral("/reminders-owner.lock"));
        // Only a dead owner (crash, logout) frees the lock, never age
        m_owner->setStaleLockTime(0);
    }
    m_isOwner = m_owner->tryLock(0);
    return m_isOwner;
}

void ReminderService::watch()
{
    if (!m_watcher) {
        m_watcher = new QFileSystemWatcher(this);
        connect(m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] {
            watch();
            refresh();
        });
    }
    const QString root = m_bridge->calendarsPath();
    QStringList wanted;
    if (QFileInfo(root).isDir()) {
        wanted << root;
        const QStringList folders = QDir(root).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
        for (const QString &folder : folders)
            wanted << root + QLatin1Char('/') + folder;
    }
    const QStringList watched = m_watcher->directories();
    for (const QString &path : watched) {
        if (!wanted.contains(path))
            m_watcher->removePath(path);
    }
    for (const QString &path : std::as_const(wanted)) {
        if (!watched.contains(path))
            m_watcher->addPath(path);
    }
}

void ReminderService::check()
{
    watch();
    // Another process (the background service or the app) shows the reminders
    if (!acquire())
        return;
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    m_bridge->call(QStringLiteral("alarms"),
                   {{QStringLiteral("op"), QStringLiteral("alarms")},
                    {QStringLiteral("from"), now - CatchUpSecs},
                    {QStringLiteral("to"), now + LookAheadSecs}},
                   60000, [this](bool ok, const QVariant &data, const QString &) {
                       if (!ok)
                           return;   // try again on the next minute
                       m_alarms = data.toList();
                       fireDue();
                   });
}

void ReminderService::fireDue()
{
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    qint64 next = 0;
    for (const QVariant &item : std::as_const(m_alarms)) {
        const QVariantMap alarm = item.toMap();
        const qint64 when = alarm.value(QStringLiteral("when")).toLongLong();
        if (when <= now) {
            if (when >= now - CatchUpSecs && remember(alarm.value(QStringLiteral("key")).toString()))
                notify(alarm);
        } else if (!next || when < next) {
            next = when;
        }
    }
    if (next) {
        const qint64 wait = (next - now) * 1000 + 300;
        m_next->start(int(qMin<qint64>(wait, 6 * 3600 * 1000)));
    } else {
        m_next->stop();
    }
}

// True the first time a key is seen, across processes
bool ReminderService::remember(const QString &key)
{
    if (key.isEmpty())
        return false;
    const QString dir = stateDir();
    QLockFile lock(dir + QStringLiteral("/reminders-state.lock"));
    lock.setStaleLockTime(30000);
    if (!lock.tryLock(5000))
        return false;
    const QString path = dir + QStringLiteral("/reminders-notified.json");
    QJsonObject fired;
    QFile input(path);
    if (input.open(QIODevice::ReadOnly) && input.size() < 4 * 1024 * 1024)
        fired = QJsonDocument::fromJson(input.readAll()).object();
    input.close();
    if (fired.contains(key))
        return false;
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    for (auto it = fired.begin(); it != fired.end();) {
        if (it.value().toInteger() < now - KeepSecs)
            it = fired.erase(it);
        else
            ++it;
    }
    fired.insert(key, now);
    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly))
        return false;
    output.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    output.write(QJsonDocument(fired).toJson(QJsonDocument::Compact));
    return output.commit();
}

QString ReminderService::describe(const QVariantMap &alarm)
{
    const QLocale locale;
    const QDateTime start = QDateTime::fromString(alarm.value(QStringLiteral("start")).toString(), Qt::ISODate);
    const bool allDay = alarm.value(QStringLiteral("allDay")).toBool();
    const bool task = alarm.value(QStringLiteral("kind")).toString() == QLatin1String("task");
    const QDate today = QDate::currentDate();
    QString day;
    if (start.date() == today)
        day = tr("hoje");
    else if (start.date() == today.addDays(1))
        day = tr("amanhã");
    else
        day = locale.toString(start.date(), QStringLiteral("ddd, d MMM"));
    QString text;
    if (task)
        text = allDay ? tr("Tarefa para %1").arg(day)
                      : tr("Tarefa para %1 às %2").arg(day, locale.toString(start.time(), QStringLiteral("HH:mm")));
    else if (allDay)
        text = tr("Dia inteiro, %1").arg(day);
    else
        text = tr("Começa %1 às %2").arg(day, locale.toString(start.time(), QStringLiteral("HH:mm")));
    const QString location = alarm.value(QStringLiteral("location")).toString().simplified();
    if (!location.isEmpty())
        text += QStringLiteral(" · ") + location.left(120);
    return text;
}

void ReminderService::notify(const QVariantMap &alarm)
{
    QDBusMessage message = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("/org/freedesktop/Notifications"),
        QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("Notify"));
    QVariantMap hints;
    hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("lingmo-mail"));
    hints.insert(QStringLiteral("urgency"), QVariant::fromValue(uchar(1)));
    // Plain text only: titles come from other people's invitations
    QString title = alarm.value(QStringLiteral("title")).toString().simplified().left(200);
    title.replace(QLatin1Char('<'), QStringLiteral("‹")).replace(QLatin1Char('>'), QStringLiteral("›"));
    QString body = describe(alarm).toHtmlEscaped();
    message << tr("Calendário") << uint(0) << QStringLiteral("lingmo-mail") << title << body << QStringList()
            << hints << int(-1);
    QDBusConnection::sessionBus().call(message, QDBus::NoBlock);
}
