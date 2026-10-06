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

#include "mailbridge.h"
#include <QFile>

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDateTime>
#include <QDesktopServices>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

namespace {
// The worker reads at most 1 MiB from stdin
constexpr qsizetype MaxRequest = 1024 * 1024 - 1;
// Messages are capped at 20 MB by the worker; JSON escaping can grow that
constexpr qsizetype MaxReply = 96 * 1024 * 1024;

const QString Kinds[] = {QStringLiteral("discover"), QStringLiteral("save"), QStringLiteral("google")};

QString singleLine(QString value)
{
    value.replace(QLatin1Char('\r'), QLatin1Char(' '));
    value.replace(QLatin1Char('\n'), QLatin1Char(' '));
    value.remove(QChar(0));
    return value.simplified();
}

QDateTime parseDate(const QString &rfc2822)
{
    QString value = rfc2822.trimmed();
    // Drop trailing comments such as "(UTC)" or "(BRT)"
    static const QRegularExpression comment(QStringLiteral("\\s*\\([^)]*\\)\\s*$"));
    value.remove(comment);
    QDateTime date = QDateTime::fromString(value, Qt::RFC2822Date);
    if (!date.isValid()) {
        // Without the weekday, or with an unusual one
        static const QRegularExpression weekday(QStringLiteral("^[A-Za-z]{3},\\s*"));
        date = QDateTime::fromString(value.remove(weekday), Qt::RFC2822Date);
    }
    return date.isValid() ? date.toLocalTime() : QDateTime();
}
} // namespace
// ---------- Message model

QHash<int, QByteArray> MessageModel::roleNames() const
{
    return {
        {IdRole, "messageId"},
        {SubjectRole, "subject"},
        {SenderRole, "sender"},
        {SenderNameRole, "senderName"},
        {ToRole, "to"},
        {WhenRole, "when"},
        {FullDateRole, "fullDate"},
        {UnreadRole, "unread"},
        {StarredRole, "starred"},
        {AttachmentRole, "hasAttachment"},
        {AnsweredRole, "answered"},
    };
}

int MessageModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_items.size());
}

QVariant MessageModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size())
        return {};
    const QVariantMap &item = m_items.at(index.row());
    switch (role) {
    case IdRole: return item.value(QStringLiteral("id"));
    case SubjectRole: return item.value(QStringLiteral("subject"));
    case SenderRole: return item.value(QStringLiteral("sender"));
    case SenderNameRole: return item.value(QStringLiteral("senderName"));
    case ToRole: return item.value(QStringLiteral("to"));
    case WhenRole: return item.value(QStringLiteral("when"));
    case FullDateRole: return item.value(QStringLiteral("fullDate"));
    case UnreadRole: return item.value(QStringLiteral("unread")).toBool();
    case StarredRole: return item.value(QStringLiteral("starred")).toBool();
    case AttachmentRole: return item.value(QStringLiteral("hasAttachment")).toBool();
    case AnsweredRole: return item.value(QStringLiteral("answered")).toBool();
    }
    return {};
}

int MessageModel::indexOf(const QString &id) const
{
    for (int i = 0; i < m_items.size(); ++i) {
        if (m_items.at(i).value(QStringLiteral("id")).toString() == id)
            return i;
    }
    return -1;
}

QVariantList MessageModel::items() const
{
    QVariantList out;
    out.reserve(m_items.size());
    for (const QVariantMap &item : m_items)
        out.append(item);
    return out;
}

void MessageModel::setItems(const QVariantList &items)
{
    const int before = count();
    QList<QVariantMap> fresh;
    QSet<QString> freshIds;
    for (const QVariant &item : items) {
        fresh.append(item.toMap());
        freshIds.insert(fresh.last().value(QStringLiteral("id")).toString());
    }
    // 1. Rows that are gone
    for (int i = int(m_items.size()) - 1; i >= 0; --i) {
        if (!freshIds.contains(m_items.at(i).value(QStringLiteral("id")).toString())) {
            beginRemoveRows({}, i, i);
            m_items.removeAt(i);
            endRemoveRows();
        }
    }
    // 2. What is left must keep its order, else start over (e.g. the sort changed)
    int cursor = 0;
    bool ordered = true;
    for (const QVariantMap &item : std::as_const(m_items)) {
        const QString id = item.value(QStringLiteral("id")).toString();
        while (cursor < fresh.size() && fresh.at(cursor).value(QStringLiteral("id")).toString() != id)
            ++cursor;
        if (cursor == fresh.size()) {
            ordered = false;
            break;
        }
    }
    if (!ordered) {
        beginResetModel();
        m_items = fresh;
        endResetModel();
    } else {
        // 3. Update in place, insert the new ones where they belong
        for (int i = 0; i < fresh.size(); ++i) {
            if (i < m_items.size()
                && m_items.at(i).value(QStringLiteral("id")) == fresh.at(i).value(QStringLiteral("id"))) {
                if (m_items.at(i) != fresh.at(i)) {
                    m_items[i] = fresh.at(i);
                    Q_EMIT dataChanged(index(i), index(i));
                }
            } else {
                beginInsertRows({}, i, i);
                m_items.insert(i, fresh.at(i));
                endInsertRows();
            }
        }
    }
    if (count() != before)
        Q_EMIT countChanged();
}

void MessageModel::update(const QString &id, const QVariantMap &changes)
{
    const int row = indexOf(id);
    if (row < 0)
        return;
    for (auto it = changes.begin(); it != changes.end(); ++it)
        m_items[row].insert(it.key(), it.value());
    Q_EMIT dataChanged(index(row), index(row));
}

void MessageModel::remove(const QStringList &ids)
{
    bool changed = false;
    for (const QString &id : ids) {
        const int row = indexOf(id);
        if (row < 0)
            continue;
        beginRemoveRows({}, row, row);
        m_items.removeAt(row);
        endRemoveRows();
        changed = true;
    }
    if (changed)
        Q_EMIT countChanged();
}

// ---------- Bridge

MailBridge::MailBridge(QObject *parent)
    : QObject(parent)
    , m_model(new MessageModel(this))
{
    m_refreshTimer = new QTimer(this);
    if (refreshMinutes() > 0) {
        m_refreshTimer->setInterval(refreshMinutes() * 60 * 1000);
        connect(m_refreshTimer, &QTimer::timeout, this, [this] {
            if (!m_currentAccountId.isEmpty() && !loadingInbox())
                list(true);
            checkOtherAccounts();
        });
        m_refreshTimer->start();
    }
}

