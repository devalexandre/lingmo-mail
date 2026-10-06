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

#include "calendarbridge.h"
#include "reminderservice.h"

#include <QDate>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTimer>

namespace {
// The worker reads at most 1 MiB from stdin
constexpr qsizetype MaxRequest = 1024 * 1024 - 1;
// A few thousand expanded events at most
constexpr qsizetype MaxReply = 32 * 1024 * 1024;
constexpr qint64 MaxImport = 900 * 1024;
constexpr int SyncEveryMs = 15 * 60 * 1000;

const QString SetupKinds[] = {QStringLiteral("caldav-discover"), QStringLiteral("caldav-add")};

QString clip(QString value, int length)
{
    value.remove(QChar(0));
    return value.left(length);
}

QString singleLine(QString value)
{
    value.replace(QLatin1Char('\r'), QLatin1Char(' '));
    value.replace(QLatin1Char('\n'), QLatin1Char(' '));
    value.remove(QChar(0));
    return value.simplified();
}

// Request ids come from QML: keep them short and plain
QString requestKind(const QString &prefix, const QString &requestId)
{
    static const QRegularExpression unsafe(QStringLiteral("[^A-Za-z0-9_.-]"));
    QString id = requestId.left(64);
    id.remove(unsafe);
    return prefix + id;
}
} // namespace

CalendarBridge::CalendarBridge(QObject *parent, Mode mode)
    : QObject(parent)
    , m_mode(mode)
{
    m_reloadTimer = new QTimer(this);
    m_reloadTimer->setSingleShot(true);
    m_reloadTimer->setInterval(350);
    connect(m_reloadTimer, &QTimer::timeout, this, &CalendarBridge::reloadData);

    m_statusTimer = new QTimer(this);
    m_statusTimer->setSingleShot(true);
    m_statusTimer->setInterval(6000);
    connect(m_statusTimer, &QTimer::timeout, this, [this] { setStatus(QString()); });

    m_reminders = new ReminderService(this, this);

    if (m_mode == Headless) {
        QTimer::singleShot(0, m_reminders, &ReminderService::start);
        return;
    }

    m_watcher = new QFileSystemWatcher(this);
    connect(m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] {
        watchFolders();
        scheduleReload();
        m_reminders->refresh();
    });

    // Periodic two-way sync while the app is open
    m_syncTimer = new QTimer(this);
    m_syncTimer->setInterval(SyncEveryMs);
    connect(m_syncTimer, &QTimer::timeout, this, [this] {
        if (!m_accounts.isEmpty())
            sync();
    });
    m_syncTimer->start();

    // Local edits in a synced calendar go up shortly after
    m_pushTimer = new QTimer(this);
    m_pushTimer->setSingleShot(true);
    m_pushTimer->setInterval(4000);
    connect(m_pushTimer, &QTimer::timeout, this, &CalendarBridge::sync);

    QTimer::singleShot(0, this, &CalendarBridge::reload);
    QTimer::singleShot(0, m_reminders, &ReminderService::start);
}

CalendarBridge::~CalendarBridge()
{
    const auto processes = m_jobs.keys();
    for (QProcess *process : processes) {
        process->disconnect(this);
        process->kill();
        process->waitForFinished(1000);
        delete process;
    }
}

QString CalendarBridge::backendPath() const
{
    const QString override = qEnvironmentVariable("LINGMO_CALENDAR_BACKEND");
    if (!override.isEmpty() && QFileInfo(override).isFile())
        return override;
    // Development trees: next to the mail worker when only that one is overridden
    const QString mail = qEnvironmentVariable("LINGMO_MAIL_BACKEND");
    if (!mail.isEmpty() && !QFileInfo(QStringLiteral(CALENDAR_BACKEND)).isFile()) {
        const QString sibling = QFileInfo(mail).absolutePath() + QStringLiteral("/calendar_backend.py");
        if (QFileInfo(sibling).isFile())
            return sibling;
    }
    return QStringLiteral(CALENDAR_BACKEND);
}

QString CalendarBridge::calendarsPath() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
        + QStringLiteral("/lingmo-mail/calendars");
}

// ---------- Worker processes

