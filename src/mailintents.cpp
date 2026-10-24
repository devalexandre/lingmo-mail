#include "mailintents.h"

#include <LingmoIntents/intentschema.h>
#include <LingmoIntents/intentservice.h>

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QStandardPaths>
#include <QTimer>
#include <functional>

using LingmoIntents::IntentCall;
using LingmoIntents::IntentResult;

namespace {

using Reply = std::function<void(bool ok, const QVariant &data, const QString &error)>;

QString mailBackend()
{
    const QString env = qEnvironmentVariable("LINGMO_MAIL_BACKEND");
    return !env.isEmpty() && QFileInfo(env).isFile() ? env : QStringLiteral(MAIL_BACKEND);
}

QString calendarBackend()
{
    const QString env = qEnvironmentVariable("LINGMO_CALENDAR_BACKEND");
    if (!env.isEmpty() && QFileInfo(env).isFile())
        return env;
    const QString mail = qEnvironmentVariable("LINGMO_MAIL_BACKEND");
    if (!mail.isEmpty()) {
        const QString sibling = QFileInfo(mail).absolutePath() + QStringLiteral("/calendar_backend.py");
        if (QFileInfo(sibling).isFile())
            return sibling;
    }
    return QStringLiteral(CALENDAR_BACKEND);
}

// One JSON request on stdin, one JSON line back ({"ok", "data" | "error"})
void callWorker(const QString &backend, const QVariantMap &request, int timeoutMs, const Reply &reply)
{
    QString python = QStringLiteral("/usr/bin/python3");
    if (!QFileInfo(python).isExecutable())
        python = QStandardPaths::findExecutable(QStringLiteral("python3"));
    if (python.isEmpty() || !QFileInfo(backend).isFile()) {
        reply(false, {}, QObject::tr("Um componente do E-mail está faltando. Reinstale o aplicativo."));
        return;
    }
    auto *process = new QProcess;
    process->setProgram(python);
    process->setArguments({QStringLiteral("-I"), backend});
    process->setStandardErrorFile(QProcess::nullDevice());
    auto *timer = new QTimer(process);
    timer->setSingleShot(true);
    QObject::connect(timer, &QTimer::timeout, process, [process] { process->kill(); });
    QObject::connect(process, &QProcess::finished, process, [process, reply] {
        process->deleteLater();
        const QByteArray line = process->readAllStandardOutput().split('\n').value(0);
        const QJsonObject obj = QJsonDocument::fromJson(line).object();
        if (obj.isEmpty()) {
            reply(false, {}, QObject::tr("Resposta inválida do E-mail."));
            return;
        }
        if (!obj.value(QStringLiteral("ok")).toBool()) {
            reply(false, {}, obj.value(QStringLiteral("error")).toString(QObject::tr("O E-mail recusou o pedido.")));
            return;
        }
        reply(true, obj.value(QStringLiteral("data")).toVariant(), QString());
    });
    QObject::connect(process, &QProcess::errorOccurred, process, [process, reply](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            process->deleteLater();
            reply(false, {}, QObject::tr("Não foi possível abrir o E-mail."));
        }
    });
    process->start();
    process->write(QJsonDocument(QJsonObject::fromVariantMap(request)).toJson(QJsonDocument::Compact) + '\n');
    process->closeWriteChannel();
    timer->start(timeoutMs);
}

void mailCall(const QVariantMap &request, const Reply &reply, int timeoutMs = 60000)
{
    callWorker(mailBackend(), request, timeoutMs, reply);
}

// Resolves "account" (id, address or empty = first) and continues with the account map
void withAccount(const IntentCall &call, const std::function<void(const QVariantMap &account)> &next)
{
    mailCall({{QStringLiteral("op"), QStringLiteral("accounts")}}, [call, next](bool ok, const QVariant &data, const QString &error) {
        if (!ok)
            return call.finish(IntentResult::failed(error));
        const QVariantList accounts = data.toList();
        if (accounts.isEmpty())
            return call.finish(IntentResult::failed(QObject::tr("Nenhuma conta de e-mail no Lingmo Mail.")));
        const QString ref = call.params().value(QStringLiteral("account")).toString().trimmed().toLower();
        for (const QVariant &a : accounts) {
            const QVariantMap acc = a.toMap();
            if (ref.isEmpty() || acc.value(QStringLiteral("id")).toString().toLower() == ref
                || acc.value(QStringLiteral("email")).toString().toLower() == ref)
                return next(acc);
        }
        call.finish(IntentResult::failed(QObject::tr("Conta de e-mail não encontrada: %1").arg(ref)));
    });
}