int MailBridge::refreshMinutes() const
{
    bool ok = false;
    const int minutes = qEnvironmentVariableIntValue("LINGMO_MAIL_REFRESH_MINUTES", &ok);
    return ok && minutes >= 0 ? minutes : 5;
}

bool MailBridge::googleAvailable() const
{
    // Same lookup as oauth_config() in backend.py
    if (!qEnvironmentVariableIsEmpty("LINGMO_GOOGLE_CLIENT_ID"))
        return true;
    const QString config = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    return QFile::exists(QStringLiteral("/etc/lingmo-mail/google-oauth.json"))
        || QFile::exists(config + QStringLiteral("/lingmo-online-accounts/google-oauth.json"));
}

MailBridge::~MailBridge()
{
    const auto processes = m_jobs.keys();
    for (QProcess *process : processes) {
        process->disconnect(this);
        process->kill();
        process->waitForFinished(1000);
        delete process;
    }
}

QString MailBridge::backendPath() const
{
    const QString override = qEnvironmentVariable("LINGMO_MAIL_BACKEND");
    if (!override.isEmpty() && QFileInfo(override).isFile())
        return override;
    return QStringLiteral(MAIL_BACKEND);
}

void MailBridge::request(const QString &kind, const QVariantMap &payload, int timeoutMs, Handler handler,
                         const QVariantMap &context)
{
    cancel(kind);

    QByteArray line = QJsonDocument(QJsonObject::fromVariantMap(payload)).toJson(QJsonDocument::Compact);
    m_context = context;   // for handlers that fail right away below
    if (line.size() > MaxRequest) {
        (this->*handler)(false, {}, tr("O conteúdo é grande demais para ser enviado."));
        return;
    }
    const QString backend = backendPath();
    if (!QFileInfo(backend).isFile()) {
        (this->*handler)(false, {}, tr("Um componente do E-mail está faltando. Reinstale o aplicativo."));
        return;
    }
    QString python = QStringLiteral("/usr/bin/python3");
    if (!QFileInfo(python).isExecutable())
        python = QStandardPaths::findExecutable(QStringLiteral("python3"));
    if (python.isEmpty()) {
        (this->*handler)(false, {}, tr("O Python 3 não está instalado. Instale-o para usar o E-mail."));
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
    job.handler = handler;
    job.context = context;
    job.timer = new QTimer(process);
    job.timer->setSingleShot(true);
    job.timer->setInterval(timeoutMs);
    m_jobs.insert(process, job);
    m_running.insert(kind, process);

    connect(job.timer, &QTimer::timeout, this, [this, process] {
        finish(process, false, {}, tr("O servidor demorou demais para responder. Verifique a conexão e tente novamente."));
    });
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
        auto it = m_jobs.find(process);
        if (it == m_jobs.end())
            return;
        it->buffer += process->readAllStandardOutput();
        if (it->buffer.size() > MaxReply) {
            finish(process, false, {}, tr("A resposta do servidor é grande demais."));
            return;
        }
        qsizetype newline;
        while ((newline = it->buffer.indexOf('\n')) >= 0) {
            const QByteArray chunk = it->buffer.left(newline);
            it->buffer.remove(0, newline + 1);
            handleLine(process, chunk);
            it = m_jobs.find(process);
            if (it == m_jobs.end())
                return;
        }
    });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            finish(process, false, {}, tr("Não foi possível iniciar o serviço de e-mail. Verifique se o Python 3 está instalado."));
    });
    connect(process, &QProcess::finished, this, [this, process](int, QProcess::ExitStatus) {
        auto it = m_jobs.find(process);
        if (it == m_jobs.end())
            return;
        it->buffer += process->readAllStandardOutput();
        if (!it->buffer.trimmed().isEmpty()) {
            const QByteArray rest = it->buffer;
            it->buffer.clear();
            handleLine(process, rest);
            it = m_jobs.find(process);
            if (it == m_jobs.end())
                return;
        }
        const QVariantMap reply = it->reply;
        if (!reply.contains(QStringLiteral("ok"))) {
            finish(process, false, {}, tr("O serviço de e-mail foi encerrado inesperadamente. Tente novamente."));
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
    // Don't keep a copy of the password around longer than needed
    line.fill('\0');
}

void MailBridge::handleLine(QProcess *process, const QByteArray &line)
{
    auto it = m_jobs.find(process);
    if (it == m_jobs.end() || line.trimmed().isEmpty())
        return;
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject())
        return;   // not ours; the final check reports a missing reply
    const QVariantMap object = document.object().toVariantMap();
    if (object.value(QStringLiteral("event")).toString() == QLatin1String("openUrl")) {
        const QUrl url(object.value(QStringLiteral("url")).toString(), QUrl::StrictMode);
        // Only the provider's sign-in page, over HTTPS
        if (url.isValid() && url.scheme() == QLatin1String("https")
            && url.host() == QLatin1String("accounts.google.com")) {
            QDesktopServices::openUrl(url);
            setStatus(tr("Continue o login no navegador. Esta janela atualiza sozinha ao terminar."));
        }
        return;
    }
    if (object.contains(QStringLiteral("ok")))
        it->reply = object;
}

void MailBridge::finish(QProcess *process, bool ok, const QVariant &data, const QString &error)
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
    m_context = job.context;
    (this->*job.handler)(ok, data, error);
    m_context.clear();
}

void MailBridge::cancel(const QString &kind)
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

bool MailBridge::setupBusy() const
{
    for (const QString &kind : Kinds) {
        if (m_running.contains(kind))
            return true;
    }
    return false;
}

void MailBridge::setError(const QString &error)
{
    if (m_error == error)
        return;
    m_error = error;
    Q_EMIT errorChanged();
}

void MailBridge::clearError()
{
    setError(QString());
}

void MailBridge::setStatus(const QString &status)
{
    if (m_status == status)
        return;
    m_status = status;
    Q_EMIT statusChanged();
}

void MailBridge::setAccounts(const QVariantList &accounts)
{
    m_accounts = accounts;
    m_accountsLoaded = true;
    // Forget folders of accounts that are gone
    for (const QString &id : m_folderCache.keys()) {
        if (accountById(id).isEmpty())
            m_folderCache.remove(id);
    }
    Q_EMIT accountsChanged();
    Q_EMIT foldersChanged();
}