void CalendarBridge::call(const QString &kind, const QVariantMap &payload, int timeoutMs, Callback callback)
{
    cancel(kind);

    QByteArray line = QJsonDocument(QJsonObject::fromVariantMap(payload)).toJson(QJsonDocument::Compact);
    if (line.size() > MaxRequest) {
        line.fill('\0');
        callback(false, {}, tr("O conteúdo é grande demais."));
        return;
    }
    const QString backend = backendPath();
    if (!QFileInfo(backend).isFile()) {
        callback(false, {}, tr("Um componente do calendário está faltando. Reinstale o aplicativo."));
        return;
    }
    QString python = QStringLiteral("/usr/bin/python3");
    if (!QFileInfo(python).isExecutable())
        python = QStandardPaths::findExecutable(QStringLiteral("python3"));
    if (python.isEmpty()) {
        callback(false, {}, tr("O Python 3 não está instalado. Instale-o para usar o calendário."));
        return;
    }

    auto *process = new QProcess(this);
    process->setProgram(python);
    // -I: ignore PYTHON* variables and the user's site-packages
    process->setArguments({QStringLiteral("-I"), backend});
    // Tracebacks could carry server replies: never keep them
    process->setStandardErrorFile(QProcess::nullDevice());

    Job job;
    job.kind = kind;
    job.callback = std::move(callback);
    job.timer = new QTimer(process);
    job.timer->setSingleShot(true);
    job.timer->setInterval(timeoutMs);
    m_jobs.insert(process, job);
    m_running.insert(kind, process);

    connect(job.timer, &QTimer::timeout, this, [this, process] {
        finish(process, false, {}, tr("O calendário demorou demais para responder. Verifique a conexão e tente novamente."));
    });
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
        auto it = m_jobs.find(process);
        if (it == m_jobs.end())
            return;
        it->buffer += process->readAllStandardOutput();
        if (it->buffer.size() > MaxReply)
            finish(process, false, {}, tr("A resposta do calendário é grande demais."));
    });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            finish(process, false, {}, tr("Não foi possível iniciar o serviço de calendário. Verifique se o Python 3 está instalado."));
    });
    connect(process, &QProcess::finished, this, [this, process](int, QProcess::ExitStatus) {
        auto it = m_jobs.find(process);
        if (it == m_jobs.end())
            return;
        it->buffer += process->readAllStandardOutput();
        QVariantMap reply;
        const QList<QByteArray> lines = it->buffer.split('\n');
        for (const QByteArray &chunk : lines) {
            if (chunk.trimmed().isEmpty())
                continue;
            QJsonParseError parseError;
            const QJsonDocument document = QJsonDocument::fromJson(chunk, &parseError);
            if (parseError.error == QJsonParseError::NoError && document.isObject()
                && document.object().contains(QStringLiteral("ok")))
                reply = document.object().toVariantMap();
        }
        if (!reply.contains(QStringLiteral("ok"))) {
            finish(process, false, {}, tr("O serviço de calendário foi encerrado inesperadamente. Tente novamente."));
            return;
        }
        const bool ok = reply.value(QStringLiteral("ok")).toBool();
        QString error = reply.value(QStringLiteral("error")).toString();
        if (!ok && error.isEmpty())
            error = tr("Não foi possível concluir a operação.");
        finish(process, ok, reply.value(QStringLiteral("data")), error);
    });

    Q_EMIT busyChanged();
    job.timer->start();
    process->start(QIODevice::ReadWrite);
    if (!m_jobs.contains(process)) {   // failed to start, already reported
        line.fill('\0');
        return;
    }
    line.append('\n');
    process->write(line);
    process->closeWriteChannel();
    // Don't keep a copy of a password around longer than needed
    line.fill('\0');
}

void CalendarBridge::finish(QProcess *process, bool ok, const QVariant &data, const QString &error)
{
    auto it = m_jobs.find(process);
    if (it == m_jobs.end())
        return;
    const Job job = *it;
    m_jobs.erase(it);
    if (m_running.value(job.kind) == process)
        m_running.remove(job.kind);
    job.timer->stop();
    process->disconnect(this);
    if (process->state() != QProcess::NotRunning) {
        process->kill();
        connect(process, &QProcess::finished, process, &QObject::deleteLater);
    } else {
        process->deleteLater();
    }
    Q_EMIT busyChanged();
    if (job.callback)
        job.callback(ok, data, error);
}

