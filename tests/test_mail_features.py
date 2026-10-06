"""Folders, list, actions, rules, contacts and calendar replies, against a fake IMAP server.

No network, no Secret Service: the connection is a FakeIMAP object and credentials are stubbed.
"""
import contextlib
import email
import email.policy
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'backend'))
import backend  # noqa: E402
from test_backend import account, no_network  # noqa: E402


def header(sender='Ana <ana@example.com>', to='eu@example.com', subject='Oi', cc=''):
    raw = f'From: {sender}\r\nTo: {to}\r\nSubject: {subject}\r\nDate: Tue, 06 Oct 2026 10:00:00 -0300\r\n'
    if cc:
        raw += f'Cc: {cc}\r\n'
    return (raw + '\r\n').encode()


PLAIN = b'("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL)'
WITH_PDF = (b'(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL)'
            b'("APPLICATION" "PDF" ("NAME" "a.pdf") NIL NIL "BASE64" 100 NIL ("ATTACHMENT" ("FILENAME" "a.pdf")) NIL) "MIXED")')

GMAIL_LIST = [
    b'(\\HasNoChildren) "/" "INBOX"',
    b'(\\HasChildren \\Noselect) "/" "[Gmail]"',
    b'(\\All \\HasNoChildren) "/" "[Gmail]/Todos os e-mails"',
    b'(\\Drafts \\HasNoChildren) "/" "[Gmail]/Rascunhos"',
    b'(\\HasNoChildren \\Sent) "/" "[Gmail]/E-mails enviados"',
    b'(\\HasNoChildren \\Junk) "/" "[Gmail]/Spam"',
    b'(\\HasNoChildren \\Trash) "/" "[Gmail]/Lixeira"',
    b'(\\Flagged \\HasNoChildren) "/" "[Gmail]/Com estrela"',
    (b'(\\HasNoChildren) "/" {14}', b'Projetos/2026&-'),
    b'(\\HasChildren) "/" Projetos',
    b'(\\HasNoChildren) "/" "Recibos &AOk-l&AOk-trico"',
]

DOVECOT_LIST = [
    b'(\\HasNoChildren) "." INBOX',
    b'(\\HasNoChildren) "." "Enviados"',
    b'(\\HasNoChildren) "." "Itens Exclu&AO0-dos"',
    b'(\\HasNoChildren) "." "Lixo Eletr&APQ-nico"',
    b'(\\HasNoChildren) "." "Rascunhos"',
    b'(\\HasNoChildren) "." "Arquivo"',
    b'(\\HasNoChildren) NIL "Notas"',
]