void MailBridge::setMessage(const QString &id, const QVariantMap &message)
{
    m_currentMessageId = id;
    m_message = message;
    Q_EMIT messageChanged();
}

QVariantMap MailBridge::accountById(const QString &id) const
{
    for (const QVariant &account : m_accounts) {
        const QVariantMap map = account.toMap();
        if (map.value(QStringLiteral("id")).toString() == id)
            return map;
    }
    return {};
}

// ---------- Accounts

void MailBridge::reloadAccounts()
{
    request(QStringLiteral("accounts"), {{QStringLiteral("op"), QStringLiteral("accounts")}}, 30000,
            &MailBridge::onAccounts);
}

void MailBridge::onAccounts(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        setError(error);
        setAccounts({});
        return;
    }
    setAccounts(data.toList());
    QString wanted = m_selectAfterReload;
    m_selectAfterReload.clear();
    auto exists = [this](const QString &id) { return !accountById(id).isEmpty(); };
    if (wanted.isEmpty() || !exists(wanted))
        wanted = exists(m_currentAccountId) ? m_currentAccountId : QString();
    if (wanted.isEmpty() && !m_accounts.isEmpty())
        wanted = m_accounts.first().toMap().value(QStringLiteral("id")).toString();
    if (wanted == m_currentAccountId) {
        Q_EMIT currentAccountChanged();   // its details may have changed
        if (!wanted.isEmpty() && !m_inboxLoaded && !loadingInbox())
            refresh();
    } else {
        setCurrentAccountId(wanted);
    }
    if (!m_checkedOthers) {
        // Folders and new mail of the other accounts, once at startup
        m_checkedOthers = true;
        checkOtherAccounts();
    }
    if (!m_contactsLoaded)
        reloadContacts();
}

QVariantMap MailBridge::currentAccount() const
{
    return accountById(m_currentAccountId);
}

bool MailBridge::currentIsImap() const
{
    return currentAccount().value(QStringLiteral("protocol")).toString() == QLatin1String("imap");
}

void MailBridge::setCurrentAccountId(const QString &id)
{
    selectAccount(id, QStringLiteral("INBOX"));
}

void MailBridge::resetFolderState()
{
    cancel(QStringLiteral("inbox"));
    cancel(QStringLiteral("read"));
    m_limit = 50;
    m_total = 0;
    m_hasMore = false;
    m_inboxLoaded = false;
    m_model->setItems({});
    Q_EMIT messagesChanged();
    setMessage(QString(), {});
}

void MailBridge::selectAccount(const QString &id, const QString &folder)
{
    if (id == m_currentAccountId && folder == m_currentFolder)
        return;
    const bool accountChanged = id != m_currentAccountId;
    resetFolderState();
    m_currentAccountId = id;
    m_currentFolder = folder.isEmpty() ? QStringLiteral("INBOX") : folder;
    if (accountChanged || !m_searchQuery.isEmpty() || m_filter != QLatin1String("all")) {
        m_searchQuery.clear();
        m_filter = QStringLiteral("all");
        Q_EMIT queryChanged();
    }
    setError(QString());
    if (accountChanged) {
        setStatus(QString());
        m_rules.clear();
        m_rulesLoaded = false;
        Q_EMIT rulesChanged();
        Q_EMIT currentAccountChanged();
    }
    Q_EMIT folderChanged();
    Q_EMIT foldersChanged();
    if (!id.isEmpty()) {
        refresh();
        if (accountChanged)
            reloadRules();
    }
}

void MailBridge::openFolder(const QString &accountId, const QString &path)
{
    if (accountById(accountId).isEmpty())
        return;
    // Only folders the server listed (the worker checks again)
    bool known = path == QLatin1String("INBOX");
    for (const QVariant &folder : m_folderCache.value(accountId).toList())
        known |= folder.toMap().value(QStringLiteral("path")).toString() == path;
    if (!known)
        return;
    if (accountId == m_currentAccountId && path == m_currentFolder) {
        closeMessage();
        refresh();
        return;
    }
    selectAccount(accountId, path);
}

void MailBridge::discover(const QString &email)
{
    request(QStringLiteral("discover"),
            {{QStringLiteral("op"), QStringLiteral("discover")}, {QStringLiteral("email"), email.trimmed()}},
            40000, &MailBridge::onDiscover);
}

void MailBridge::onDiscover(bool ok, const QVariant &data, const QString &error)
{
    if (ok)
        Q_EMIT discovered(data.toMap());
    else
        Q_EMIT discoverFailed(error);
}

void MailBridge::saveAccount(const QVariantMap &account, const QString &password)
{
    if (setupBusy())
        return;
    request(QStringLiteral("save"),
            {{QStringLiteral("op"), QStringLiteral("save")},
             {QStringLiteral("account"), account},
             {QStringLiteral("password"), password}},
            150000, &MailBridge::onSave);
}

void MailBridge::signInWithGoogle()
{
    if (setupBusy())
        return;
    // The worker waits up to 3 minutes for the browser, then talks to Google
    request(QStringLiteral("google"), {{QStringLiteral("op"), QStringLiteral("google")}}, 260000,
            &MailBridge::onSave);
}

void MailBridge::cancelSetup()
{
    for (const QString &kind : Kinds)
        cancel(kind);
    setStatus(QString());
}

void MailBridge::onSave(bool ok, const QVariant &data, const QString &error)
{
    setStatus(QString());
    if (!ok) {
        Q_EMIT setupFailed(error);
        return;
    }
    const QVariantMap account = data.toMap();
    m_selectAfterReload = account.value(QStringLiteral("id")).toString();
    setStatus(tr("Conta %1 adicionada.").arg(account.value(QStringLiteral("email")).toString()));
    Q_EMIT accountSaved(account);
    reloadAccounts();
}

void MailBridge::removeAccount(const QString &id)
{
    if (id.isEmpty())
        return;
    request(QStringLiteral("remove"),
            {{QStringLiteral("op"), QStringLiteral("remove")}, {QStringLiteral("id"), id}},
            100000, &MailBridge::onRemove);
}

void MailBridge::onRemove(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        setError(error);
        return;
    }
    setAccounts(data.toList());
    setStatus(tr("Conta removida deste computador."));
    if (accountById(m_currentAccountId).isEmpty())
        setCurrentAccountId(m_accounts.isEmpty() ? QString()
                                                 : m_accounts.first().toMap().value(QStringLiteral("id")).toString());
    else
        Q_EMIT currentAccountChanged();
}