void CalendarBridge::cancel(const QString &kind)
{
    QProcess *process = m_running.take(kind);
    if (!process)
        return;
    auto it = m_jobs.find(process);
    if (it != m_jobs.end()) {
        it->timer->stop();
        m_jobs.erase(it);
    }
    process->disconnect(this);
    if (process->state() != QProcess::NotRunning) {
        process->kill();
        connect(process, &QProcess::finished, process, &QObject::deleteLater);
    } else {
        process->deleteLater();
    }
    Q_EMIT busyChanged();
}

bool CalendarBridge::busy() const
{
    for (auto it = m_running.cbegin(); it != m_running.cend(); ++it) {
        if (!it.key().startsWith(QLatin1String("alarms")) && it.key() != QLatin1String("sync"))
            return true;
    }
    return false;
}

bool CalendarBridge::setupBusy() const
{
    for (const QString &kind : SetupKinds) {
        if (m_running.contains(kind))
            return true;
    }
    return false;
}

void CalendarBridge::setError(const QString &error)
{
    if (m_error == error)
        return;
    m_error = error;
    Q_EMIT errorChanged();
}

void CalendarBridge::clearError()
{
    setError(QString());
}

void CalendarBridge::setStatus(const QString &status)
{
    if (!status.isEmpty())
        m_statusTimer->start();
    if (m_status == status)
        return;
    m_status = status;
    Q_EMIT statusChanged();
}

// ---------- Loading

void CalendarBridge::reload()
{
    loadCalendars();
    loadUpcoming();
    loadTasks();
    if (!m_rangeStart.isEmpty())
        loadRange(m_rangeStart, m_rangeEnd);
}

void CalendarBridge::scheduleReload()
{
    if (m_mode == Interactive)
        m_reloadTimer->start();
}

void CalendarBridge::reloadData()
{
    reload();
}

void CalendarBridge::watchFolders()
{
    if (!m_watcher)
        return;
    const QString root = calendarsPath();
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

void CalendarBridge::loadCalendars()
{
    call(QStringLiteral("calendars"), {{QStringLiteral("op"), QStringLiteral("calendars")}}, 30000,
         [this](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 setError(error);
                 return;
             }
             const QVariantMap map = data.toMap();
             const bool first = !m_loaded;
             m_calendars = map.value(QStringLiteral("calendars")).toList();
             m_accounts = map.value(QStringLiteral("accounts")).toList();
             m_defaultCalendar = map.value(QStringLiteral("defaultCalendar")).toString();
             m_defaultTaskList = map.value(QStringLiteral("defaultTaskList")).toString();
             m_loaded = true;
             QString newest;
             for (const QVariant &account : std::as_const(m_accounts)) {
                 const QString when = account.toMap().value(QStringLiteral("lastSync")).toString();
                 if (when > newest)
                     newest = when;
             }
             if (newest != m_lastSync) {
                 m_lastSync = newest;
                 Q_EMIT lastSyncChanged();
             }
             Q_EMIT calendarsChanged();
             watchFolders();
             // First load with synced accounts: bring them up to date
             if (first && !m_accounts.isEmpty())
                 sync();
         });
}

void CalendarBridge::loadRange(const QString &startDay, const QString &endDay)
{
    if (QDate::fromString(startDay, Qt::ISODate).isNull() || QDate::fromString(endDay, Qt::ISODate).isNull())
        return;
    const bool changed = startDay != m_rangeStart || endDay != m_rangeEnd;
    m_rangeStart = startDay;
    m_rangeEnd = endDay;
    if (changed) {
        // Don't show the previous period's events while the new one loads
        m_events.clear();
        Q_EMIT eventsChanged();
    }
    call(QStringLiteral("range"),
         {{QStringLiteral("op"), QStringLiteral("range")},
          {QStringLiteral("start"), startDay},
          {QStringLiteral("end"), endDay}},
         60000, [this, startDay, endDay](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 setError(error);
                 return;
             }
             if (startDay != m_rangeStart || endDay != m_rangeEnd)
                 return;
             m_events = data.toList();
             Q_EMIT eventsChanged();
         });
}