QVariantMap readRequest(const QVariantMap &account, const IntentCall &call)
{
    return {{QStringLiteral("op"), QStringLiteral("read")},
            {QStringLiteral("id"), account.value(QStringLiteral("id"))},
            {QStringLiteral("message"), call.params().value(QStringLiteral("message"))},
            {QStringLiteral("folder"), call.params().value(QStringLiteral("folder"))},
            {QStringLiteral("peek"), true}};
}

void send(const IntentCall &call)
{
    withAccount(call, [call](const QVariantMap &account) {
        const QVariantMap p = call.params();
        const QVariantMap draft{{QStringLiteral("to"), p.value(QStringLiteral("to"))},
                                {QStringLiteral("cc"), p.value(QStringLiteral("cc")).toString()},
                                {QStringLiteral("subject"), p.value(QStringLiteral("subject")).toString().simplified()},
                                {QStringLiteral("body"), p.value(QStringLiteral("body"))}};
        mailCall({{QStringLiteral("op"), QStringLiteral("send")}, {QStringLiteral("id"), account.value(QStringLiteral("id"))},
                  {QStringLiteral("draft"), draft}},
                 [call, draft, account](bool ok, const QVariant &, const QString &error) {
                     if (!ok)
                         return call.finish(IntentResult::failed(error));
                     call.finish(IntentResult::ok({{QStringLiteral("to"), draft.value(QStringLiteral("to"))},
                                                   {QStringLiteral("subject"), draft.value(QStringLiteral("subject"))},
                                                   {QStringLiteral("account"), account.value(QStringLiteral("email"))}}));
                 });
    });
}

void reply(const IntentCall &call)
{
    withAccount(call, [call](const QVariantMap &account) {
        mailCall(readRequest(account, call), [call, account](bool ok, const QVariant &data, const QString &error) {
            if (!ok)
                return call.finish(IntentResult::failed(error));
            const QVariantMap original = data.toMap();
            QString subject = original.value(QStringLiteral("subject")).toString();
            if (!subject.startsWith(QLatin1String("re:"), Qt::CaseInsensitive)
                && !subject.startsWith(QLatin1String("res:"), Qt::CaseInsensitive))
                subject = QStringLiteral("Re: ") + subject;
            QString to = original.value(QStringLiteral("replyTo")).toString();
            if (to.isEmpty())
                to = original.value(QStringLiteral("sender")).toString();
            QStringList quoted;
            const QStringList lines = original.value(QStringLiteral("body")).toString().split(QLatin1Char('\n'));
            for (int i = 0; i < lines.size() && i < 200; ++i)
                quoted << QStringLiteral("> ") + lines.at(i);
            const QString body = call.params().value(QStringLiteral("body")).toString().trimmed() + QStringLiteral("\n\n")
                + QObject::tr("Em %1, %2 escreveu:").arg(original.value(QStringLiteral("date")).toString(),
                                                        original.value(QStringLiteral("sender")).toString())
                + QLatin1Char('\n') + quoted.join(QLatin1Char('\n'));
            QVariantMap draft{{QStringLiteral("to"), to}, {QStringLiteral("cc"), QString()},
                              {QStringLiteral("subject"), subject.simplified().left(300)}, {QStringLiteral("body"), body}};
            const QString messageId = original.value(QStringLiteral("messageId")).toString();
            if (!messageId.isEmpty()) {
                draft.insert(QStringLiteral("inReplyTo"), messageId);
                const QString refs = original.value(QStringLiteral("references")).toString();
                draft.insert(QStringLiteral("references"), refs.isEmpty() ? messageId : refs + QLatin1Char(' ') + messageId);
            }
            mailCall({{QStringLiteral("op"), QStringLiteral("send")}, {QStringLiteral("id"), account.value(QStringLiteral("id"))},
                      {QStringLiteral("draft"), draft}},
                     [call, draft](bool ok, const QVariant &, const QString &error) {
                         if (!ok)
                             return call.finish(IntentResult::failed(error));
                         call.finish(IntentResult::ok({{QStringLiteral("to"), draft.value(QStringLiteral("to"))},
                                                       {QStringLiteral("subject"), draft.value(QStringLiteral("subject"))}}));
                     });
        });
    });
}

