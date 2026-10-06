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

#include <QDateTime>
#include <QDesktopServices>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QProcess>
#include <QRegularExpression>
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

MailBridge::MailBridge(QObject *parent)
    : QObject(parent)
{
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

void MailBridge::request(const QString &kind, const QVariantMap &payload, int timeoutMs, Handler handler)
{
    cancel(kind);

    QByteArray line = QJsonDocument(QJsonObject::fromVariantMap(payload)).toJson(QJsonDocument::Compact);
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
    (this->*job.handler)(ok, data, error);
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
    Q_EMIT accountsChanged();
}

void MailBridge::setMessages(const QVariantList &messages, bool loaded)
{
    m_messages = messages;
    m_inboxLoaded = loaded;
    Q_EMIT messagesChanged();
}

void MailBridge::setMessage(const QString &id, const QVariantMap &message)
{
    m_currentMessageId = id;
    m_message = message;
    Q_EMIT messageChanged();
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
    auto exists = [this](const QString &id) {
        for (const QVariant &account : std::as_const(m_accounts)) {
            if (account.toMap().value(QStringLiteral("id")).toString() == id)
                return true;
        }
        return false;
    };
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
}

QVariantMap MailBridge::currentAccount() const
{
    for (const QVariant &account : m_accounts) {
        const QVariantMap map = account.toMap();
        if (map.value(QStringLiteral("id")).toString() == m_currentAccountId)
            return map;
    }
    return {};
}

void MailBridge::setCurrentAccountId(const QString &id)
{
    if (id == m_currentAccountId)
        return;
    cancel(QStringLiteral("inbox"));
    cancel(QStringLiteral("read"));
    m_currentAccountId = id;
    setMessages({}, false);
    setMessage(QString(), {});
    setError(QString());
    setStatus(QString());
    Q_EMIT currentAccountChanged();
    if (!id.isEmpty())
        refresh();
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
    bool stillThere = false;
    for (const QVariant &account : std::as_const(m_accounts))
        stillThere |= account.toMap().value(QStringLiteral("id")).toString() == m_currentAccountId;
    if (!stillThere)
        setCurrentAccountId(m_accounts.isEmpty() ? QString()
                                                 : m_accounts.first().toMap().value(QStringLiteral("id")).toString());
    else
        Q_EMIT currentAccountChanged();
}

// ---------- Inbox and messages

void MailBridge::refresh()
{
    if (m_currentAccountId.isEmpty())
        return;
    setError(QString());
    request(QStringLiteral("inbox"),
            {{QStringLiteral("op"), QStringLiteral("inbox")}, {QStringLiteral("id"), m_currentAccountId}},
            120000, &MailBridge::onInbox);
}

void MailBridge::onInbox(bool ok, const QVariant &data, const QString &error)
{
    if (!ok) {
        setError(error);
        if (!m_inboxLoaded)
            setMessages({}, false);
        return;
    }
    QVariantList messages;
    const QVariantList items = data.toList();
    for (const QVariant &item : items) {
        QVariantMap message = item.toMap();
        const QString sender = message.value(QStringLiteral("sender")).toString();
        const QString date = message.value(QStringLiteral("date")).toString();
        message.insert(QStringLiteral("senderName"), displayName(sender));
        message.insert(QStringLiteral("when"), shortDate(date));
        message.insert(QStringLiteral("fullDate"), longDate(date));
        if (message.value(QStringLiteral("subject")).toString().trimmed().isEmpty())
            message.insert(QStringLiteral("subject"), tr("(Sem assunto)"));
        messages.append(message);
    }
    setMessages(messages, true);
    setStatus(QString());
    // Keep the open message if it is still in the inbox
    if (!m_currentMessageId.isEmpty()) {
        bool found = false;
        for (const QVariant &message : std::as_const(m_messages))
            found |= message.toMap().value(QStringLiteral("id")).toString() == m_currentMessageId;
        if (!found)
            closeMessage();
    }
}

void MailBridge::openMessage(const QString &messageId)
{
    if (m_currentAccountId.isEmpty() || messageId.isEmpty())
        return;
    // Show the headers we already have while the body loads
    QVariantMap header;
    for (const QVariant &message : std::as_const(m_messages)) {
        if (message.toMap().value(QStringLiteral("id")).toString() == messageId) {
            header = message.toMap();
            break;
        }
    }
    setMessage(messageId, header);
    request(QStringLiteral("read"),
            {{QStringLiteral("op"), QStringLiteral("read")},
             {QStringLiteral("id"), m_currentAccountId},
             {QStringLiteral("message"), messageId}},
            120000, &MailBridge::onRead);
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
    QVariantMap message = data.toMap();
    const QString sender = message.value(QStringLiteral("sender")).toString();
    const QString date = message.value(QStringLiteral("date")).toString();
    message.insert(QStringLiteral("senderName"), displayName(sender));
    message.insert(QStringLiteral("senderAddress"), addressOf(sender));
    message.insert(QStringLiteral("fullDate"), longDate(date));
    message.insert(QStringLiteral("loaded"), true);
    if (message.value(QStringLiteral("subject")).toString().trimmed().isEmpty())
        message.insert(QStringLiteral("subject"), tr("(Sem assunto)"));
    setMessage(m_currentMessageId, message);
}

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