void CalendarBridge::loadUpcoming()
{
    const QDate today = QDate::currentDate();
    call(QStringLiteral("upcoming"),
         {{QStringLiteral("op"), QStringLiteral("range")},
          {QStringLiteral("start"), today.toString(Qt::ISODate)},
          {QStringLiteral("end"), today.addDays(15).toString(Qt::ISODate)}},
         60000, [this](bool ok, const QVariant &data, const QString &) {
             if (!ok)
                 return;
             m_upcoming = data.toList();
             Q_EMIT upcomingChanged();
         });
}

void CalendarBridge::loadTasks()
{
    call(QStringLiteral("tasks"), {{QStringLiteral("op"), QStringLiteral("tasks")}}, 60000,
         [this](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 setError(error);
                 return;
             }
             m_tasks = data.toList();
             m_tasksLoaded = true;
             Q_EMIT tasksChanged();
         });
}

QVariantMap CalendarBridge::calendar(const QString &id) const
{
    for (const QVariant &item : m_calendars) {
        const QVariantMap map = item.toMap();
        if (map.value(QStringLiteral("id")).toString() == id)
            return map;
    }
    return {};
}

bool CalendarBridge::isCalDav(const QString &calendarId) const
{
    return calendar(calendarId).value(QStringLiteral("source")).toString() == QLatin1String("caldav");
}

void CalendarBridge::write(const QString &op, const QVariantMap &payload, const QString &done,
                           const QString &calendarId)
{
    QVariantMap request = payload;
    request.insert(QStringLiteral("op"), op);
    call(QStringLiteral("write-%1").arg(++m_serial), request, 30000,
         [this, done, calendarId](bool ok, const QVariant &, const QString &error) {
             if (!ok) {
                 setError(error);
                 return;
             }
             setError(QString());
             if (!done.isEmpty())
                 setStatus(done);
             scheduleReload();
             if (isCalDav(calendarId) && m_pushTimer)
                 m_pushTimer->start();
         });
}

// ---------- Events

void CalendarBridge::saveEvent(const QVariantMap &event)
{
    const QString calendarId = event.value(QStringLiteral("calendarId")).toString();
    const QString original = event.value(QStringLiteral("originalCalendarId")).toString();
    call(QStringLiteral("write-%1").arg(++m_serial),
         {{QStringLiteral("op"), QStringLiteral("save_event")}, {QStringLiteral("event"), event}}, 30000,
         [this, calendarId, original](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 Q_EMIT eventSaveFailed(error);
                 return;
             }
             setStatus(tr("Evento salvo."));
             scheduleReload();
             if ((isCalDav(calendarId) || isCalDav(original)) && m_pushTimer)
                 m_pushTimer->start();
             Q_EMIT eventSaved(data.toMap());
         });
}

void CalendarBridge::deleteEvent(const QVariantMap &event, const QString &scope)
{
    const QString calendarId = event.value(QStringLiteral("calendarId")).toString();
    write(QStringLiteral("delete_event"),
          {{QStringLiteral("calendarId"), calendarId},
           {QStringLiteral("file"), event.value(QStringLiteral("file"))},
           {QStringLiteral("uid"), event.value(QStringLiteral("uid"))},
           {QStringLiteral("recurrenceId"), event.value(QStringLiteral("recurrenceId"))},
           {QStringLiteral("scope"), scope == QLatin1String("this") ? scope : QStringLiteral("all")}},
          scope == QLatin1String("this") ? tr("Ocorrência excluída.") : tr("Evento excluído."), calendarId);
}

void CalendarBridge::importIcsFile(const QUrl &file, const QString &calendarId)
{
    if (!file.isLocalFile()) {
        setError(tr("Escolha um arquivo deste computador."));
        return;
    }
    QFile input(file.toLocalFile());
    if (input.size() > MaxImport) {
        setError(tr("O arquivo é grande demais para importar (limite de 900 KB)."));
        return;
    }
    if (!input.open(QIODevice::ReadOnly)) {
        setError(tr("Não foi possível abrir o arquivo."));
        return;
    }
    const QString text = QString::fromUtf8(input.read(MaxImport));
    call(QStringLiteral("write-%1").arg(++m_serial),
         {{QStringLiteral("op"), QStringLiteral("import_ics")},
          {QStringLiteral("text"), text},
          {QStringLiteral("calendarId"), calendarId}},
         60000, [this, calendarId](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 setError(error);
                 return;
             }
             const int count = data.toMap().value(QStringLiteral("imported")).toInt();
             setStatus(tr("%n item(ns) importado(s).", nullptr, count));
             scheduleReload();
             if (isCalDav(calendarId) && m_pushTimer)
                 m_pushTimer->start();
             Q_EMIT imported(count);
         });
}