void search(const IntentCall &call)
{
    withAccount(call, [call](const QVariantMap &account) {
        const QVariantMap p = call.params();
        QVariantMap req{{QStringLiteral("op"), QStringLiteral("list")},
                        {QStringLiteral("id"), account.value(QStringLiteral("id"))},
                        {QStringLiteral("folder"), p.value(QStringLiteral("folder"))},
                        {QStringLiteral("limit"), p.value(QStringLiteral("limit"))},
                        {QStringLiteral("filter"), p.value(QStringLiteral("unreadOnly")).toBool() ? QStringLiteral("unread") : QStringLiteral("all")},
                        {QStringLiteral("sort"), QStringLiteral("desc")},
                        {QStringLiteral("checkNew"), false}};   // never runs the user's filter rules
        if (!p.value(QStringLiteral("query")).toString().isEmpty())
            req.insert(QStringLiteral("search"), QVariantMap{{QStringLiteral("field"), p.value(QStringLiteral("field"))},
                                                             {QStringLiteral("query"), p.value(QStringLiteral("query"))}});
        mailCall(req, [call](bool ok, const QVariant &data, const QString &error) {
            if (!ok)
                return call.finish(IntentResult::failed(error));
            QVariantList out;
            QStringList lines;
            for (const QVariant &v : data.toMap().value(QStringLiteral("messages")).toList()) {
                const QVariantMap m = v.toMap();
                const QVariantMap item{{QStringLiteral("id"), m.value(QStringLiteral("id")).toString()},
                                       {QStringLiteral("subject"), m.value(QStringLiteral("subject"))},
                                       {QStringLiteral("sender"), m.value(QStringLiteral("sender"))},
                                       {QStringLiteral("date"), m.value(QStringLiteral("date"))},
                                       {QStringLiteral("unread"), m.value(QStringLiteral("unread")).toBool()},
                                       {QStringLiteral("hasAttachment"), m.value(QStringLiteral("hasAttachment")).toBool()}};
                out << item;
                lines << QStringLiteral("[%1] %2 — %3").arg(item.value(QStringLiteral("id")).toString(),
                                                            item.value(QStringLiteral("sender")).toString(),
                                                            item.value(QStringLiteral("subject")).toString());
            }
            call.finish(IntentResult::ok({{QStringLiteral("count"), out.size()},
                                          {QStringLiteral("messages"), out},
                                          {QStringLiteral("text"), lines.join(QLatin1Char('\n'))}}));
        });
    });
}

void read(const IntentCall &call)
{
    withAccount(call, [call](const QVariantMap &account) {
        mailCall(readRequest(account, call), [call](bool ok, const QVariant &data, const QString &error) {
            if (!ok)
                return call.finish(IntentResult::failed(error));
            const QVariantMap m = data.toMap();
            QStringList names;
            for (const QVariant &a : m.value(QStringLiteral("attachments")).toList())
                names << (a.typeId() == QMetaType::QVariantMap ? a.toMap().value(QStringLiteral("name")).toString() : a.toString());
            call.finish(IntentResult::ok({{QStringLiteral("subject"), m.value(QStringLiteral("subject"))},
                                          {QStringLiteral("sender"), m.value(QStringLiteral("sender"))},
                                          {QStringLiteral("date"), m.value(QStringLiteral("date"))},
                                          {QStringLiteral("body"), m.value(QStringLiteral("body")).toString().left(100000)},
                                          {QStringLiteral("attachments"), names}}));
        });
    });
}

void saveAttachments(const IntentCall &call)
{
    withAccount(call, [call](const QVariantMap &account) {
        const QString dest = call.params().value(QStringLiteral("dest")).toString();
        QDir().mkpath(dest);
        const QFileInfo fi(dest);
        if (!fi.isDir() || fi.isSymLink())
            return call.finish(IntentResult::failed(QObject::tr("Pasta inválida: %1").arg(dest)));
        mailCall({{QStringLiteral("op"), QStringLiteral("saveAttachments")}, {QStringLiteral("id"), account.value(QStringLiteral("id"))},
                  {QStringLiteral("message"), call.params().value(QStringLiteral("message"))},
                  {QStringLiteral("folder"), call.params().value(QStringLiteral("folder"))},
                  {QStringLiteral("dest"), fi.canonicalFilePath()}},
                 [call](bool ok, const QVariant &data, const QString &error) {
                     if (!ok)
                         return call.finish(IntentResult::failed(error));
                     const QStringList files = data.toMap().value(QStringLiteral("saved")).toStringList();
                     call.finish(IntentResult::ok({{QStringLiteral("files"), files}, {QStringLiteral("count"), files.size()}}));
                 });
    });
}