// ---------- Folders and message list

QVariantMap MailBridge::currentFolderInfo() const
{
    for (const QVariant &folder : folders()) {
        const QVariantMap map = folder.toMap();
        if (map.value(QStringLiteral("path")).toString() == m_currentFolder)
            return map;
    }
    if (m_currentFolder == QLatin1String("INBOX"))
        return {{QStringLiteral("path"), m_currentFolder}, {QStringLiteral("name"), m_currentFolder},
                {QStringLiteral("role"), QStringLiteral("inbox")}};
    return {{QStringLiteral("path"), m_currentFolder}, {QStringLiteral("name"), m_currentFolder}};
}

QVariantMap MailBridge::folderByRole(const QString &role) const
{
    for (const QVariant &folder : folders()) {
        const QVariantMap map = folder.toMap();
        if (map.value(QStringLiteral("role")).toString() == role)
            return map;
    }
    return {};
}

QString MailBridge::folderTitle(const QVariantMap &folder) const
{
    const QString role = folder.value(QStringLiteral("role")).toString();
    if (role == QLatin1String("inbox")) return tr("Caixa de entrada");
    if (role == QLatin1String("sent")) return tr("Enviados");
    if (role == QLatin1String("drafts")) return tr("Rascunhos");
    if (role == QLatin1String("trash")) return tr("Lixeira");
    if (role == QLatin1String("junk")) return tr("Spam");
    if (role == QLatin1String("archive")) return tr("Arquivo");
    if (role == QLatin1String("all")) return tr("Todos os e-mails");
    return folder.value(QStringLiteral("name")).toString();
}

QString MailBridge::folderIcon(const QString &role) const
{
    if (role == QLatin1String("inbox")) return QStringLiteral("mail-folder-inbox");
    if (role == QLatin1String("sent")) return QStringLiteral("mail-folder-sent");
    if (role == QLatin1String("drafts")) return QStringLiteral("document-edit");
    if (role == QLatin1String("trash")) return QStringLiteral("trash-empty");
    if (role == QLatin1String("junk")) return QStringLiteral("mail-mark-junk");
    if (role == QLatin1String("archive") || role == QLatin1String("all")) return QStringLiteral("mail-archive");
    return QStringLiteral("folder");
}

QVariantList MailBridge::moveTargets() const
{
    QVariantList out;
    for (const QVariant &folder : folders()) {
        QVariantMap map = folder.toMap();
        if (map.value(QStringLiteral("path")).toString() == m_currentFolder)
            continue;
        map.insert(QStringLiteral("title"), folderTitle(map));
        out.append(map);
    }
    return out;
}

void MailBridge::setFolders(const QString &accountId, const QVariantList &folders)
{
    m_folderCache.insert(accountId, folders);
    Q_EMIT foldersChanged();
}

void MailBridge::adjustUnread(const QString &path, int delta)
{
    QVariantList list = folders();
    for (QVariant &folder : list) {
        QVariantMap map = folder.toMap();
        if (map.value(QStringLiteral("path")).toString() != path)
            continue;
        const int unread = map.value(QStringLiteral("unread")).toInt();
        if (unread >= 0) {
            map.insert(QStringLiteral("unread"), qMax(0, unread + delta));
            folder = map;
            setFolders(m_currentAccountId, list);
        }
        return;
    }
}

void MailBridge::refresh()
{
    list(false);
}

void MailBridge::list(bool silent)
{
    if (m_currentAccountId.isEmpty())
        return;
    if (!silent)
        setError(QString());
    request(QStringLiteral("inbox"),
            {{QStringLiteral("op"), QStringLiteral("list")},
             {QStringLiteral("id"), m_currentAccountId},
             {QStringLiteral("folder"), m_currentFolder},
             {QStringLiteral("limit"), m_limit},
             {QStringLiteral("filter"), m_filter},
             {QStringLiteral("sort"), m_newestFirst ? QStringLiteral("desc") : QStringLiteral("asc")},
             {QStringLiteral("search"), QVariantMap{{QStringLiteral("field"), m_searchField},
                                                    {QStringLiteral("query"), m_searchQuery}}}},
            150000, &MailBridge::onInbox,
            {{QStringLiteral("silent"), silent}, {QStringLiteral("account"), m_currentAccountId},
             {QStringLiteral("folder"), m_currentFolder}});
}

void MailBridge::loadMore()
{
    if (!m_hasMore || loadingInbox())
        return;
    m_limit = qMin(m_limit + 50, 500);
    m_loadingMore = true;
    list(false);
}

void MailBridge::setFilter(const QString &filter)
{
    static const QStringList known = {QStringLiteral("all"), QStringLiteral("unread"), QStringLiteral("flagged"),
                                      QStringLiteral("attachment")};
    if (!known.contains(filter) || filter == m_filter)
        return;
    m_filter = filter;
    m_limit = 50;
    Q_EMIT queryChanged();
    refresh();
}

void MailBridge::setNewestFirst(bool newestFirst)
{
    if (newestFirst == m_newestFirst)
        return;
    m_newestFirst = newestFirst;
    m_limit = 50;
    Q_EMIT queryChanged();
    refresh();
}

void MailBridge::search(const QString &field, const QString &query)
{
    static const QStringList known = {QStringLiteral("text"), QStringLiteral("from"), QStringLiteral("subject")};
    const QString clean = singleLine(query).left(200);
    const QString key = known.contains(field) ? field : QStringLiteral("text");
    if (clean == m_searchQuery && key == m_searchField)
        return;
    m_searchQuery = clean;
    m_searchField = key;
    m_limit = 50;
    Q_EMIT queryChanged();
    refresh();
}

QVariantMap MailBridge::decorate(QVariantMap message) const
{
    const QString sender = message.value(QStringLiteral("sender")).toString();
    const QString date = message.value(QStringLiteral("date")).toString();
    message.insert(QStringLiteral("senderName"), displayName(sender));
    message.insert(QStringLiteral("senderAddress"), addressOf(sender));
    message.insert(QStringLiteral("when"), shortDate(date));
    message.insert(QStringLiteral("fullDate"), longDate(date));
    if (message.value(QStringLiteral("subject")).toString().trimmed().isEmpty())
        message.insert(QStringLiteral("subject"), tr("(Sem assunto)"));
    return message;
}