// ---------- Calendars

void CalendarBridge::saveCalendar(const QVariantMap &calendar)
{
    write(QStringLiteral("calendar_save"), {{QStringLiteral("calendar"), calendar}},
          calendar.value(QStringLiteral("id")).toString().isEmpty() ? tr("Calendário criado.") : QString(), QString());
}

void CalendarBridge::setCalendarHidden(const QString &id, bool hidden)
{
    // Instant feedback; the worker stores it
    for (QVariant &item : m_calendars) {
        QVariantMap map = item.toMap();
        if (map.value(QStringLiteral("id")).toString() == id) {
            map.insert(QStringLiteral("hidden"), hidden);
            item = map;
            const QString color = map.value(QStringLiteral("color")).toString();
            Q_EMIT calendarsChanged();
            write(QStringLiteral("calendar_save"),
                  {{QStringLiteral("calendar"), QVariantMap{{QStringLiteral("id"), id},
                                                            {QStringLiteral("color"), color},
                                                            {QStringLiteral("hidden"), hidden}}}},
                  QString(), QString());
            return;
        }
    }
}

void CalendarBridge::deleteCalendar(const QString &id)
{
    write(QStringLiteral("calendar_delete"), {{QStringLiteral("id"), id}}, tr("Calendário excluído."), QString());
}

void CalendarBridge::setDefaultCalendar(const QString &id, bool tasks)
{
    write(QStringLiteral("set_default"),
          {{QStringLiteral("id"), id}, {QStringLiteral("kind"), tasks ? QStringLiteral("tasks") : QStringLiteral("events")}},
          QString(), QString());
}

// ---------- Tasks

void CalendarBridge::saveTask(const QVariantMap &task)
{
    write(QStringLiteral("save_task"), {{QStringLiteral("task"), task}},
          task.value(QStringLiteral("file")).toString().isEmpty() ? tr("Tarefa criada.") : tr("Tarefa salva."),
          task.value(QStringLiteral("calendarId")).toString());
}

void CalendarBridge::completeTask(const QString &calendarId, const QString &file, bool done)
{
    // Instant feedback in the list
    for (QVariant &item : m_tasks) {
        QVariantMap map = item.toMap();
        if (map.value(QStringLiteral("calendarId")).toString() == calendarId
            && map.value(QStringLiteral("file")).toString() == file) {
            map.insert(QStringLiteral("done"), done);
            item = map;
            Q_EMIT tasksChanged();
            break;
        }
    }
    write(QStringLiteral("complete_task"),
          {{QStringLiteral("calendarId"), calendarId}, {QStringLiteral("file"), file}, {QStringLiteral("done"), done}},
          done ? tr("Tarefa concluída.") : QString(), calendarId);
}

void CalendarBridge::deleteTask(const QString &calendarId, const QString &file)
{
    write(QStringLiteral("delete_task"), {{QStringLiteral("calendarId"), calendarId}, {QStringLiteral("file"), file}},
          tr("Tarefa excluída."), calendarId);
}

void CalendarBridge::createTask(const QString &title, const QString &notes, const QString &dueIso)
{
    QString name = singleLine(title).left(500);
    if (name.isEmpty())
        name = tr("Nova tarefa");
    QString due = dueIso.trimmed();
    static const QRegularExpression valid(QStringLiteral("^\\d{4}-\\d{2}-\\d{2}(T\\d{2}:\\d{2}(:\\d{2})?)?$"));
    if (!valid.match(due).hasMatch())
        due.clear();
    const QString list = m_defaultTaskList;
    call(QStringLiteral("write-%1").arg(++m_serial),
         {{QStringLiteral("op"), QStringLiteral("save_task")},
          {QStringLiteral("task"), QVariantMap{{QStringLiteral("title"), name},
                                               {QStringLiteral("notes"), clip(notes, 20000)},
                                               {QStringLiteral("due"), due.left(16)},
                                               {QStringLiteral("calendarId"), list}}}},
         30000, [this, name](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 setError(error);
                 return;
             }
             const QVariantMap task = data.toMap();
             setStatus(tr("Tarefa “%1” adicionada em %2.").arg(name, task.value(QStringLiteral("listName")).toString()));
             scheduleReload();
             if (isCalDav(task.value(QStringLiteral("calendarId")).toString()) && m_pushTimer)
                 m_pushTimer->start();
             Q_EMIT taskCreated(name);
         });
}

