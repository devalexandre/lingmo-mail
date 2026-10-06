"""Unit tests for backend/calendar_backend.py: storage, events, tasks, invites, CalDAV sync.

No network and no keyring: HTTP goes to an in-memory CalDAV server and
secret-tool is replaced by a dictionary.
"""
import datetime as dt
import io
import json
import re
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'backend'))
import calendar_backend as cb  # noqa: E402
import ics  # noqa: E402

SP = ZoneInfo('America/Sao_Paulo')


def no_network(*args, **kwargs):
    raise AssertionError('network access in a unit test')


class Isolated(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.secrets = {}

        def fake_secret(account_id, value=None, remove=False):
            if remove:
                self.secrets.pop(account_id, None)
                return ''
            if value is not None:
                self.secrets[account_id] = value
                return ''
            return self.secrets.get(account_id, '')

        patches = [
            mock.patch.object(cb, 'CALENDARS', root / 'data' / 'calendars'),
            mock.patch.object(cb, 'CONFIG', root / 'config'),
            mock.patch.object(cb, 'MAIL_ACCOUNTS', root / 'online' / 'accounts.json'),
            mock.patch.object(cb, '_open', side_effect=no_network),
            mock.patch.object(cb.subprocess, 'run', side_effect=no_network),
            mock.patch.object(cb, 'secret', side_effect=fake_secret),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        ics.set_local_zone(SP)
        self.addCleanup(ics.set_local_zone, None)
        self.addCleanup(self.tmp.cleanup)

    def run_op(self, **req):
        return cb.dispatch(req)


class StorageTest(Isolated):
    def test_default_calendar_is_created(self):
        data = self.run_op(op='calendars')
        self.assertEqual([c['name'] for c in data['calendars']], ['Pessoal'])
        self.assertEqual(data['defaultCalendar'], 'pessoal')
        self.assertEqual(data['defaultTaskList'], 'pessoal')

    def test_calendar_crud_and_validation(self):
        made = self.run_op(op='calendar_save', calendar={'name': 'Trabalho', 'color': 'green'})
        self.assertTrue(made['id'].startswith('local-'))
        self.run_op(op='calendar_save', calendar={'id': made['id'], 'color': 'red', 'hidden': True})
        meta = cb.load_meta(made['id'])
        self.assertEqual((meta['name'], meta['color'], meta['hidden']), ('Trabalho', 'red', True))
        with self.assertRaises(cb.Problem):
            self.run_op(op='calendar_save', calendar={'name': 'x', 'color': '#ff0000'})
        with self.assertRaises(cb.Problem):
            self.run_op(op='calendar_save', calendar={'id': '../etc', 'color': 'red'})
        self.run_op(op='calendar_delete', id=made['id'])
        with self.assertRaises(cb.Problem):
            self.run_op(op='calendar_delete', id='pessoal')   # the last local one stays

    def test_rejects_path_tricks(self):
        for name in ('../x.ics', '.hidden.ics', 'a/b.ics', 'x.txt'):
            with self.assertRaises(cb.Problem):
                self.run_op(op='delete_event', calendarId='pessoal', file=name)

    def test_files_are_private_ics(self):
        saved = self.run_op(op='save_event', event={'title': 'Dentista', 'start': '2026-10-06T14:00',
                                                    'end': '2026-10-06T15:00'})
        path = cb.CALENDARS / 'pessoal' / saved['file']
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        text = path.read_text()
        self.assertIn('DTSTART;TZID=America/Sao_Paulo:20261006T140000', text)
        self.assertIn('BEGIN:VTIMEZONE', text)
        self.assertEqual(len(ics.parse(text)[0].walk('VEVENT')), 1)


class EventsTest(Isolated):
    def range(self, start, end):
        return self.run_op(op='range', start=start, end=end)

    def test_create_edit_delete(self):
        saved = self.run_op(op='save_event', event={
            'title': 'Reunião, equipe', 'location': 'Sala 2', 'notes': 'Pauta:\n- itens',
            'start': '2026-10-06T09:00', 'end': '2026-10-06T10:30', 'alarm': 15})
        items = self.range('2026-10-01', '2026-11-01')
        self.assertEqual(len(items), 1)
        e = items[0]
        self.assertEqual((e['title'], e['location'], e['notes']), ('Reunião, equipe', 'Sala 2', 'Pauta:\n- itens'))
        self.assertEqual((e['start'], e['end'], e['alarm'], e['allDay']),
                         ('2026-10-06T09:00:00', '2026-10-06T10:30:00', 15, False))
        self.run_op(op='save_event', event=dict(file=saved['file'], uid=saved['uid'], title='Reunião',
                                                start='2026-10-07T09:00', end='2026-10-07T10:00', alarm=-1))
        e = self.range('2026-10-01', '2026-11-01')[0]
        self.assertEqual((e['title'], e['start'], e['alarm']), ('Reunião', '2026-10-07T09:00:00', -1))
        cal = cb.read_object('pessoal', saved['file'])
        self.assertEqual(cal.walk('VEVENT')[0].text('SEQUENCE'), '1')
        self.run_op(op='delete_event', calendarId='pessoal', file=saved['file'])
        self.assertEqual(self.range('2026-10-01', '2026-11-01'), [])

    def test_all_day_end_is_inclusive_in_the_ui(self):
        self.run_op(op='save_event', event={'title': 'Férias', 'allDay': True, 'start': '2026-12-20',
                                            'end': '2026-12-24'})
        e = self.range('2026-12-01', '2027-01-01')[0]
        self.assertEqual((e['start'], e['end'], e['allDay']), ('2026-12-20T00:00:00', '2026-12-25T00:00:00', True))
        self.assertEqual(len(self.range('2026-12-24', '2026-12-25')), 1)
        self.assertEqual(self.range('2026-12-25', '2026-12-26'), [])

    def test_validation(self):
        bad = [
            {'title': 'x', 'start': '2026-10-06T10:00', 'end': '2026-10-06T09:00'},
            {'title': 'x', 'start': 'amanhã', 'end': '2026-10-06T09:00'},
            {'title': 'x', 'start': '2026-10-06T10:00', 'end': '2026-10-06T11:00', 'alarm': 'x'},
            {'title': 'x', 'start': '2026-10-06T10:00', 'end': '2026-10-06T11:00', 'rrule': {'freq': 'HOURLY'}},
            {'title': 'x' * 600, 'start': '2026-10-06T10:00', 'end': '2026-10-06T11:00'},
        ]
        for event in bad:
            with self.subTest(event=event), self.assertRaises(cb.Problem):
                self.run_op(op='save_event', event=event)
        with self.assertRaises(cb.Problem):
            self.range('2026-10-10', '2026-10-01')

    def test_recurring_this_and_all(self):
        saved = self.run_op(op='save_event', event={
            'title': 'Academia', 'start': '2026-10-05T07:00', 'end': '2026-10-05T08:00',
            'rrule': {'freq': 'WEEKLY', 'interval': 1, 'byday': ['MO', 'WE'], 'count': 0, 'until': '2026-10-31'}})
        items = self.range('2026-10-01', '2026-11-01')
        self.assertEqual([i['start'][:10] for i in items],
                         ['2026-10-05', '2026-10-07', '2026-10-12', '2026-10-14', '2026-10-19', '2026-10-21',
                          '2026-10-26', '2026-10-28'])
        self.assertEqual(items[0]['rrule']['text'], 'Semanalmente (segunda, quarta), até 31/10/2026')
        second = items[1]
        # Move only the 7th to 18:00
        self.run_op(op='save_event', event=dict(file=saved['file'], uid=saved['uid'], scope='this',
                                                recurrenceId=second['recurrenceId'], title='Academia (tarde)',
                                                start='2026-10-07T18:00', end='2026-10-07T19:00'))
        items = self.range('2026-10-07', '2026-10-08')
        self.assertEqual([(i['title'], i['start']) for i in items], [('Academia (tarde)', '2026-10-07T18:00:00')])
        # Delete only the 12th
        third = self.range('2026-10-12', '2026-10-13')[0]
        self.run_op(op='delete_event', calendarId='pessoal', file=saved['file'], uid=saved['uid'], scope='this',
                    recurrenceId=third['recurrenceId'])
        self.assertEqual(self.range('2026-10-12', '2026-10-13'), [])
        # Edit "all" from the 14th instance: the series shifts by one hour, the start date stays
        fourth = self.range('2026-10-14', '2026-10-15')[0]
        self.run_op(op='save_event', event=dict(file=saved['file'], uid=saved['uid'], scope='all', title='Academia',
                                                occurrenceStart=fourth['start'], start='2026-10-14T08:00',
                                                end='2026-10-14T09:00', rrule=None))
        items = self.range('2026-10-01', '2026-11-01')
        self.assertEqual(items[0]['start'], '2026-10-05T08:00:00')
        self.assertEqual([i['start'][:10] for i in items],
                         ['2026-10-05', '2026-10-07', '2026-10-14', '2026-10-19', '2026-10-21', '2026-10-26',
                          '2026-10-28'])
        moved = next(i for i in items if i['start'][:10] == '2026-10-07')
        self.assertEqual((moved['title'], moved['start']), ('Academia (tarde)', '2026-10-07T18:00:00'))
        cal = cb.read_object('pessoal', saved['file'])
        self.assertEqual(len(cal.walk('VEVENT')), 2)   # master + the moved instance

    def test_move_between_calendars(self):
        other = self.run_op(op='calendar_save', calendar={'name': 'Casa', 'color': 'orange'})
        saved = self.run_op(op='save_event', event={'title': 'Feira', 'start': '2026-10-10T08:00',
                                                    'end': '2026-10-10T09:00'})
        self.run_op(op='save_event', event=dict(file=saved['file'], uid=saved['uid'], calendarId=other['id'],
                                                originalCalendarId='pessoal', title='Feira',
                                                start='2026-10-10T08:00', end='2026-10-10T09:00'))
        items = self.range('2026-10-10', '2026-10-11')
        self.assertEqual([(i['calendarId'], i['color']) for i in items], [(other['id'], 'orange')])

    def test_import_ics(self):
        text = ('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:PUBLISH\r\n'
                'BEGIN:VEVENT\r\nUID:a@x\r\nDTSTART:20261001T120000Z\r\nSUMMARY:Um\r\nEND:VEVENT\r\n'
                'BEGIN:VEVENT\r\nUID:b@x\r\nDTSTART;VALUE=DATE:20261002\r\nSUMMARY:Dois\r\nEND:VEVENT\r\n'
                'BEGIN:VTODO\r\nUID:c@x\r\nSUMMARY:Três\r\nEND:VTODO\r\nEND:VCALENDAR\r\n')
        self.assertEqual(self.run_op(op='import_ics', text=text)['imported'], 3)
        self.assertEqual(self.run_op(op='import_ics', text=text)['imported'], 3)   # same UIDs: replaced
        self.assertEqual(len(self.range('2026-10-01', '2026-10-03')), 2)
        self.assertEqual([t['title'] for t in self.run_op(op='tasks')], ['Três'])
        with self.assertRaises(ics.ICalError):
            self.run_op(op='import_ics', text='BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n')


class TasksTest(Isolated):
    def test_task_lifecycle(self):
        t = self.run_op(op='save_task', task={'title': 'Pagar conta', 'notes': 'Luz', 'due': '2026-10-10',
                                              'priority': 1})
        self.assertEqual((t['title'], t['due'], t['dueAllDay'], t['priority'], t['done']),
                         ('Pagar conta', '2026-10-10T00:00:00', True, 1, False))
        t = self.run_op(op='complete_task', calendarId=t['calendarId'], file=t['file'], done=True)
        self.assertTrue(t['done'])
        self.assertTrue(t['completed'])
        t = self.run_op(op='save_task', task={'file': t['file'], 'calendarId': t['calendarId'], 'title': 'Pagar luz',
                                              'due': '2026-10-11T18:30', 'priority': 0, 'done': False})
        self.assertEqual((t['title'], t['due'], t['done']), ('Pagar luz', '2026-10-11T18:30:00', False))
        self.run_op(op='delete_task', calendarId=t['calendarId'], file=t['file'])
        self.assertEqual(self.run_op(op='tasks'), [])
        with self.assertRaises(cb.Problem):
            self.run_op(op='save_task', task={'title': '   '})

    def test_event_only_calendar_refuses_tasks(self):
        meta = {'id': 'dav-1', 'name': 'Só eventos', 'color': 'blue', 'source': 'local', 'components': ['VEVENT']}
        cb.save_meta(meta)
        with self.assertRaises(cb.Problem):
            self.run_op(op='save_task', task={'title': 'x', 'calendarId': 'dav-1'})


class AlarmsTest(Isolated):
    def test_event_and_task_reminders(self):
        self.run_op(op='save_event', event={'title': 'Consulta', 'start': '2026-10-06T14:00',
                                            'end': '2026-10-06T15:00', 'alarm': 30})
        self.run_op(op='save_event', event={'title': 'Sem lembrete', 'start': '2026-10-06T16:00',
                                            'end': '2026-10-06T17:00'})
        self.run_op(op='save_task', task={'title': 'Relatório', 'due': '2026-10-06T17:00'})
        self.run_op(op='save_task', task={'title': 'Feito', 'due': '2026-10-06T17:00', 'done': True})
        self.run_op(op='save_task', task={'title': 'Dia todo', 'due': '2026-10-07'})
        start = int(dt.datetime(2026, 10, 6, 0, tzinfo=SP).timestamp())
        alarms = self.run_op(op='alarms', **{'from': start, 'to': start + 2 * 86400})
        got = [(a['title'], dt.datetime.fromtimestamp(a['when'], SP).strftime('%d %H:%M'), a['kind']) for a in alarms]
        self.assertEqual(got, [('Consulta', '06 13:30', 'event'), ('Relatório', '06 17:00', 'task'),
                               ('Dia todo', '07 09:00', 'task')])
        self.assertEqual(len({a['key'] for a in alarms}), 3)
        again = self.run_op(op='alarms', **{'from': start, 'to': start + 2 * 86400})
        self.assertEqual([a['key'] for a in again], [a['key'] for a in alarms])   # stable identity


INVITE = '''BEGIN:VCALENDAR
VERSION:2.0
METHOD:%(method)s
BEGIN:VEVENT
UID:invite-1@example.com
SEQUENCE:%(seq)d
DTSTAMP:20261001T120000Z
DTSTART;TZID=America/Sao_Paulo:20261008T100000
DTEND;TZID=America/Sao_Paulo:20261008T110000
SUMMARY:Revisão do projeto
LOCATION:Sala 3
ORGANIZER;CN=Bia:mailto:bia@example.com
ATTENDEE;CN=Ana;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:ana@example.com
END:VEVENT
END:VCALENDAR
'''


class InviteTest(Isolated):
    def invite(self, method='REQUEST', seq=0):
        return INVITE % {'method': method, 'seq': seq}

    def test_parse_shows_conflicts(self):
        self.run_op(op='save_event', event={'title': 'Almoço cedo', 'start': '2026-10-08T10:30',
                                            'end': '2026-10-08T11:30'})
        info = self.run_op(op='invite_parse', text=self.invite(), email='ana@example.com')
        self.assertEqual((info['method'], info['title'], info['location'], info['start']),
                         ('REQUEST', 'Revisão do projeto', 'Sala 3', '2026-10-08T10:00:00'))
        self.assertEqual(info['organizer']['email'], 'bia@example.com')
        self.assertEqual(info['myStatus'], 'NEEDS-ACTION')
        self.assertEqual([c['title'] for c in info['conflicts']], ['Almoço cedo'])
        self.assertIsNone(info['existing'])

    def test_accept_then_update_then_cancel(self):
        out = self.run_op(op='invite_reply', text=self.invite(), partstat='ACCEPTED', email='ana@example.com')
        self.assertEqual(out['organizer'], 'bia@example.com')
        self.assertEqual(out['subject'], 'Aceito: Revisão do projeto')
        reply = ics.parse(out['replyIcs'])[0]
        self.assertEqual(reply.text('METHOD'), 'REPLY')
        self.assertEqual(reply.walk('VEVENT')[0].get('ATTENDEE').params['PARTSTAT'], 'ACCEPTED')
        stored = self.run_op(op='range', start='2026-10-08', end='2026-10-09')
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]['attendees'][0]['partstat'], 'ACCEPTED')
        cal = cb.read_object(stored[0]['calendarId'], stored[0]['file'])
        self.assertIsNone(cal.get('METHOD'))
        # Newer version of the same invite
        info = self.run_op(op='invite_parse', text=self.invite(seq=1), email='ana@example.com')
        self.assertTrue(info['updated'])
        self.assertEqual(info['existing']['partstat'], 'ACCEPTED')
        self.run_op(op='invite_reply', text=self.invite(seq=1), partstat='TENTATIVE', email='ana@example.com')
        # An older one is refused
        with self.assertRaises(cb.Problem):
            self.run_op(op='invite_reply', text=self.invite(seq=0), partstat='ACCEPTED', email='ana@example.com')
        self.assertTrue(self.run_op(op='invite_parse', text=self.invite(seq=0), email='ana@example.com')['outdated'])
        self.assertEqual(len(self.run_op(op='range', start='2026-10-08', end='2026-10-09')), 1)
        self.assertTrue(self.run_op(op='invite_cancel', text=self.invite('CANCEL', 2))['removed'])
        self.assertEqual(self.run_op(op='range', start='2026-10-08', end='2026-10-09'), [])

    def test_decline_does_not_add(self):
        out = self.run_op(op='invite_reply', text=self.invite(), partstat='DECLINED', email='ana@example.com')
        self.assertEqual(out['subject'], 'Recusado: Revisão do projeto')
        self.assertEqual(self.run_op(op='range', start='2026-10-08', end='2026-10-09'), [])

    def test_reply_needs_valid_input(self):
        with self.assertRaises(cb.Problem):
            self.run_op(op='invite_reply', text=self.invite(), partstat='YES', email='ana@example.com')
        with self.assertRaises(cb.Problem):
            self.run_op(op='invite_reply', text=self.invite(), partstat='ACCEPTED', email='ana\r\n@x')


