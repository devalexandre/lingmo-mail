#pragma once

// `lingmo-mail --intents`: no window. Serves com.lingmo.Mail /Intents (D-Bus
// activation): mail.send, mail.reply, mail.search, mail.read, mail.saveAttachments,
// calendar.event.create, tasks.create and contacts.create, through the same
// Python workers the window uses (backend.py, calendar_backend.py). Only
// reading, sending and creating requests are ever built here: nothing is
// deleted, moved or marked, and the user's filter rules never run.
namespace MailIntents {
bool requested(int argc, char *argv[]);
int run(int argc, char *argv[]);
}