// ---------- Invitations

void CalendarBridge::parseInvite(const QString &requestId, const QString &icsText, const QString &email)
{
    call(requestKind(QStringLiteral("invite-parse-"), requestId),
         {{QStringLiteral("op"), QStringLiteral("invite_parse")},
          {QStringLiteral("text"), icsText},
          {QStringLiteral("email"), singleLine(email)}},
         30000, [this, requestId](bool ok, const QVariant &data, const QString &error) {
             if (ok)
                 Q_EMIT inviteParsed(requestId, data.toMap());
             else
                 Q_EMIT inviteFailed(requestId, error);
         });
}

void CalendarBridge::respondInvite(const QString &requestId, const QString &icsText, const QString &partstat,
                                   const QString &email, const QString &name)
{
    call(requestKind(QStringLiteral("invite-reply-"), requestId),
         {{QStringLiteral("op"), QStringLiteral("invite_reply")},
          {QStringLiteral("text"), icsText},
          {QStringLiteral("partstat"), partstat},
          {QStringLiteral("email"), singleLine(email)},
          {QStringLiteral("name"), singleLine(name)},
          {QStringLiteral("calendarId"), m_defaultCalendar}},
         30000, [this, requestId](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 Q_EMIT inviteFailed(requestId, error);
                 return;
             }
             const QVariantMap result = data.toMap();
             scheduleReload();
             if (isCalDav(result.value(QStringLiteral("calendarId")).toString()) && m_pushTimer)
                 m_pushTimer->start();
             Q_EMIT inviteResponded(requestId, result);
         });
}

void CalendarBridge::cancelInvite(const QString &requestId, const QString &icsText)
{
    call(requestKind(QStringLiteral("invite-cancel-"), requestId),
         {{QStringLiteral("op"), QStringLiteral("invite_cancel")}, {QStringLiteral("text"), icsText}}, 30000,
         [this, requestId](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 Q_EMIT inviteFailed(requestId, error);
                 return;
             }
             scheduleReload();
             if (m_pushTimer && !m_accounts.isEmpty())
                 m_pushTimer->start();
             Q_EMIT inviteCancelled(requestId, data.toMap().value(QStringLiteral("removed")).toBool());
         });
}

void CalendarBridge::applyInviteReply(const QString &requestId, const QString &icsText)
{
    call(requestKind(QStringLiteral("invite-apply-"), requestId),
         {{QStringLiteral("op"), QStringLiteral("invite_apply_reply")}, {QStringLiteral("text"), icsText}}, 30000,
         [this, requestId](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 Q_EMIT inviteFailed(requestId, error);
                 return;
             }
             scheduleReload();
             if (m_pushTimer && !m_accounts.isEmpty())
                 m_pushTimer->start();
             Q_EMIT inviteResponded(requestId, data.toMap());
         });
}

void CalendarBridge::addInvite(const QString &requestId, const QString &icsText)
{
    call(requestKind(QStringLiteral("invite-add-"), requestId),
         {{QStringLiteral("op"), QStringLiteral("import_ics")},
          {QStringLiteral("text"), icsText},
          {QStringLiteral("calendarId"), m_defaultCalendar}},
         30000, [this, requestId](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 Q_EMIT inviteFailed(requestId, error);
                 return;
             }
             const QVariantMap result = data.toMap();
             setStatus(tr("Adicionado ao calendário."));
             scheduleReload();
             if (isCalDav(result.value(QStringLiteral("calendarId")).toString()) && m_pushTimer)
                 m_pushTimer->start();
             Q_EMIT inviteResponded(requestId, result);
         });
}