void MailBridge::onInbox(bool ok, const QVariant &data, const QString &error)
{
    const bool silent = m_context.value(QStringLiteral("silent")).toBool();
    m_loadingMore = false;
    Q_EMIT busyChanged();
    if (!ok) {
        // A failed background refresh keeps what is on screen without nagging
        if (!silent || !m_inboxLoaded)
            setError(error);
        if (!m_inboxLoaded) {
            m_model->setItems({});
            Q_EMIT messagesChanged();
        }
        return;
    }
    const QVariantMap reply = data.toMap();
    const QString accountId = reply.value(QStringLiteral("id")).toString();
    if (accountId != m_currentAccountId || m_context.value(QStringLiteral("folder")).toString() != m_currentFolder)
        return;   // stale
    setFolders(accountId, reply.value(QStringLiteral("folders")).toList());
    QVariantList messages;
    const QVariantList items = reply.value(QStringLiteral("messages")).toList();
    for (const QVariant &item : items)
        messages.append(decorate(item.toMap()));
    m_model->setItems(messages);
    m_total = reply.value(QStringLiteral("total")).toInt();
    m_hasMore = reply.value(QStringLiteral("hasMore")).toBool();
    m_inboxLoaded = true;
    Q_EMIT messagesChanged();
    Q_EMIT foldersChanged();
    if (!silent)
        setStatus(QString());
    notifyNewMail(accountId, reply.value(QStringLiteral("newMail")).toMap());
    // Keep the open message if it is still listed
    if (!m_currentMessageId.isEmpty() && m_model->indexOf(m_currentMessageId) < 0)
        closeMessage();
}

void MailBridge::checkOtherAccounts()
{
    for (const QVariant &account : std::as_const(m_accounts)) {
        const QString id = account.toMap().value(QStringLiteral("id")).toString();
        if (id.isEmpty() || id == m_currentAccountId)
            continue;
        request(QStringLiteral("check-") + id,
                {{QStringLiteral("op"), QStringLiteral("check")}, {QStringLiteral("id"), id}},
                150000, &MailBridge::onCheck);
    }
}

void MailBridge::onCheck(bool ok, const QVariant &data, const QString &)
{
    if (!ok)
        return;   // background work: the account shows its error when opened
    const QVariantMap reply = data.toMap();
    const QString accountId = reply.value(QStringLiteral("id")).toString();
    if (accountById(accountId).isEmpty())
        return;
    setFolders(accountId, reply.value(QStringLiteral("folders")).toList());
    notifyNewMail(accountId, reply.value(QStringLiteral("newMail")).toMap());
}

void MailBridge::notifyNewMail(const QString &accountId, const QVariantMap &newMail)
{
    const int count = newMail.value(QStringLiteral("count")).toInt();
    if (count <= 0)
        return;
    const QVariantList items = newMail.value(QStringLiteral("items")).toList();
    QString summary;
    QStringList lines;
    // Subject and sender only: bodies never leave the worker for this
    if (count == 1 && !items.isEmpty()) {
        const QVariantMap item = items.first().toMap();
        summary = displayName(item.value(QStringLiteral("sender")).toString());
        lines << singleLine(item.value(QStringLiteral("subject")).toString());
    } else {
        summary = tr("%1 novas mensagens").arg(count);
        for (const QVariant &item : items) {
            const QVariantMap map = item.toMap();
            lines << tr("%1: %2").arg(displayName(map.value(QStringLiteral("sender")).toString()),
                                      singleLine(map.value(QStringLiteral("subject")).toString()));
        }
    }
    const QString email = accountById(accountId).value(QStringLiteral("email")).toString();
    if (m_accounts.size() > 1 && !email.isEmpty())
        lines << email;
    for (QString &line : lines)
        line = line.left(160).toHtmlEscaped();   // servers may read the body as markup

    QDBusMessage call = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("/org/freedesktop/Notifications"),
        QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("Notify"));
    call << tr("E-mail") << uint(0) << QStringLiteral("lingmo-mail") << summary.left(120)
         << lines.join(QLatin1Char('\n')) << QStringList()
         << QVariantMap{{QStringLiteral("desktop-entry"), QStringLiteral("lingmo-mail")},
                        {QStringLiteral("category"), QStringLiteral("email.arrived")}}
         << int(-1);
    QDBusConnection::sessionBus().asyncCall(call);
}

// ---------- Reading

void MailBridge::openMessage(const QString &messageId)
{
    if (m_currentAccountId.isEmpty() || messageId.isEmpty())
        return;
    // Show the headers we already have while the body loads
    const QVariantMap header = m_model->at(m_model->indexOf(messageId));
    setMessage(messageId, header);
    request(QStringLiteral("read"),
            {{QStringLiteral("op"), QStringLiteral("read")},
             {QStringLiteral("id"), m_currentAccountId},
             {QStringLiteral("folder"), m_currentFolder},
             {QStringLiteral("message"), messageId}},
            120000, &MailBridge::onRead,
            {{QStringLiteral("account"), m_currentAccountId}, {QStringLiteral("folder"), m_currentFolder},
             {QStringLiteral("message"), messageId}});
}

void MailBridge::closeMessage()
{
    cancel(QStringLiteral("read"));
    setMessage(QString(), {});
}

void MailBridge::onRead(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        setError(error);
        return;
    }
    const QString id = m_context.value(QStringLiteral("message")).toString();
    if (id != m_currentMessageId || m_context.value(QStringLiteral("folder")).toString() != m_currentFolder)
        return;
    const QVariantMap listed = m_model->at(m_model->indexOf(id));
    QVariantMap message = decorate(data.toMap());
    message.insert(QStringLiteral("loaded"), true);
    message.insert(QStringLiteral("starred"), listed.value(QStringLiteral("starred")).toBool());
    message.insert(QStringLiteral("unread"), false);
    message.insert(QStringLiteral("folder"), m_currentFolder);
    // Opening marks it read on the server: mirror that here
    if (listed.value(QStringLiteral("unread")).toBool()) {
        m_model->update(id, {{QStringLiteral("unread"), false}});
        adjustUnread(m_currentFolder, -1);
    }
    setMessage(m_currentMessageId, message);
}

// ---------- Actions

QStringList MailBridge::idsBetween(int from, int to) const
{
    QStringList ids;
    if (from > to)
        std::swap(from, to);
    for (int row = qMax(0, from); row <= to && row < m_model->count(); ++row)
        ids << m_model->at(row).value(QStringLiteral("id")).toString();
    return ids;
}