class FakeIMAP:
    """Just enough of imaplib.IMAP4 for the worker, with UIDs and flags per mailbox."""

    def __init__(self, listing, caps=('IMAP4REV1', 'MOVE', 'UIDPLUS'), validity=7):
        self.listing = listing
        self.capabilities = caps
        self.validity = validity
        self.boxes = {}
        self.next_uid = {}
        self.selected = None
        self.readonly = None
        self.literal = None
        self.calls = []
        for item in listing:
            line = item[0] if isinstance(item, tuple) else item
            if b'Noselect' in line:
                continue
            name = backend.parse_list([item])[0]['path']
            self.boxes[name] = {}
            self.next_uid[name] = 1

    # -- helpers for tests
    def deliver(self, box, raw_header, structure=PLAIN, flags=()):
        uid = self.next_uid[box]
        self.next_uid[box] += 1
        self.boxes[box][uid] = dict(header=raw_header, structure=structure, flags=set(flags))
        return uid

    @staticmethod
    def unquote(value):
        return backend.unquote(value.encode()) if value.startswith('"') else value

    # -- imaplib API
    def list(self):
        return 'OK', list(self.listing)

    def status(self, mailbox, items):
        box = self.boxes.get(self.unquote(mailbox))
        if box is None:
            return 'NO', [b'no such mailbox']
        name = mailbox.encode()
        if 'UIDNEXT' in items:
            return 'OK', [name + b' (UIDNEXT %d UIDVALIDITY %d)' % (self.next_uid[self.unquote(mailbox)], self.validity)]
        unseen = sum(1 for m in box.values() if '\\Seen' not in m['flags'])
        return 'OK', [name + b' (UNSEEN %d)' % unseen]

    def select(self, mailbox, readonly=False):
        name = self.unquote(mailbox)
        if name not in self.boxes:
            return 'NO', [b'']
        self.selected, self.readonly = name, readonly
        self.calls.append(('SELECT', name, readonly))
        return 'OK', [str(len(self.boxes[name])).encode()]

    def expunge(self):
        self.calls.append(('EXPUNGE',))
        box = self.boxes[self.selected]
        for uid in [u for u, m in box.items() if '\\Deleted' in m['flags']]:
            del box[uid]
        return 'OK', [None]

    def _uids(self, spec):
        box = self.boxes[self.selected]
        out = []
        for part in spec.split(','):
            if ':' in part:
                lo, hi = part.split(':')
                hi = max(box) if hi == '*' and box else int(hi) if hi != '*' else 0
                out += [u for u in box if int(lo) <= u <= hi]
            else:
                out += [int(part)] if int(part) in box else []
        return sorted(set(out))

    def uid(self, command, *args):
        command = command.upper()
        literal, self.literal = self.literal, None
        self.calls.append((command,) + args + ((literal,) if literal is not None else ()))
        box = self.boxes[self.selected]
        if command == 'SEARCH':
            uids = sorted(box)
            words = list(args)
            if words[:2] == ['CHARSET', 'UTF-8']:
                words = words[2:]
            if 'UNSEEN' in words:
                uids = [u for u in uids if '\\Seen' not in box[u]['flags']]
            if 'FLAGGED' in words:
                uids = [u for u in uids if '\\Flagged' in box[u]['flags']]
            if words[:1] == ['UID']:
                uids = self._uids(words[1])
                if not uids and box:   # n:* always matches the last message
                    uids = [max(box)]
            for key, field in (('FROM', b'From:'), ('SUBJECT', b'Subject:')):
                if key in words:
                    i = words.index(key)
                    needle = literal if i == len(words) - 1 and literal is not None else self.unquote(words[i + 1]).encode()
                    uids = [u for u in uids if any(line.startswith(field) and needle.lower() in line.lower()
                                                   for line in box[u]['header'].split(b'\r\n'))]
            return 'OK', [' '.join(map(str, uids)).encode()]
        if command == 'FETCH':
            data = []
            for n, uid in enumerate(self._uids(args[0]), 1):
                m = box[uid]
                flags = ' '.join(sorted(m['flags'])).encode()
                # Header literal first, flags after it: the order servers are free to use
                data.append((b'%d (UID %d BODYSTRUCTURE %s BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE)] {%d}'
                             % (n, uid, m['structure'], len(m['header'])), m['header']))
                data.append(b' FLAGS (%s))' % flags)
            return 'OK', data
        if command == 'STORE':
            uids, mode, flags = self._uids(args[0]), args[1], args[2].strip('()').split()
            for u in uids:
                if mode.startswith('+'):
                    box[u]['flags'].update(flags)
                else:
                    box[u]['flags'].difference_update(flags)
            return 'OK', [None]
        if command in ('MOVE', 'COPY'):
            target = self.unquote(args[1])
            for u in self._uids(args[0]):
                m = dict(box[u], flags=set(box[u]['flags']))
                self.boxes[target][self.next_uid[target]] = m
                self.next_uid[target] += 1
                if command == 'MOVE':
                    del box[u]
            return 'OK', [None]
        if command == 'EXPUNGE':
            for u in self._uids(args[0]):
                if '\\Deleted' in box[u]['flags']:
                    del box[u]
            return 'OK', [None]
        raise AssertionError('unexpected command ' + command)