// ---------- CalDAV

QVariantMap CalendarBridge::account(const QVariantMap &input) const
{
    return {
        {QStringLiteral("provider"), input.value(QStringLiteral("provider")).toString()},
        {QStringLiteral("email"), singleLine(input.value(QStringLiteral("email")).toString())},
        {QStringLiteral("username"), singleLine(input.value(QStringLiteral("username")).toString())},
        {QStringLiteral("url"), singleLine(input.value(QStringLiteral("url")).toString())},
        {QStringLiteral("name"), singleLine(input.value(QStringLiteral("name")).toString())},
    };
}

void CalendarBridge::loadMailAccounts()
{
    call(QStringLiteral("mail-accounts"), {{QStringLiteral("op"), QStringLiteral("mail_accounts")}}, 20000,
         [this](bool ok, const QVariant &data, const QString &) {
             m_mailAccounts = ok ? data.toList() : QVariantList();
             Q_EMIT mailAccountsChanged();
         });
}

void CalendarBridge::discoverCalDav(const QVariantMap &input, const QString &password)
{
    QVariantMap payload = account(input);
    payload.insert(QStringLiteral("op"), QStringLiteral("caldav_discover"));
    payload.insert(QStringLiteral("password"), password);
    call(QStringLiteral("caldav-discover"), payload, 90000,
         [this](bool ok, const QVariant &data, const QString &error) {
             if (ok)
                 Q_EMIT calDavDiscovered(data.toMap().value(QStringLiteral("calendars")).toList());
             else
                 Q_EMIT setupFailed(error);
         });
}

void CalendarBridge::addCalDavAccount(const QVariantMap &input, const QString &password)
{
    if (setupBusy())
        return;
    QVariantMap payload = account(input);
    payload.insert(QStringLiteral("op"), QStringLiteral("caldav_add_account"));
    payload.insert(QStringLiteral("password"), password);
    cancel(QStringLiteral("sync"));
    call(QStringLiteral("caldav-add"), payload, 300000,
         [this](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 Q_EMIT setupFailed(error);
                 return;
             }
             const QVariantMap result = data.toMap();
             const QVariantMap added = result.value(QStringLiteral("account")).toMap();
             const QStringList errors = result.value(QStringLiteral("sync")).toMap()
                                            .value(QStringLiteral("errors")).toStringList();
             setStatus(tr("Conta %1 conectada.").arg(added.value(QStringLiteral("name")).toString()));
             if (!errors.isEmpty())
                 setError(errors.first());
             scheduleReload();
             Q_EMIT calDavAdded(added);
         });
}

void CalendarBridge::cancelSetup()
{
    for (const QString &kind : SetupKinds)
        cancel(kind);
}

void CalendarBridge::removeCalDavAccount(const QString &id)
{
    cancel(QStringLiteral("sync"));
    write(QStringLiteral("caldav_remove"), {{QStringLiteral("accountId"), id}},
          tr("Conta removida. Os eventos continuam no servidor."), QString());
}

void CalendarBridge::sync()
{
    if (syncing() || setupBusy() || m_mode == Headless)
        return;
    if (m_accounts.isEmpty()) {
        setStatus(tr("Nenhuma conta de calendário para sincronizar."));
        return;
    }
    call(QStringLiteral("sync"), {{QStringLiteral("op"), QStringLiteral("caldav_sync")}}, 600000,
         [this](bool ok, const QVariant &data, const QString &error) {
             if (!ok) {
                 // Another sync (e.g. from the account setup) is running: not worth an alert
                 if (!error.contains(QStringLiteral("em andamento")))
                     setError(error);
                 return;
             }
             const QVariantList accounts = data.toMap().value(QStringLiteral("accounts")).toList();
             QString problem;
             for (const QVariant &account : accounts) {
                 const QVariantMap map = account.toMap();
                 const QStringList errors = map.value(QStringLiteral("errors")).toStringList();
                 if (!errors.isEmpty() && problem.isEmpty())
                     problem = tr("%1: %2").arg(map.value(QStringLiteral("name")).toString(), errors.first());
             }
             if (!problem.isEmpty())
                 setError(problem);
             else
                 setStatus(tr("Calendários sincronizados."));
             scheduleReload();
         });
}