void MailBridge::act(const QString &action, const QStringList &ids, const QVariantMap &extra)
{
    if (m_currentAccountId.isEmpty() || ids.isEmpty() || !currentIsImap())
        return;
    QVariantMap payload = extra;
    payload.insert(QStringLiteral("op"), QStringLiteral("act"));
    payload.insert(QStringLiteral("id"), m_currentAccountId);
    payload.insert(QStringLiteral("folder"), m_currentFolder);
    payload.insert(QStringLiteral("action"), action);
    payload.insert(QStringLiteral("uids"), ids);
    request(QStringLiteral("act-%1").arg(++m_serial), payload, 120000, &MailBridge::onAct,
            {{QStringLiteral("action"), action}, {QStringLiteral("ids"), ids},
             {QStringLiteral("account"), m_currentAccountId}, {QStringLiteral("folder"), m_currentFolder}});
}

void MailBridge::markRead(const QStringList &ids, bool read)
{
    if (!currentIsImap())
        return;
    int delta = 0;
    for (const QString &id : ids) {
        const QVariantMap item = m_model->at(m_model->indexOf(id));
        if (!item.isEmpty() && item.value(QStringLiteral("unread")).toBool() == read) {
            delta += read ? -1 : 1;
            m_model->update(id, {{QStringLiteral("unread"), !read}});
        }
    }
    adjustUnread(m_currentFolder, delta);
    if (ids.contains(m_currentMessageId)) {
        m_message.insert(QStringLiteral("unread"), !read);
        Q_EMIT messageChanged();
    }
    act(read ? QStringLiteral("read") : QStringLiteral("unread"), ids);
}

void MailBridge::setStarred(const QStringList &ids, bool starred)
{
    if (!currentIsImap())
        return;
    for (const QString &id : ids)
        m_model->update(id, {{QStringLiteral("starred"), starred}});
    if (ids.contains(m_currentMessageId)) {
        m_message.insert(QStringLiteral("starred"), starred);
        Q_EMIT messageChanged();
    }
    act(starred ? QStringLiteral("star") : QStringLiteral("unstar"), ids);
}

void MailBridge::archive(const QStringList &ids)
{
    if (!currentIsImap())
        return;
    if (folderByRole(QStringLiteral("archive")).isEmpty() && folderByRole(QStringLiteral("all")).isEmpty()) {
        setError(tr("Esta conta não tem uma pasta de arquivo."));
        return;
    }
    if (ids.contains(m_currentMessageId))
        closeMessage();
    m_model->remove(ids);
    act(QStringLiteral("archive"), ids);
}

void MailBridge::moveMessages(const QStringList &ids, const QString &target)
{
    if (!currentIsImap() || target == m_currentFolder)
        return;
    if (ids.contains(m_currentMessageId))
        closeMessage();
    m_model->remove(ids);
    act(QStringLiteral("move"), ids, {{QStringLiteral("target"), target}});
}

void MailBridge::deleteMessages(const QStringList &ids, bool permanent)
{
    if (!currentIsImap() || ids.isEmpty())
        return;
    const QVariantMap trash = folderByRole(QStringLiteral("trash"));
    const bool destroys = trash.isEmpty() || trash.value(QStringLiteral("path")).toString() == m_currentFolder;
    if (destroys && !permanent) {
        Q_EMIT deleteNeedsConfirm(ids);
        return;
    }
    if (ids.contains(m_currentMessageId))
        closeMessage();
    m_model->remove(ids);
    act(QStringLiteral("delete"), ids, {{QStringLiteral("permanent"), destroys && permanent}});
}

void MailBridge::onAct(bool ok, const QVariant &data, const QString &error)
{
    const bool here = m_context.value(QStringLiteral("account")).toString() == m_currentAccountId
            && m_context.value(QStringLiteral("folder")).toString() == m_currentFolder;
    if (!ok)
        setError(error);
    else if (data.toMap().value(QStringLiteral("confirm")).toBool() && here)
        Q_EMIT deleteNeedsConfirm(m_context.value(QStringLiteral("ids")).toStringList());
    // Back in sync with the server (counts, and anything we guessed wrong). A listing
    // already running may predate this action, so it is replaced.
    if (here)
        list(true);
}

// ---------- Sending

void MailBridge::send(const QVariantMap &draft)
{
    if (sending())
        return;
    if (m_currentAccountId.isEmpty()) {
        Q_EMIT sendFailed(tr("Adicione uma conta antes de enviar."));
        return;
    }
    // Tolerate a trailing comma or semicolons between recipients
    auto recipients = [](QString value) {
        value = singleLine(value);
        value.replace(QLatin1Char(';'), QLatin1Char(','));
        QStringList parts = value.split(QLatin1Char(','), Qt::SkipEmptyParts);
        for (QString &part : parts)
            part = part.trimmed();
        parts.removeAll(QString());
        return parts.join(QStringLiteral(", "));
    };
    QVariantMap clean;
    clean.insert(QStringLiteral("to"), recipients(draft.value(QStringLiteral("to")).toString()));
    clean.insert(QStringLiteral("cc"), recipients(draft.value(QStringLiteral("cc")).toString()));
    clean.insert(QStringLiteral("subject"), singleLine(draft.value(QStringLiteral("subject")).toString()));
    clean.insert(QStringLiteral("body"), draft.value(QStringLiteral("body")).toString());
    clean.insert(QStringLiteral("inReplyTo"), singleLine(draft.value(QStringLiteral("inReplyTo")).toString()));
    clean.insert(QStringLiteral("references"), singleLine(draft.value(QStringLiteral("references")).toString()));
    if (clean.value(QStringLiteral("to")).toString().isEmpty()) {
        Q_EMIT sendFailed(tr("Informe pelo menos um destinatário."));
        return;
    }
    request(QStringLiteral("send"),
            {{QStringLiteral("op"), QStringLiteral("send")},
             {QStringLiteral("id"), m_currentAccountId},
             {QStringLiteral("draft"), clean}},
            150000, &MailBridge::onSend);
}

void MailBridge::onSend(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        Q_EMIT sendFailed(error);
        return;
    }
    const QStringList refused = data.toMap().value(QStringLiteral("refused")).toStringList();
    if (refused.isEmpty())
        setStatus(tr("Mensagem enviada."));
    else
        setStatus(tr("Mensagem enviada, mas recusada para: %1").arg(refused.join(QStringLiteral(", "))));
    Q_EMIT sent();
    reloadContacts();   // recipients are collected by the worker
}