class FakeServer(unittest.TestCase):
    listing = GMAIL_LIST
    caps = ('IMAP4REV1', 'MOVE', 'UIDPLUS')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = dict(XDG_CONFIG_HOME=os.path.join(self.tmp.name, 'cfg'), XDG_DATA_HOME=os.path.join(self.tmp.name, 'data'))
        self.imap = FakeIMAP(self.listing, self.caps)

        @contextlib.contextmanager
        def incoming(a, pw, oauth):
            yield self.imap

        patches = [
            mock.patch.dict(os.environ, env),
            mock.patch.object(backend, 'CONFIG', Path(self.tmp.name) / 'accounts'),
            mock.patch.object(backend, 'incoming', incoming),
            mock.patch.object(backend, 'credentials', return_value=('pw', False)),
            mock.patch.object(backend, 'outgoing', side_effect=no_network),
            mock.patch.object(backend.subprocess, 'run', side_effect=no_network),
            mock.patch.object(backend.urllib.request, 'urlopen', side_effect=no_network),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.a = backend.validate(account())


class Utf7Test(unittest.TestCase):
    def test_decode(self):
        self.assertEqual(backend.utf7_decode('Itens Exclu&AO0-dos'), 'Itens Excluídos')
        self.assertEqual(backend.utf7_decode('Lixo Eletr&APQ-nico'), 'Lixo Eletrônico')
        self.assertEqual(backend.utf7_decode('Projetos/2026&-'), 'Projetos/2026&')
        self.assertEqual(backend.utf7_decode('&ZeVnLIqe-'), '日本語')

    def test_round_trip(self):
        for text in ['Recibos élétrico', 'A & B', '日本語/Notas', 'plain', 'çãõ~']:
            with self.subTest(text=text):
                encoded = backend.utf7_encode(text)
                self.assertTrue(encoded.isascii())
                self.assertEqual(backend.utf7_decode(encoded), text)


class FolderTest(FakeServer):
    def test_gmail_special_use_and_order(self):
        folders = backend.list_folders(self.imap)
        roles = {f['role']: f['path'] for f in folders if f['role']}
        self.assertEqual(roles, {'inbox': 'INBOX', 'drafts': '[Gmail]/Rascunhos', 'sent': '[Gmail]/E-mails enviados',
                                 'all': '[Gmail]/Todos os e-mails', 'junk': '[Gmail]/Spam', 'trash': '[Gmail]/Lixeira'})
        self.assertNotIn('[Gmail]', [f['path'] for f in folders])   # \Noselect
        self.assertEqual([f['role'] for f in folders][:6], ['inbox', 'drafts', 'sent', 'all', 'junk', 'trash'])
        by_path = {f['path']: f for f in folders}
        self.assertEqual(by_path['Projetos/2026&-']['name'], '2026&')       # literal + mUTF-7
        self.assertEqual(by_path['Projetos/2026&-']['depth'], 1)
        self.assertEqual(by_path['[Gmail]/Lixeira']['depth'], 0)            # parent not selectable
        self.assertEqual(by_path['Recibos &AOk-l&AOk-trico']['name'], 'Recibos élétrico')

    def test_names_without_flags(self):
        folders = backend.assign_roles(backend.parse_list(DOVECOT_LIST))
        roles = {f['role']: f['name'] for f in folders if f['role']}
        self.assertEqual(roles, {'inbox': 'INBOX', 'sent': 'Enviados', 'trash': 'Itens Excluídos',
                                 'junk': 'Lixo Eletrônico', 'drafts': 'Rascunhos', 'archive': 'Arquivo'})
        notes = next(f for f in folders if f['path'] == 'Notas')
        self.assertEqual(notes['delimiter'], '')

    def test_flags_beat_names(self):
        listing = [b'() "/" INBOX', b'() "/" "Trash"', b'(\\Trash) "/" "Deleted Messages"']
        roles = {f['role']: f['path'] for f in backend.assign_roles(backend.parse_list(listing)) if f['role']}
        self.assertEqual(roles['trash'], 'Deleted Messages')

    def test_unsafe_names_are_skipped(self):
        listing = [b'() "/" INBOX', b'() "/" "Bad\x00name"', (b'() "/" {5}', 'Não'.encode() + b'x')]
        self.assertEqual([f['path'] for f in backend.parse_list(listing)], ['INBOX'])

    def test_quote(self):
        self.assertEqual(backend.quote('a "b" \\c'), '"a \\"b\\" \\\\c"')
        with self.assertRaises(ValueError):
            backend.quote('a\r\nb')


class SearchTest(unittest.TestCase):
    def test_filters(self):
        self.assertEqual(backend.search_criteria('all'), (['ALL'], None))
        self.assertEqual(backend.search_criteria('unread'), (['UNSEEN'], None))
        self.assertEqual(backend.search_criteria('flagged'), (['FLAGGED'], None))
        self.assertEqual(backend.search_criteria('attachment')[0][0], 'HEADER')

    def test_ascii_query_is_quoted(self):
        args, literal = backend.search_criteria('unread', 'from', 'joe "x"')
        self.assertEqual(args, ['UNSEEN', 'FROM', '"joe \\"x\\""'])
        self.assertIsNone(literal)

    def test_utf8_query_is_a_literal(self):
        args, literal = backend.search_criteria('all', 'subject', 'relatório')
        self.assertEqual(args, ['CHARSET', 'UTF-8', 'SUBJECT'])
        self.assertEqual(literal, 'relatório'.encode())

    def test_rejects_bad_input(self):
        for args in [('all', 'body', 'x'), ('nope', 'text', ''), ('all', 'text', 'a\r\nb'), ('all', 'text', 'x' * 201)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                backend.search_criteria(*args)


class FetchParseTest(unittest.TestCase):
    def test_flags_after_literal_and_attachment(self):
        data = [(b'1 (UID 9 BODYSTRUCTURE ' + WITH_PDF + b' BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE)] {60}',
                 header()), b' FLAGS (\\Flagged))',
                b'2 (UID 10 FLAGS (\\Seen) BODYSTRUCTURE ' + PLAIN + b' BODY[HEADER.FIELDS (FROM)] "")']
        records = [backend.fetch_record_summary(r) for r in backend.parse_fetch(data)]
        self.assertEqual([r['id'] for r in records], ['9', '10'])
        self.assertTrue(records[0]['unread'])
        self.assertTrue(records[0]['starred'])
        self.assertTrue(records[0]['hasAttachment'])
        self.assertEqual(records[0]['subject'], 'Oi')
        self.assertFalse(records[1]['unread'])
        self.assertFalse(records[1]['hasAttachment'])

    def test_literal_inside_bodystructure(self):
        data = [(b'1 (UID 3 FLAGS () BODYSTRUCTURE (("TEXT" "PLAIN" NIL NIL NIL "7BIT" 1 1)("APPLICATION" "PDF" ("NAME" {5}',
                 b'a.pdf'),
                (b') NIL NIL "BASE64" 9 NIL NIL NIL) "MIXED") BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE)] {60}', header()),
                b')']
        [record] = backend.parse_fetch(data)
        s = backend.fetch_record_summary(record)
        self.assertEqual(s['id'], '3')
        self.assertTrue(s['hasAttachment'])
        self.assertEqual(s['subject'], 'Oi')


class ListTest(FakeServer):
    def test_page_flags_and_counts(self):
        for n in range(1, 8):
            self.imap.deliver('INBOX', header(subject=f'm{n}'), WITH_PDF if n == 7 else PLAIN,
                              flags={'\\Seen'} if n % 2 else set())
        result = backend.list_messages(self.a, dict(limit=5))
        self.assertEqual([m['subject'] for m in result['messages']], ['m7', 'm6', 'm5', 'm4', 'm3'])
        self.assertEqual((result['total'], result['hasMore']), (7, True))
        self.assertTrue(result['messages'][0]['hasAttachment'])
        self.assertTrue(result['messages'][1]['unread'])
        inbox = next(f for f in result['folders'] if f['role'] == 'inbox')
        self.assertEqual(inbox['unread'], 3)
        # Listing never changes flags
        self.assertIn(('SELECT', 'INBOX', True), self.imap.calls)
        oldest = backend.list_messages(self.a, dict(limit=2, sort='asc'))
        self.assertEqual([m['subject'] for m in oldest['messages']], ['m1', 'm2'])

    def test_filters_and_search(self):
        self.imap.deliver('INBOX', header(subject='Relatório mensal'))
        self.imap.deliver('INBOX', header(subject='Outro'), flags={'\\Seen', '\\Flagged'})
        found = backend.list_messages(self.a, dict(search=dict(field='subject', query='relatório')))
        self.assertEqual([m['subject'] for m in found['messages']], ['Relatório mensal'])
        self.assertIn(('SEARCH', 'CHARSET', 'UTF-8', 'SUBJECT', 'relatório'.encode()), self.imap.calls)
        starred = backend.list_messages(self.a, dict(filter='flagged'))
        self.assertEqual([m['subject'] for m in starred['messages']], ['Outro'])

    def test_unknown_folder_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Pasta'):
            backend.list_messages(self.a, dict(folder='INBOX" (UNSEEN'))

    def test_other_folder(self):
        self.imap.deliver('Projetos/2026&-', header(subject='Plano'))
        result = backend.list_messages(self.a, dict(folder='Projetos/2026&-'))
        self.assertEqual(result['folder'], 'Projetos/2026&-')
        self.assertEqual([m['subject'] for m in result['messages']], ['Plano'])

    def test_pop3_is_inbox_only(self):
        a = dict(self.a, protocol='pop3')
        with mock.patch.object(backend, 'inbox', return_value=[]):
            result = backend.list_messages(a, {})
        self.assertTrue(result['pop3'])
        self.assertEqual([f['role'] for f in result['folders']], ['inbox'])
        with self.assertRaises(ValueError):
            backend.list_messages(a, dict(folder='[Gmail]/Spam'))


class ActionTest(FakeServer):
    def setUp(self):
        super().setUp()
        self.u1 = self.imap.deliver('INBOX', header(subject='um'))
        self.u2 = self.imap.deliver('INBOX', header(subject='dois'))

    def act(self, **req):
        return backend.act(self.a, dict(dict(folder='INBOX', uids=[str(self.u1)]), **req))

    def test_flags(self):
        self.act(action='read', uids=[str(self.u1), str(self.u2)])
        self.assertTrue(all('\\Seen' in m['flags'] for m in self.imap.boxes['INBOX'].values()))
        self.act(action='unread')
        self.assertNotIn('\\Seen', self.imap.boxes['INBOX'][self.u1]['flags'])
        self.act(action='star')
        self.assertIn('\\Flagged', self.imap.boxes['INBOX'][self.u1]['flags'])
        self.act(action='unstar')
        self.assertNotIn('\\Flagged', self.imap.boxes['INBOX'][self.u1]['flags'])

    def test_archive_on_gmail_goes_to_all_mail(self):
        self.act(action='archive')
        self.assertNotIn(self.u1, self.imap.boxes['INBOX'])
        self.assertEqual(len(self.imap.boxes['[Gmail]/Todos os e-mails']), 1)

    def test_move_and_delete_to_trash(self):
        self.act(action='move', target='Projetos')
        self.assertEqual(len(self.imap.boxes['Projetos']), 1)
        self.act(action='delete', uids=[str(self.u2)])
        self.assertEqual(self.imap.boxes['INBOX'], {})
        self.assertEqual(len(self.imap.boxes['[Gmail]/Lixeira']), 1)

    def test_delete_inside_trash_needs_confirmation(self):
        self.act(action='delete')
        trash_uid = str(next(iter(self.imap.boxes['[Gmail]/Lixeira'])))
        self.assertEqual(self.act(action='delete', folder='[Gmail]/Lixeira', uids=[trash_uid]), {'confirm': True})
        self.assertEqual(len(self.imap.boxes['[Gmail]/Lixeira']), 1)
        self.act(action='delete', folder='[Gmail]/Lixeira', uids=[trash_uid], permanent=True)
        self.assertEqual(self.imap.boxes['[Gmail]/Lixeira'], {})
        self.assertIn(('EXPUNGE', trash_uid), self.imap.calls)   # UIDPLUS: only these UIDs

    def test_validation(self):
        bad = [dict(action='read', uids=['1 2']), dict(action='read', uids=['1,*']), dict(action='read', uids=[]),
               dict(action='read', uids='1'), dict(action='read', uids=['0']), dict(action='format'),
               dict(action='move', target='Nao existe'), dict(action='move', target=None),
               dict(action='read', folder='Outra')]
        for req in bad:
            with self.subTest(req=req), self.assertRaises(ValueError):
                self.act(**req)
        with self.assertRaisesRegex(ValueError, 'já estão'):
            self.act(action='move', target='INBOX')

    def test_pop3_actions_refused(self):
        with self.assertRaises(ValueError):
            backend.act(dict(self.a, protocol='pop3'), dict(action='read', uids=['1']))


class MoveFallbackTest(FakeServer):
    listing = DOVECOT_LIST

    def run_move(self, caps):
        self.imap.capabilities = caps
        uid = self.imap.deliver('INBOX', header())
        self.imap.deliver('INBOX', header(), flags={'\\Deleted'})   # someone else's pending delete
        backend.act(self.a, dict(action='move', folder='INBOX', uids=[str(uid)], target='Arquivo'))
        return [c[0] for c in self.imap.calls if c[0] != 'SELECT']

    def test_uid_move(self):
        self.assertEqual(self.run_move(('MOVE', 'UIDPLUS')), ['MOVE'])

    def test_copy_store_uid_expunge(self):
        self.assertEqual(self.run_move(('UIDPLUS',)), ['COPY', 'STORE', 'EXPUNGE'])
        self.assertEqual(len(self.imap.boxes['INBOX']), 1)   # only our UID was expunged
        self.assertEqual(len(self.imap.boxes['Arquivo']), 1)

    def test_copy_store_expunge(self):
        self.assertEqual(self.run_move(()), ['COPY', 'STORE', 'EXPUNGE'])
        self.assertIn(('EXPUNGE',), self.imap.calls)   # plain EXPUNGE without UIDPLUS
        self.assertEqual(self.imap.boxes['INBOX'], {})

    def test_archive_folder_by_name(self):
        uid = self.imap.deliver('INBOX', header())
        backend.act(self.a, dict(action='archive', folder='INBOX', uids=[str(uid)]))
        self.assertEqual(len(self.imap.boxes['Arquivo']), 1)


class RulesTest(FakeServer):
    def rule(self, **changes):
        r = dict(name='Boletos', enabled=True, match='all',
                 conditions=[dict(field='from', value='banco')], actions=[dict(type='move', folder='Projetos')])
        r.update(changes)
        return r

    def test_validation(self):
        bad = [dict(match='some'), dict(conditions=[]), dict(actions=[]),
               dict(conditions=[dict(field='body', value='x')]), dict(conditions=[dict(field='from', value='')]),
               dict(conditions=[dict(field='subject', value='a\nb')]), dict(actions=[dict(type='forward')]),
               dict(actions=[dict(type='move', folder='')]),
               dict(actions=[dict(type='move', folder='X'), dict(type='delete')]),
               dict(actions=[dict(type='read'), dict(type='read')]), dict(name='x' * 121)]
        for change in bad:
            with self.subTest(change=change), self.assertRaises(ValueError):
                backend.clean_rules([self.rule(**change)])
        [clean] = backend.clean_rules([self.rule(conditions=[dict(field='attachment', value='ignored')])])
        self.assertEqual(clean['conditions'], [dict(field='attachment', value='')])
        self.assertRegex(clean['id'], r'^[0-9a-f-]{36}$')

    def test_matching(self):
        msg = dict(sender='Banco X <avisos@banco.com>', to='eu@example.com', cc='time@example.com',
                   subject='Seu boleto', hasAttachment=False)
        r = backend.clean_rules([self.rule(conditions=[dict(field='from', value='BANCO'),
                                                       dict(field='attachment', value='')])])[0]
        self.assertFalse(backend.rule_matches(r, msg))
        self.assertTrue(backend.rule_matches(dict(r, match='any'), msg))
        to = backend.clean_rules([self.rule(conditions=[dict(field='to', value='time@')])])[0]
        self.assertTrue(backend.rule_matches(to, msg))

    def test_order_and_stop_after_move(self):
        rules = backend.clean_rules([
            self.rule(actions=[dict(type='read'), dict(type='move', folder='Projetos')]),
            self.rule(actions=[dict(type='star')]),
            self.rule(enabled=False, conditions=[dict(field='subject', value='oi')], actions=[dict(type='delete')]),
        ])
        folders = backend.list_folders(self.imap)
        plan = backend.plan_rules(rules, [dict(id='5', sender='banco', subject='oi', to='', cc='')], folders)
        self.assertEqual(plan, {'read': ['5'], 'star': [], 'delete': [], 'move': {'Projetos': ['5']}})
        # A rule pointing to a folder that no longer exists does nothing
        gone = backend.clean_rules([self.rule(actions=[dict(type='move', folder='Sumiu')])])
        self.assertEqual(backend.plan_rules(gone, [dict(id='5', sender='banco', subject='', to='', cc='')], folders)['move'], {})

    def test_new_mail_processed_once(self):
        backend.save_rules(self.a['id'], [self.rule(), self.rule(conditions=[dict(field='subject', value='lixo')],
                                                                 actions=[dict(type='delete')])])
        old = self.imap.deliver('INBOX', header(sender='banco@x.com'))
        first = backend.list_messages(self.a, {})
        self.assertEqual(first['newMail']['count'], 0)     # first run: only remembers where we are
        self.assertIn(old, self.imap.boxes['INBOX'])         # old mail is left alone
        self.imap.deliver('INBOX', header(sender='Banco <banco@x.com>', subject='Fatura'))
        self.imap.deliver('INBOX', header(subject='lixo'))
        self.imap.deliver('INBOX', header(sender='Bia <bia@example.com>', subject='Almoço?'))
        self.imap.deliver('INBOX', header(subject='já lida'), flags={'\\Seen'})
        second = backend.list_messages(self.a, {})
        self.assertEqual(second['newMail']['count'], 1)
        self.assertEqual(second['newMail']['items'][0]['subject'], 'Almoço?')
        self.assertEqual([m['subject'] for m in second['messages']], ['já lida', 'Almoço?', 'Oi'])
        self.assertEqual(len(self.imap.boxes['Projetos']), 1)
        self.assertEqual(len(self.imap.boxes['[Gmail]/Lixeira']), 1)
        # Nothing new: nothing processed again, even if the user moves mail back
        self.imap.boxes['INBOX'][99] = dict(header=header(sender='banco@x.com'), structure=PLAIN, flags=set())
        self.imap.next_uid['INBOX'] = 100
        third = backend.list_messages(self.a, {})
        self.assertEqual(third['newMail']['count'], 0)
        self.assertEqual(len(self.imap.boxes['Projetos']), 2)   # uid 99 is new, so it was moved once
        fourth = backend.list_messages(self.a, {})
        self.assertEqual(fourth['newMail']['count'], 0)
        self.assertEqual(len(self.imap.boxes['Projetos']), 2)

    def test_uidvalidity_change_resets(self):
        backend.save_rules(self.a['id'], [self.rule()])
        backend.list_messages(self.a, {})
        self.imap.validity = 8
        self.imap.deliver('INBOX', header(sender='banco@x.com'))
        result = backend.list_messages(self.a, {})
        self.assertEqual(result['newMail']['count'], 0)
        self.assertEqual(len(self.imap.boxes['Projetos']), 0)

    def test_apply_now(self):
        backend.save_rules(self.a['id'], [self.rule(actions=[dict(type='star')])])
        self.imap.deliver('INBOX', header(sender='banco@x.com'))
        self.imap.deliver('INBOX', header(sender='outro@x.com'))
        self.assertEqual(backend.apply_rules_now(self.a), {'matched': 1})
        self.assertEqual(sorted('\\Flagged' in m['flags'] for m in self.imap.boxes['INBOX'].values()), [False, True])

    def test_rules_file_location(self):
        backend.save_rules(self.a['id'], [self.rule()])
        path = Path(os.environ['XDG_CONFIG_HOME']) / 'lingmo-mail' / 'rules.json'
        self.assertTrue(path.exists())
        self.assertEqual(backend.load_rules(self.a['id'])[0]['name'], 'Boletos')
        self.assertEqual(backend.load_rules('outra-conta'), [])


class ContactsTest(FakeServer):
    def test_collect_on_send(self):
        with mock.patch.object(backend, 'deliver', return_value=[]):
            backend.send(self.a, dict(to='Bia <bia@example.com>, ana@example.com', cc='c@example.com', subject='x', body=''))
            backend.send(self.a, dict(to='bia@EXAMPLE.com', subject='x', body=''))
        contacts = backend.read_contacts()
        self.assertEqual(sorted(e for c in contacts for e in c['emails']), ['bia@example.com', 'c@example.com'])
        self.assertTrue(all(c['collected'] for c in contacts))
        self.assertEqual(next(c for c in contacts if 'bia@example.com' in c['emails'])['name'], 'Bia')
        path = Path(os.environ['XDG_DATA_HOME']) / 'lingmo-mail' / 'contacts.json'
        self.assertTrue(path.exists())

    def test_edit_makes_contact_permanent(self):
        backend.collect_addresses('x@example.com')
        [c] = backend.read_contacts()
        [saved] = backend.save_contact(dict(c, name='Xavier', phone='+55 (11) 9999-0000'))
        self.assertFalse(saved['collected'])
        self.assertEqual(saved['id'], c['id'])
        self.assertEqual(backend.delete_contact(c['id']), [])

    def test_validation(self):
        for bad in [dict(name='', emails=[]), dict(name='A', emails=['nope']), dict(name='A\nB'),
                    dict(name='A', phone='abc'), dict(name='A', emails='a@b.com\r\nBcc: x@y.com'), 'x']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                backend.save_contact(bad) if isinstance(bad, dict) else backend.clean_contact(bad)
        [c] = backend.save_contact(dict(name='Duo', emails='a@b.com, A@b.com; c@d.org'))
        self.assertEqual(c['emails'], ['a@b.com', 'c@d.org'])


class ReadTest(FakeServer):
    def test_read_marks_seen_and_finds_invites(self):
        msg = backend.EmailMessage()
        msg['From'] = 'org@example.com'
        msg['Subject'] = 'Reunião'
        msg.set_content('Convite')
        ics = 'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nSUMMARY:Reunião\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
        msg.add_alternative(ics, subtype='calendar', params={'method': 'REQUEST'})
        msg.add_attachment(ics.encode(), maintype='application', subtype='ics', filename='invite.ics')
        raw = msg.as_bytes()
        uid = self.imap.deliver('INBOX', header())
        real_uid = self.imap.uid

        def uid_command(command, *args):
            if command.upper() == 'FETCH' and 'RFC822.SIZE' in args[1]:
                return 'OK', [b'1 (UID %d RFC822.SIZE %d)' % (uid, len(raw))]
            if command.upper() == 'FETCH':
                return 'OK', [(b'1 (UID %d BODY[] {%d}' % (uid, len(raw)), raw), b')']
            return real_uid(command, *args)

        self.imap.uid = uid_command
        self.imap.selected = 'INBOX'
        result = backend.read_message(self.a, str(uid), 'INBOX')
        self.assertIn('\\Seen', self.imap.boxes['INBOX'][uid]['flags'])
        self.assertEqual(len(result['calendarParts']), 1)      # inline + .ics copy are one invite
        self.assertIn('SUMMARY:Reunião', result['calendarParts'][0])
        with self.assertRaises(ValueError):
            backend.read_message(self.a, '1 OR 2', 'INBOX')

    def test_calendar_part_limits(self):
        msg = backend.EmailMessage()
        msg.set_content('x')
        for n in range(5):
            msg.add_attachment(f'BEGIN:VCALENDAR\nUID:{n}\nEND:VCALENDAR\n'.encode(), maintype='text', subtype='calendar',
                               filename=f'{n}.ics')
        msg.add_attachment(b'BEGIN:VCALENDAR\n' + b'X' * (300 * 1024), maintype='text', subtype='calendar', filename='big.ics')
        parsed = email.message_from_bytes(msg.as_bytes(), policy=email.policy.default)
        parts = backend.calendar_parts(parsed)
        self.assertEqual(len(parts), 3)
        self.assertTrue(all(len(p) < 1024 for p in parts))


class CalendarReplyTest(FakeServer):
    ICS = 'BEGIN:VCALENDAR\nMETHOD:REPLY\nBEGIN:VEVENT\nATTENDEE;PARTSTAT=ACCEPTED:mailto:ana@example.com\nEND:VEVENT\nEND:VCALENDAR\n'

    def test_message_structure(self):
        msg = backend.build_calendar_reply(self.a, 'org@example.com', 'Aceito: Reunião', self.ICS)
        self.assertEqual(msg.get_content_type(), 'multipart/alternative')
        text, cal = msg.get_payload()
        self.assertEqual(text.get_content_type(), 'text/plain')
        self.assertEqual(cal.get_content_type(), 'text/calendar')
        self.assertEqual(cal.get_param('method'), 'REPLY')
        self.assertIn('PARTSTAT=ACCEPTED', cal.get_content())
        self.assertEqual(msg['To'], 'org@example.com')
        self.assertIn('ana@example.com', msg['From'])

    def test_rejected_before_network(self):
        bad = [('org@example.com\r\nBcc: x@evil.com', 'Aceito', self.ICS), ('org@example.com', 'A\nBcc: x', self.ICS),
               ('lixo', 'Aceito', self.ICS), ('org@example.com', 'Aceito', 'not ical'),
               ('org@example.com', 'Aceito', 'BEGIN:VCALENDAR\n' + 'X' * (256 * 1024)),
               ('org@example.com', 'Aceito', None)]
        for to, subject, ics in bad:
            with self.subTest(to=to, subject=subject), self.assertRaises(ValueError):
                backend.send_calendar_reply(self.a, dict(to=to, subject=subject, ics=ics))

    def test_sends(self):
        with mock.patch.object(backend, 'deliver', return_value=[]) as deliver:
            self.assertEqual(backend.send_calendar_reply(self.a, dict(to='org@example.com', subject='Aceito', ics=self.ICS)),
                             {'sent': True, 'refused': []})
        self.assertEqual(deliver.call_args[0][1].get_content_type(), 'multipart/alternative')


if __name__ == '__main__':
    unittest.main()