# ---------------------------------------------------------------- fake CalDAV server

class FakeDav:
    """Just enough CalDAV for the client: principal discovery, listing, multiget, PUT/DELETE with etags."""

    def __init__(self, host='caldav.example.com', sync_tokens=False):
        self.host = host
        self.base = 'https://%s' % host
        self.objects = {}   # path -> (etag, text)
        self.ctag = 1
        self.sync_tokens = sync_tokens
        self.history = []   # (token, path, deleted)
        self.requests = []
        self.password = 'app-password'
        self.cal_path = '/cal/user/home/work/'

    def put_object(self, name, text):
        path = self.cal_path + name
        self.ctag += 1
        etag = '"e%d"' % self.ctag
        self.objects[path] = (etag, text)
        self.history.append((self.ctag, path, False))
        return etag

    def delete_object(self, name):
        path = self.cal_path + name
        self.objects.pop(path, None)
        self.ctag += 1
        self.history.append((self.ctag, path, True))

    def ms(self, responses):
        return ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
                'xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/">%s</d:multistatus>'
                % ''.join(responses)).encode()

    def ok(self, href, props):
        return ('<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 200 OK'
                '</d:status></d:propstat></d:response>' % (href, props))

    def __call__(self, request, timeout):
        url = urllib.parse.urlsplit(request.full_url)
        url = url._replace(path=urllib.parse.unquote(url.path))
        method = request.get_method()
        body = request.data.decode() if request.data else ''
        headers = {k.lower(): v for k, v in request.header_items()}
        self.requests.append((method, url.path, headers))
        assert url.scheme == 'https'
        if url.hostname != self.host:
            return 404, {}, b''
        expected = 'Basic ' + __import__('base64').b64encode(('ana@example.com:%s' % self.password).encode()).decode()
        if headers.get('authorization') != expected:
            return 401, {}, b'<secret server body>'
        path = url.path
        if path == '/.well-known/caldav':
            return 301, {'location': '/dav/'}, b''
        if method == 'PROPFIND' and path == '/dav/' and 'current-user-principal' in body:
            return 207, {}, self.ms([self.ok(path, '<d:current-user-principal><d:href>/principals/ana/</d:href>'
                                                   '</d:current-user-principal>')])
        if method == 'PROPFIND' and path == '/principals/ana/':
            return 207, {}, self.ms([self.ok(path, '<c:calendar-home-set><d:href>/cal/user/home/</d:href>'
                                                   '</c:calendar-home-set>')])
        if method == 'PROPFIND' and path == '/cal/user/home/':
            return 207, {}, self.ms([
                self.ok(path, '<d:resourcetype><d:collection/></d:resourcetype>'),
                self.ok(self.cal_path, '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
                        '<d:displayname>Trabalho</d:displayname><a:calendar-color>#34C759FF</a:calendar-color>'
                        '<c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/>'
                        '</c:supported-calendar-component-set><cs:getctag>%d</cs:getctag>'
                        '<d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/>'
                        '</d:privilege></d:current-user-privilege-set>' % self.ctag),
                self.ok('/cal/user/home/inbox/', '<d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype>'),
            ])
        if method == 'PROPFIND' and path == self.cal_path:
            token = '<d:sync-token>tok-%d</d:sync-token>' % self.ctag if self.sync_tokens else ''
            return 207, {}, self.ms([self.ok(path, '<cs:getctag>%d</cs:getctag>%s' % (self.ctag, token))])
        if method == 'REPORT' and path == self.cal_path:
            if 'calendar-query' in body:
                return 207, {}, self.ms([self.ok(p, '<d:getetag>%s</d:getetag>' % e.replace('"', '&quot;'))
                                         for p, (e, _) in self.objects.items()])
            if 'calendar-multiget' in body:
                wanted = re.findall(r'<d:href>([^<]+)</d:href>', body)
                return 207, {}, self.ms([self.ok(p, '<d:getetag>%s</d:getetag><c:calendar-data>%s</c:calendar-data>'
                                                 % (self.objects[p][0], self.objects[p][1].replace('&', '&amp;')
                                                    .replace('<', '&lt;')))
                                         for p in wanted if p in self.objects])
            if 'sync-collection' in body:
                old = int(re.search(r'tok-(\d+)', body)[1])
                parts = []
                for token, p, deleted in self.history:
                    if token > old:
                        if deleted and p not in self.objects:
                            parts.append('<d:response><d:href>%s</d:href><d:status>HTTP/1.1 404 Not Found'
                                         '</d:status></d:response>' % p)
                        elif p in self.objects:
                            parts.append(self.ok(p, '<d:getetag>%s</d:getetag>' % self.objects[p][0]))
                return 207, {}, self.ms(parts + ['<d:sync-token>tok-%d</d:sync-token>' % self.ctag])
        if method == 'PUT' and path.startswith(self.cal_path):
            current = self.objects.get(path)
            if headers.get('if-none-match') == '*' and current:
                return 412, {}, b''
            if headers.get('if-match') and (not current or current[0] != headers['if-match']):
                return 412, {}, b''
            etag = self.put_object(path[len(self.cal_path):], body)
            return 201, {'etag': etag}, b''
        if method == 'DELETE' and path.startswith(self.cal_path):
            current = self.objects.get(path)
            if not current:
                return 404, {}, b''
            if headers.get('if-match') and current[0] != headers['if-match']:
                return 412, {}, b''
            self.delete_object(path[len(self.cal_path):])
            return 204, {}, b''
        return 404, {}, b''