void MailBridge::sendCalendarReply(const QString &accountId, const QString &to, const QString &subject,
                                   const QString &icsText)
{
    if (accountById(accountId).isEmpty()) {
        Q_EMIT calendarReplyFailed(tr("Selecione uma conta."));
        return;
    }
    if (icsText.toUtf8().size() > 256 * 1024) {
        Q_EMIT calendarReplyFailed(tr("O convite é grande demais."));
        return;
    }
    request(QStringLiteral("calreply-%1").arg(++m_serial),
            {{QStringLiteral("op"), QStringLiteral("calendarReply")},
             {QStringLiteral("id"), accountId},
             {QStringLiteral("to"), singleLine(to)},
             {QStringLiteral("subject"), singleLine(subject)},
             {QStringLiteral("ics"), icsText}},
            150000, &MailBridge::onCalendarReply);
}

void MailBridge::onCalendarReply(bool ok, const QVariant &, const QString &error)
{
    if (!ok) {
        Q_EMIT calendarReplyFailed(error);
        return;
    }
    setStatus(tr("Resposta ao convite enviada."));
    Q_EMIT calendarReplySent();
}

// ---------- Contacts

void MailBridge::reloadContacts()
{
    request(QStringLiteral("contacts"), {{QStringLiteral("op"), QStringLiteral("contacts")}}, 30000,
            &MailBridge::onContacts);
}

void MailBridge::onContacts(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        setError(error);
        return;
    }
    m_contacts = data.toList();
    m_contactsLoaded = true;
    Q_EMIT contactsChanged();
}

void MailBridge::saveContact(const QVariantMap &contact)
{
    QVariantMap clean;
    clean.insert(QStringLiteral("id"), contact.value(QStringLiteral("id")).toString());
    clean.insert(QStringLiteral("name"), singleLine(contact.value(QStringLiteral("name")).toString()));
    clean.insert(QStringLiteral("phone"), singleLine(contact.value(QStringLiteral("phone")).toString()));
    clean.insert(QStringLiteral("notes"), contact.value(QStringLiteral("notes")).toString());
    const QVariant emails = contact.value(QStringLiteral("emails"));
    clean.insert(QStringLiteral("emails"), emails.typeId() == QMetaType::QString
                     ? QVariant(singleLine(emails.toString())) : QVariant(emails.toStringList()));
    request(QStringLiteral("contact-%1").arg(++m_serial),
            {{QStringLiteral("op"), QStringLiteral("saveContact")}, {QStringLiteral("contact"), clean}},
            30000, &MailBridge::onContactSaved, {{QStringLiteral("saved"), true}});
}

void MailBridge::deleteContact(const QString &id)
{
    request(QStringLiteral("contact-%1").arg(++m_serial),
            {{QStringLiteral("op"), QStringLiteral("deleteContact")}, {QStringLiteral("contactId"), id}},
            30000, &MailBridge::onContactSaved);
}

void MailBridge::onContactSaved(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        Q_EMIT contactFailed(error);
        setStatus(error);
        return;
    }
    m_contacts = data.toList();
    m_contactsLoaded = true;
    Q_EMIT contactsChanged();
    setStatus(m_context.value(QStringLiteral("saved")).toBool() ? tr("Contato salvo.") : tr("Contato apagado."));
    Q_EMIT contactSaved();
}

QVariantList MailBridge::contactSuggestions(const QString &text, int limit) const
{
    const QString needle = text.trimmed().toCaseFolded();
    QVariantList saved, collected;
    if (needle.isEmpty())
        return {};
    for (const QVariant &entry : m_contacts) {
        const QVariantMap contact = entry.toMap();
        const QString name = contact.value(QStringLiteral("name")).toString();
        for (const QString &address : contact.value(QStringLiteral("emails")).toStringList()) {
            if (!name.toCaseFolded().contains(needle) && !address.toCaseFolded().contains(needle))
                continue;
            QString label = address;
            if (!name.isEmpty()) {
                // Quote names that would break the recipient list
                const bool plain = !name.contains(QRegularExpression(QStringLiteral("[,;<>\"@()]")));
                label = (plain ? name : QLatin1Char('"') + QString(name).remove(QLatin1Char('"')) + QLatin1Char('"'))
                        + QStringLiteral(" <") + address + QLatin1Char('>');
            }
            const QVariantMap item{{QStringLiteral("name"), name}, {QStringLiteral("address"), address},
                                   {QStringLiteral("recipient"), label},
                                   {QStringLiteral("collected"), contact.value(QStringLiteral("collected"))}};
            (contact.value(QStringLiteral("collected")).toBool() ? collected : saved).append(item);
        }
    }
    QVariantList out = saved + collected;
    return out.mid(0, qMax(1, limit));
}

// ---------- Rules

void MailBridge::reloadRules()
{
    if (m_currentAccountId.isEmpty())
        return;
    request(QStringLiteral("rules"),
            {{QStringLiteral("op"), QStringLiteral("rules")}, {QStringLiteral("id"), m_currentAccountId}},
            30000, &MailBridge::onRules, {{QStringLiteral("account"), m_currentAccountId}});
}

void MailBridge::onRules(bool ok, const QVariant &data, const QString &error)
{
    if (m_context.value(QStringLiteral("account")).toString() != m_currentAccountId)
        return;
    if (!ok) {
        setError(error);
        return;
    }
    m_rules = data.toList();
    m_rulesLoaded = true;
    Q_EMIT rulesChanged();
}

void MailBridge::saveRules(const QVariantList &rules)
{
    if (m_currentAccountId.isEmpty())
        return;
    request(QStringLiteral("rules-save"),
            {{QStringLiteral("op"), QStringLiteral("saveRules")}, {QStringLiteral("id"), m_currentAccountId},
             {QStringLiteral("rules"), rules}},
            30000, &MailBridge::onRulesSaved, {{QStringLiteral("account"), m_currentAccountId}});
}

void MailBridge::onRulesSaved(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        Q_EMIT rulesFailed(error);
        return;
    }
    if (m_context.value(QStringLiteral("account")).toString() == m_currentAccountId) {
        m_rules = data.toList();
        m_rulesLoaded = true;
        Q_EMIT rulesChanged();
    }
    Q_EMIT rulesSaved();
}