void createEvent(const IntentCall &call)
{
    const QVariantMap p = call.params();
    const bool allDay = p.value(QStringLiteral("allDay")).toBool();
    QDateTime start = QDateTime::fromString(p.value(QStringLiteral("start")).toString(), QStringLiteral("yyyy-MM-ddTHH:mm"));
    if (allDay)
        start.setTime(QTime(0, 0));
    const QDateTime end = allDay ? start : start.addSecs(60 * p.value(QStringLiteral("duration")).toLongLong());
    QVariantMap event{{QStringLiteral("title"), p.value(QStringLiteral("title")).toString().simplified()},
                      {QStringLiteral("start"), start.toString(QStringLiteral("yyyy-MM-ddTHH:mm"))},
                      {QStringLiteral("end"), end.toString(QStringLiteral("yyyy-MM-ddTHH:mm"))},
                      {QStringLiteral("allDay"), allDay},
                      {QStringLiteral("location"), p.value(QStringLiteral("location"))},
                      {QStringLiteral("notes"), p.value(QStringLiteral("notes"))},
                      {QStringLiteral("alarm"), p.value(QStringLiteral("reminder"))}};
    // no "file" key: the worker only creates
    callWorker(calendarBackend(), {{QStringLiteral("op"), QStringLiteral("save_event")}, {QStringLiteral("event"), event}}, 30000,
               [call, event](bool ok, const QVariant &data, const QString &error) {
                   if (!ok)
                       return call.finish(IntentResult::failed(error));
                   call.finish(IntentResult::ok({{QStringLiteral("uid"), data.toMap().value(QStringLiteral("uid"))},
                                                 {QStringLiteral("start"), event.value(QStringLiteral("start"))},
                                                 {QStringLiteral("end"), event.value(QStringLiteral("end"))}}));
               });
}

void createTask(const IntentCall &call)
{
    const QVariantMap p = call.params();
    QString due = p.value(QStringLiteral("due")).toString().trimmed();
    if (!due.isEmpty()) {
        const QString date = LingmoIntents::IntentSchema::normalizeDate(due);
        const QString dateTime = LingmoIntents::IntentSchema::normalizeDateTime(due);
        due = !dateTime.isEmpty() ? dateTime : date;
        if (due.isEmpty())
            return call.finish(IntentResult::failed(QObject::tr("Prazo inválido (use AAAA-MM-DD ou AAAA-MM-DD HH:MM)."),
                                                    LingmoIntents::Errors::InvalidParams));
    }
    const QVariantMap task{{QStringLiteral("title"), p.value(QStringLiteral("title")).toString().simplified()},
                           {QStringLiteral("due"), due},
                           {QStringLiteral("notes"), p.value(QStringLiteral("notes"))},
                           {QStringLiteral("priority"), p.value(QStringLiteral("priority"))}};
    callWorker(calendarBackend(), {{QStringLiteral("op"), QStringLiteral("save_task")}, {QStringLiteral("task"), task}}, 30000,
               [call, task](bool ok, const QVariant &data, const QString &error) {
                   if (!ok)
                       return call.finish(IntentResult::failed(error));
                   call.finish(IntentResult::ok({{QStringLiteral("uid"), data.toMap().value(QStringLiteral("uid"))},
                                                 {QStringLiteral("title"), task.value(QStringLiteral("title"))},
                                                 {QStringLiteral("due"), task.value(QStringLiteral("due"))}}));
               });
}

void createContact(const IntentCall &call)
{
    const QVariantMap p = call.params();
    // no "id": a new contact; existing ones are never changed
    const QVariantMap contact{{QStringLiteral("name"), p.value(QStringLiteral("name")).toString().simplified()},
                              {QStringLiteral("emails"), QStringList{p.value(QStringLiteral("email")).toString()}},
                              {QStringLiteral("phone"), p.value(QStringLiteral("phone"))},
                              {QStringLiteral("notes"), p.value(QStringLiteral("notes"))}};
    mailCall({{QStringLiteral("op"), QStringLiteral("saveContact")}, {QStringLiteral("contact"), contact}},
             [call, contact, p](bool ok, const QVariant &, const QString &error) {
                 if (!ok)
                     return call.finish(IntentResult::failed(error));
                 call.finish(IntentResult::ok({{QStringLiteral("name"), contact.value(QStringLiteral("name"))},
                                               {QStringLiteral("email"), p.value(QStringLiteral("email"))}}));
             });
}

}

namespace MailIntents {

bool requested(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i)
        if (qstrcmp(argv[i], "--intents") == 0)
            return true;
    return false;
}

int run(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("lingmoos"));
    app.setApplicationName(QStringLiteral("lingmo-mail"));
    LingmoIntents::IntentService intents(QStringLiteral("lingmo-mail"));
    intents.handleAsync(QStringLiteral("mail.send"), send);
    intents.handleAsync(QStringLiteral("mail.reply"), reply);
    intents.handleAsync(QStringLiteral("mail.search"), search);
    intents.handleAsync(QStringLiteral("mail.read"), read);
    intents.handleAsync(QStringLiteral("mail.saveAttachments"), saveAttachments);
    intents.handleAsync(QStringLiteral("calendar.event.create"), createEvent);
    intents.handleAsync(QStringLiteral("tasks.create"), createTask);
    intents.handleAsync(QStringLiteral("contacts.create"), createContact);
    if (!intents.publish(LingmoIntents::IntentService::Headless))
        return 1;
    intents.setIdleQuit(60000);
    return app.exec();
}

}