def remote_event(uid, title, start='20261012T130000Z'):
    return ('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Server//EN\r\nBEGIN:VEVENT\r\nUID:%s\r\nDTSTAMP:20261001T000000Z\r\n'
            'DTSTART:%s\r\nDURATION:PT1H\r\nSUMMARY:%s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' % (uid, start, title))


class CalDavTest(Isolated):
    def connect(self, server):
        cb._open.side_effect = server
        return self.run_op(op='caldav_add_account', provider='other', url='https://%s' % server.host,
                           email='ana@example.com', username='ana@example.com', password=server.password)

    def dav_calendar(self):
        return next(m for m in cb.all_meta() if m.get('source') == 'caldav')

    def test_xml_parsing_and_colors(self):
        data = (b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/a%20b/</d:href><d:propstat><d:prop>'
                b'<d:displayname>X</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
                b'<d:propstat><d:prop><d:getctag/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>'
                b'</d:response></d:multistatus>')
        items = cb.multistatus(data, 'https://h.example.com/home/')
        self.assertEqual(items[0]['href'], 'https://h.example.com/a%20b/')
        self.assertEqual(list(items[0]['props']), ['{DAV:}displayname'])
        with self.assertRaises(cb.DavError):
            cb.parse_xml(b'<!DOCTYPE x [<!ENTITY a "b">]><x>&a;</x>')
        self.assertEqual(cb.nearest_color('#FF2D92'), 'pink')
        self.assertEqual(cb.nearest_color('#FF3B30'), 'red')
        self.assertEqual(cb.nearest_color('#34C759FF'), 'green')
        self.assertEqual(cb.nearest_color('#1BADF8'), 'blue')
        self.assertEqual(cb.nearest_color('#FF9500'), 'orange')
        self.assertEqual(cb.nearest_color('#888888'), 'grey')
        self.assertIsNone(cb.nearest_color('blue'))

    def test_https_only_and_no_body_in_errors(self):
        with self.assertRaises(cb.DavError):
            cb.candidates('other', '', 'http://cal.example.com/')
        server = FakeDav()
        server.password = 'other'
        cb._open.side_effect = server
        with self.assertRaises(cb.DavError) as ctx:
            self.run_op(op='caldav_discover', provider='other', url='caldav.example.com', email='ana@example.com',
                        password='wrong')
        self.assertNotIn('secret', str(ctx.exception))
        self.assertIn('senha de app', str(ctx.exception))

    def test_credentials_stay_on_the_same_site(self):
        def redirecting(request, timeout):
            if request.host == 'caldav.example.com':
                return 302, {'location': 'https://evil.example.org/x'}, b''
            self.assertIsNone(request.get_header('Authorization'))
            return 404, {}, b''
        cb._open.side_effect = redirecting
        with self.assertRaises(cb.DavError):
            cb.propfind('https://caldav.example.com/', ('u', 'p'), '', 0)

    def test_discovery_add_and_initial_pull(self):
        server = FakeDav()
        server.put_object('one.ics', remote_event('one@srv', 'Planejamento'))
        out = self.connect(server)
        self.assertEqual(out['sync']['errors'], [])
        self.assertEqual(self.secrets[out['account']['id']], 'app-password')
        accounts = json.loads((cb.CONFIG / 'caldav-accounts.json').read_text())
        self.assertNotIn('app-password', json.dumps(accounts))
        meta = self.dav_calendar()
        self.assertEqual((meta['name'], meta['color'], meta['components']), ('Trabalho', 'green', ['VEVENT', 'VTODO']))
        items = self.run_op(op='range', start='2026-10-12', end='2026-10-13')
        self.assertEqual([i['title'] for i in items], ['Planejamento'])

    def test_two_way_sync(self):
        server = FakeDav()
        server.put_object('one.ics', remote_event('one@srv', 'Planejamento'))
        self.connect(server)
        cid = self.dav_calendar()['id']
        # Local create -> PUT If-None-Match
        saved = self.run_op(op='save_event', event={'calendarId': cid, 'title': 'Local', 'start': '2026-10-13T10:00',
                                                    'end': '2026-10-13T11:00'})
        self.assertEqual(cb.sync_state(cid)['dirty'], [saved['file']])
        self.run_op(op='caldav_sync')
        self.assertIn(server.cal_path + saved['file'], server.objects)
        self.assertEqual(cb.sync_state(cid)['dirty'], [])
        put = [r for r in server.requests if r[0] == 'PUT'][-1]
        self.assertEqual(put[2].get('if-none-match'), '*')
        # Remote change -> pulled
        server.put_object('one.ics', remote_event('one@srv', 'Planejamento v2'))
        self.run_op(op='caldav_sync')
        titles = [i['title'] for i in self.run_op(op='range', start='2026-10-12', end='2026-10-14')]
        self.assertEqual(sorted(titles), ['Local', 'Planejamento v2'])
        # Local edit -> PUT If-Match
        item = next(i for i in self.run_op(op='range', start='2026-10-12', end='2026-10-13'))
        self.run_op(op='save_event', event=dict(calendarId=cid, file=item['file'], uid=item['uid'],
                                                title='Editado aqui', start='2026-10-12T10:00', end='2026-10-12T11:00'))
        self.run_op(op='caldav_sync')
        put = [r for r in server.requests if r[0] == 'PUT'][-1]
        self.assertTrue(put[2].get('if-match'))
        self.assertIn('Editado aqui', server.objects[server.cal_path + 'one.ics'][1])
        # Remote delete -> removed locally; local delete -> DELETE If-Match
        server.delete_object('one.ics')
        self.run_op(op='caldav_sync')
        self.assertEqual([i['title'] for i in self.run_op(op='range', start='2026-10-12', end='2026-10-14')], ['Local'])
        self.run_op(op='delete_event', calendarId=cid, file=saved['file'])
        self.run_op(op='caldav_sync')
        self.assertEqual(server.objects, {})
        delete = [r for r in server.requests if r[0] == 'DELETE'][-1]
        self.assertTrue(delete[2].get('if-match'))

    def test_unchanged_ctag_skips_listing(self):
        server = FakeDav()
        server.put_object('one.ics', remote_event('one@srv', 'A'))
        self.connect(server)
        before = len(server.requests)
        self.run_op(op='caldav_sync')
        reports = [r for r in server.requests[before:] if r[0] == 'REPORT']
        self.assertEqual(reports, [])

    def test_conflict_server_wins_and_local_copy_kept(self):
        server = FakeDav()
        server.put_object('one.ics', remote_event('one@srv', 'Original'))
        self.connect(server)
        cid = self.dav_calendar()['id']
        item = self.run_op(op='range', start='2026-10-12', end='2026-10-13')[0]
        self.run_op(op='save_event', event=dict(calendarId=cid, file=item['file'], uid=item['uid'], title='Minha versão',
                                                start='2026-10-12T10:00', end='2026-10-12T11:00'))
        server.put_object('one.ics', remote_event('one@srv', 'Versão do servidor'))
        out = self.run_op(op='caldav_sync')
        self.assertEqual(out['accounts'][0]['errors'], [])
        titles = sorted(i['title'] for i in self.run_op(op='range', start='2026-10-12', end='2026-10-13'))
        self.assertEqual(titles, ['Minha versão (cópia em conflito)', 'Versão do servidor'])
        self.assertIn('Versão do servidor', server.objects[server.cal_path + 'one.ics'][1])
        # The copy was uploaded as a new object
        self.assertEqual(len(server.objects), 2)
        self.assertEqual(cb.sync_state(cid)['dirty'], [])

    def test_sync_token_mode(self):
        server = FakeDav(sync_tokens=True)
        server.put_object('one.ics', remote_event('one@srv', 'A'))
        self.connect(server)
        server.put_object('two.ics', remote_event('two@srv', 'B'))
        server.delete_object('one.ics')
        self.run_op(op='caldav_sync')
        titles = [i['title'] for i in self.run_op(op='range', start='2026-10-12', end='2026-10-13')]
        self.assertEqual(titles, ['B'])
        bodies = [r for r in server.requests if r[0] == 'REPORT']
        self.assertTrue(any(True for _ in bodies))

    def test_remove_account(self):
        server = FakeDav()
        out = self.connect(server)
        self.run_op(op='caldav_remove', accountId=out['account']['id'])
        self.assertEqual(self.secrets, {})
        self.assertEqual([m['source'] for m in cb.all_meta()], ['local'])

    def test_sync_errors_are_reported_per_account(self):
        server = FakeDav()
        self.connect(server)
        server.password = 'revoked'
        out = self.run_op(op='caldav_sync')
        self.assertIn('senha de app', out['accounts'][0]['errors'][0])
        self.assertTrue(self.run_op(op='calendars')['accounts'][0]['lastError'])