void MailBridge::applyRulesNow()
{
    if (m_currentAccountId.isEmpty() || applyingRules())
        return;
    setError(QString());
    request(QStringLiteral("applyRules"),
            {{QStringLiteral("op"), QStringLiteral("applyRules")}, {QStringLiteral("id"), m_currentAccountId}},
            300000, &MailBridge::onApplyRules, {{QStringLiteral("account"), m_currentAccountId}});
}

void MailBridge::onApplyRules(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        setError(error);
        return;
    }
    const int matched = data.toMap().value(QStringLiteral("matched")).toInt();
    if (matched == 0)
        setStatus(tr("Nenhuma mensagem da caixa de entrada corresponde às regras."));
    else if (matched == 1)
        setStatus(tr("Regras aplicadas a 1 mensagem."));
    else
        setStatus(tr("Regras aplicadas a %1 mensagens.").arg(matched));
    if (m_context.value(QStringLiteral("account")).toString() == m_currentAccountId && !loadingInbox())
        list(true);
}

// ---------- Drafts

QVariantMap MailBridge::replyDraft() const
{
    const QVariantMap &m = m_message;
    const QString sender = m.value(QStringLiteral("sender")).toString();
    const QString replyTo = m.value(QStringLiteral("replyTo")).toString();
    QString subject = singleLine(m.value(QStringLiteral("subject")).toString());
    static const QRegularExpression replied(QStringLiteral("^(re|res)\\s*:"),
                                            QRegularExpression::CaseInsensitiveOption);
    if (!replied.match(subject).hasMatch())
        subject = tr("Re: %1").arg(subject);

    QString quoted;
    const QStringList lines = m.value(QStringLiteral("body")).toString().split(QLatin1Char('\n'));
    for (QString line : lines) {
        if (line.endsWith(QLatin1Char('\r')))
            line.chop(1);
        quoted += (line.startsWith(QLatin1Char('>')) ? QStringLiteral(">") : QStringLiteral("> ")) + line
                + QLatin1Char('\n');
    }
    const QString date = m.value(QStringLiteral("fullDate")).toString();
    const QString intro = date.isEmpty() ? tr("%1 escreveu:").arg(displayName(sender))
                                         : tr("Em %1, %2 escreveu:").arg(date, displayName(sender));

    const QString messageId = m.value(QStringLiteral("messageId")).toString();
    QString references = m.value(QStringLiteral("references")).toString();
    if (!messageId.isEmpty())
        references = (references + QLatin1Char(' ') + messageId).trimmed();

    return {
        {QStringLiteral("to"), singleLine(replyTo.trimmed().isEmpty() ? sender : replyTo)},
        {QStringLiteral("cc"), QString()},
        {QStringLiteral("subject"), subject},
        {QStringLiteral("body"), QStringLiteral("\n\n") + intro + QLatin1Char('\n') + quoted},
        {QStringLiteral("inReplyTo"), messageId},
        {QStringLiteral("references"), references},
    };
}

QVariantMap MailBridge::forwardDraft() const
{
    const QVariantMap &m = m_message;
    QString subject = singleLine(m.value(QStringLiteral("subject")).toString());
    static const QRegularExpression forwarded(QStringLiteral("^(fwd?|enc)\\s*:"),
                                              QRegularExpression::CaseInsensitiveOption);
    if (!forwarded.match(subject).hasMatch())
        subject = tr("Fwd: %1").arg(subject);
    QString body = QStringLiteral("\n\n") + tr("---------- Mensagem encaminhada ----------") + QLatin1Char('\n')
            + tr("De: %1").arg(m.value(QStringLiteral("sender")).toString()) + QLatin1Char('\n')
            + tr("Data: %1").arg(m.value(QStringLiteral("fullDate")).toString()) + QLatin1Char('\n')
            + tr("Assunto: %1").arg(m.value(QStringLiteral("subject")).toString()) + QLatin1Char('\n')
            + tr("Para: %1").arg(m.value(QStringLiteral("to")).toString()) + QLatin1Char('\n');
    const QString cc = m.value(QStringLiteral("cc")).toString();
    if (!cc.isEmpty())
        body += tr("Cc: %1").arg(cc) + QLatin1Char('\n');
    body += QLatin1Char('\n') + m.value(QStringLiteral("body")).toString();
    return {
        {QStringLiteral("to"), QString()},
        {QStringLiteral("cc"), QString()},
        {QStringLiteral("subject"), subject},
        {QStringLiteral("body"), body},
        {QStringLiteral("inReplyTo"), QString()},
        {QStringLiteral("references"), QString()},
    };
}

// ---------- Display helpers

QString MailBridge::displayName(const QString &address)
{
    const QString value = singleLine(address);
    const qsizetype open = value.lastIndexOf(QLatin1Char('<'));
    if (open > 0) {
        QString name = value.left(open).trimmed();
        if (name.size() >= 2 && name.startsWith(QLatin1Char('"')) && name.endsWith(QLatin1Char('"')))
            name = name.mid(1, name.size() - 2).trimmed();
        if (!name.isEmpty())
            return name;
    }
    const QString bare = addressOf(value);
    return bare.isEmpty() ? value : bare;
}

QString MailBridge::addressOf(const QString &address)
{
    const QString value = singleLine(address);
    const qsizetype open = value.lastIndexOf(QLatin1Char('<'));
    const qsizetype close = value.lastIndexOf(QLatin1Char('>'));
    if (open >= 0 && close > open)
        return value.mid(open + 1, close - open - 1).trimmed();
    return value;
}

QString MailBridge::shortDate(const QString &rfc2822)
{
    const QDateTime date = parseDate(rfc2822);
    if (!date.isValid())
        return QString();
    const QLocale locale;
    const QDate today = QDate::currentDate();
    if (date.date() == today)
        return locale.toString(date.time(), QStringLiteral("HH:mm"));
    if (date.date() == today.addDays(-1))
        return tr("Ontem");
    if (date.date().year() == today.year())
        return locale.toString(date.date(), QStringLiteral("d MMM"));
    return locale.toString(date.date(), QLocale::ShortFormat);
}

QString MailBridge::longDate(const QString &rfc2822)
{
    const QDateTime date = parseDate(rfc2822);
    if (!date.isValid())
        return rfc2822;
    return QLocale().toString(date, QStringLiteral("ddd, d MMM yyyy HH:mm"));
}