class MailAccountsTest(Isolated):
    def test_reads_providers_without_secrets(self):
        cb.MAIL_ACCOUNTS.parent.mkdir(parents=True)
        cb.MAIL_ACCOUNTS.write_text(json.dumps([
            {'id': '1', 'email': 'ana@icloud.com', 'name': 'Ana'},
            {'id': '2', 'email': 'bia@yahoo.com.br'},
            {'id': '3', 'email': 'c@example.com'},
            {'id': '4', 'email': 'not an email'},
        ]))
        got = self.run_op(op='mail_accounts')
        self.assertEqual([(a['email'], a['provider']) for a in got],
                         [('ana@icloud.com', 'icloud'), ('bia@yahoo.com.br', 'yahoo'), ('c@example.com', '')])


class MainTest(Isolated):
    def test_errors_are_generic(self):
        out = io.StringIO()
        with mock.patch.object(cb.sys, 'stdin', io.TextIOWrapper(io.BytesIO(b'{"op":"range","start":1}\n'))), \
                mock.patch.object(cb.sys, 'stdout', out):
            self.assertEqual(cb.main(), 1)
        self.assertEqual(json.loads(out.getvalue()), {'ok': False, 'error': 'Data inválida.'})
        out = io.StringIO()
        with mock.patch.object(cb.sys, 'stdin', io.TextIOWrapper(io.BytesIO(b'{"op":"tasks"}\n'))), \
                mock.patch.object(cb.sys, 'stdout', out), \
                mock.patch.dict(cb.OPS, {'tasks': mock.Mock(side_effect=KeyError('x'))}):
            self.assertEqual(cb.main(), 1)
        self.assertEqual(json.loads(out.getvalue())['error'], 'Não foi possível concluir a operação.')


if __name__ == '__main__':
    unittest.main()
