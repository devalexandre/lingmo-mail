#!/usr/bin/python3
"""Lingmo Mail calendar and tasks worker.

One JSON request on stdin, one JSON reply on stdout. Events and tasks are kept
as standard iCalendar files, one object per file, under
$XDG_DATA_HOME/lingmo-mail/calendars/<calendar-id>/. CalDAV passwords live only
in the Secret Service (application=lingmo-mail-caldav); server replies are never
echoed in errors.
"""
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

# Isolated mode (-I) doesn't put the script's directory on sys.path
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import ics  # noqa: E402

HOME = Path.home()
DATA = Path(os.environ.get('XDG_DATA_HOME') or HOME / '.local' / 'share') / 'lingmo-mail'
CALENDARS = DATA / 'calendars'
CONFIG = Path(os.environ.get('XDG_CONFIG_HOME') or HOME / '.config') / 'lingmo-mail'
MAIL_ACCOUNTS = Path(os.environ.get('XDG_CONFIG_HOME') or HOME / '.config') / 'lingmo-online-accounts' / 'accounts.json'

COLORS = ('blue', 'green', 'orange', 'red', 'purple', 'pink', 'grey')
DEFAULT_ID = 'pessoal'
OBJECT_LIMIT = 2 * 1024 * 1024          # one .ics file
HTTP_LIMIT = 16 * 1024 * 1024           # one HTTP response
MAX_OCCURRENCES = 5000
TLS = ssl.create_default_context()
SECRET_APP = 'lingmo-mail-caldav'
PROVIDERS = {
    'icloud': 'https://caldav.icloud.com/',
    'yahoo': 'https://caldav.calendar.yahoo.com/',
    'fastmail': 'https://caldav.fastmail.com/',
}
PARTSTAT_WORDS = {'ACCEPTED': 'Aceito', 'TENTATIVE': 'Talvez', 'DECLINED': 'Recusado'}
EMAIL = re.compile(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+')
SAFE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._@+-]{0,199}')
CAL_ID = re.compile(r'[a-z0-9][a-z0-9-]{0,63}')


class Problem(ValueError):
    """An error whose (Portuguese) message can be shown to the user."""


class DavError(Problem):
    pass


# ================================================================ storage helpers

def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.tmp-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path, default):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, type(default)) else default
    except (OSError, ValueError):
        return default


def write_json(path, data):
    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=1))


_held = {}


@contextlib.contextmanager
def locked(path):
    """Exclusive lock between worker processes; re-entrant inside one process."""
    key = str(path)
    if key in _held:
        _held[key] += 1
        try:
            yield
        finally:
            _held[key] -= 1
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, 'a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        _held[key] = 1
        try:
            yield
        finally:
            del _held[key]
            fcntl.flock(handle, fcntl.LOCK_UN)


def check_id(value):
    if not isinstance(value, str) or not CAL_ID.fullmatch(value):
        raise Problem('Calendário inválido.')
    return value


def check_name(value):
    if not isinstance(value, str) or not SAFE_NAME.fullmatch(value) or not value.endswith('.ics'):
        raise Problem('Item inválido.')
    return value


def text_field(value, limit, field='Campo'):
    if value is None:
        return ''
    if not isinstance(value, str):
        raise Problem('%s inválido.' % field)
    value = value.replace('\x00', '')
    if len(value) > limit:
        raise Problem('%s grande demais.' % field)
    return value


def line_field(value, limit, field='Campo'):
    value = text_field(value, limit, field)
    return ' '.join(value.split())


def cal_dir(cid):
    return CALENDARS / check_id(cid)


def settings():
    return read_json(CALENDARS / 'settings.json', {})


def ensure_default():
    CALENDARS.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not any(p.is_dir() and (p / 'calendar.json').exists() for p in CALENDARS.iterdir()):
        with locked(CALENDARS / '.lock'):
            if not (CALENDARS / DEFAULT_ID / 'calendar.json').exists():
                save_meta({'id': DEFAULT_ID, 'name': 'Pessoal', 'color': 'blue', 'source': 'local',
                           'components': ['VEVENT', 'VTODO'], 'hidden': False, 'order': 0})


def load_meta(cid):
    meta = read_json(cal_dir(cid) / 'calendar.json', {})
    if not meta:
        raise Problem('Calendário não encontrado.')
    meta['id'] = cid
    return meta


def save_meta(meta):
    write_json(cal_dir(meta['id']) / 'calendar.json', meta)


def all_meta():
    ensure_default()
    out = []
    for path in CALENDARS.iterdir():
        if path.is_dir() and CAL_ID.fullmatch(path.name) and (path / 'calendar.json').exists():
            try:
                out.append(load_meta(path.name))
            except ValueError:
                continue
    out.sort(key=lambda m: (m.get('source') != 'local', m.get('accountId', ''), m.get('order', 0),
                            m.get('name', '').lower()))
    return out


def default_calendar(component='VEVENT'):
    metas = [m for m in all_meta() if component in m.get('components', []) and not m.get('readOnly')]
    wanted = settings().get('defaultCalendar' if component == 'VEVENT' else 'defaultTaskList')
    for m in metas:
        if m['id'] == wanted:
            return m
    for m in metas:
        if m['id'] == DEFAULT_ID:
            return m
    if metas:
        return metas[0]
    raise Problem('Nenhum calendário disponível.')


def public_meta(m):
    return {'id': m['id'], 'name': m.get('name', ''), 'color': m.get('color', 'blue'),
            'source': m.get('source', 'local'), 'accountId': m.get('accountId', ''),
            'components': m.get('components', ['VEVENT', 'VTODO']), 'hidden': bool(m.get('hidden')),
            'readOnly': bool(m.get('readOnly'))}


# ---------------------------------------------------------------- objects

def objects(cid):
    """[(file name, VCALENDAR)] of a calendar; unreadable files are skipped."""
    out = []
    folder = cal_dir(cid)
    try:
        names = sorted(os.listdir(folder))
    except FileNotFoundError:
        return out
    for name in names:
        if not name.endswith('.ics') or name.startswith('.'):
            continue
        cal = read_object(cid, name)
        if cal is not None:
            out.append((name, cal))
    return out


def read_object(cid, name):
    path = cal_dir(cid) / name
    try:
        if path.stat().st_size > OBJECT_LIMIT:
            return None
        roots = ics.parse(path.read_text(encoding='utf-8', errors='replace'))
    except (OSError, ics.ICalError):
        return None
    return next((r for r in roots if r.name == 'VCALENDAR'), None)


def sync_state(cid):
    state = read_json(cal_dir(cid) / '.sync.json', {})
    state.setdefault('objects', {})
    state.setdefault('dirty', [])
    state.setdefault('deleted', [])
    return state


def save_state(cid, state):
    write_json(cal_dir(cid) / '.sync.json', state)


def write_object(meta, name, cal):
    """Write one object; CalDAV calendars remember it must be uploaded."""
    cid = meta['id']
    ics.ensure_timezones(cal)
    text = ics.serialize(cal)
    if len(text.encode()) > OBJECT_LIMIT:
        raise Problem('O item é grande demais.')
    with locked(cal_dir(cid) / '.lock'):
        write_atomic(cal_dir(cid) / name, text)
        if meta.get('source') == 'caldav':
            state = sync_state(cid)
            if name not in state['dirty']:
                state['dirty'].append(name)
            save_state(cid, state)


def remove_object(meta, name):
    cid = meta['id']
    with locked(cal_dir(cid) / '.lock'):
        try:
            os.unlink(cal_dir(cid) / name)
        except FileNotFoundError:
            pass
        if meta.get('source') == 'caldav':
            state = sync_state(cid)
            known = state['objects'].pop(name, None)
            if known and known.get('href'):
                state['deleted'].append({'href': known['href'], 'etag': known.get('etag', '')})
            state['dirty'] = [d for d in state['dirty'] if d != name]
            save_state(cid, state)


def file_for_uid(uid):
    if SAFE_NAME.fullmatch(uid + '.ics') and len(uid) <= 150:
        return uid + '.ics'
    return hashlib.sha1(uid.encode()).hexdigest() + '.ics'


def find_uid(uid, calendars=None):
    """(meta, file name, VCALENDAR) holding a UID, or None."""
    for meta in calendars or all_meta():
        name = file_for_uid(uid)
        cal = read_object(meta['id'], name)
        if cal is not None and any(c.text('UID') == uid for c in cal.subs):
            return meta, name, cal
    for meta in calendars or all_meta():
        for name, cal in objects(meta['id']):
            if any(c.text('UID') == uid for c in cal.subs):
                return meta, name, cal
    return None


def writable(cid, component):
    meta = load_meta(cid)
    if meta.get('readOnly'):
        raise Problem('Este calendário é somente leitura.')
    if component not in meta.get('components', ['VEVENT', 'VTODO']):
        raise Problem('Este calendário não aceita este tipo de item.' if component == 'VEVENT'
                         else 'Esta lista não aceita tarefas.')
    return meta


# ================================================================ dates for the UI

def iso_local(value):
    if isinstance(value, dt.datetime):
        return ics.to_local(value).strftime('%Y-%m-%dT%H:%M:%S')
    return value.strftime('%Y-%m-%dT00:00:00')


def parse_day(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise Problem('Data inválida.')
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        raise Problem('Data inválida.')


def parse_local(value):
    """'YYYY-MM-DDTHH:MM[:SS]' in local time -> aware datetime."""
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?', value):
        raise Problem('Data e hora inválidas.')
    try:
        naive = dt.datetime.fromisoformat(value)
    except ValueError:
        raise Problem('Data e hora inválidas.')
    return naive.replace(tzinfo=ics.local_zone())


def day_start(day):
    return dt.datetime(day.year, day.month, day.day, tzinfo=ics.local_zone())


WEEKDAY_NAMES = ('segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo')
ORDINALS = {1: 'primeira', 2: 'segunda', 3: 'terceira', 4: 'quarta', 5: 'quinta', -1: 'última'}


def rule_summary(comp):
    prop = comp.get('RRULE')
    empty = {'freq': 'NONE', 'interval': 1, 'count': 0, 'until': '', 'byday': [], 'complex': False, 'text': ''}
    if prop is None:
        return empty
    try:
        rule = ics.parse_rrule(prop.value)
    except ics.ICalError:
        rule = None
    if rule is None:
        return dict(empty, complex=True, text='Repete (regra personalizada)')
    simple = not (rule.bymonthday or rule.bymonth or rule.byyearday or rule.bysetpos
                  or any(n for n, _ in rule.byday) or (rule.byday and rule.freq != 'WEEKLY'))
    unit = {'DAILY': ('dia', 'dias', 'Diariamente'), 'WEEKLY': ('semana', 'semanas', 'Semanalmente'),
            'MONTHLY': ('mês', 'meses', 'Mensalmente'), 'YEARLY': ('ano', 'anos', 'Anualmente')}[rule.freq]
    text = unit[2] if rule.interval == 1 else 'A cada %d %s' % (rule.interval, unit[1])
    if rule.byday and rule.freq == 'WEEKLY':
        text += ' (%s)' % ', '.join(WEEKDAY_NAMES[w] for _, w in sorted(rule.byday, key=lambda x: x[1]))
    elif rule.byday and rule.freq == 'MONTHLY':
        text += ' (%s)' % ', '.join(('%s %s' % (ORDINALS.get(n, '%dª' % n), WEEKDAY_NAMES[w])) if n
                                    else WEEKDAY_NAMES[w] for n, w in rule.byday)
    elif rule.bymonthday:
        text += ' (dia %s)' % ', '.join(str(d) if d > 0 else 'último' if d == -1 else str(d) for d in rule.bymonthday)
    if rule.count:
        text += ', %d vezes' % rule.count
    until = ''
    if rule.until is not None:
        day = rule.until if not isinstance(rule.until, dt.datetime) else rule.until.date()
        if isinstance(rule.until, dt.datetime) and rule.until.tzinfo:
            day = ics.to_local(rule.until).date()
        until = day.isoformat()
        text += ', até %s' % day.strftime('%d/%m/%Y')
    return {'freq': rule.freq, 'interval': rule.interval, 'count': rule.count or 0, 'until': until,
            'byday': [ics.WEEKDAYS[w] for _, w in rule.byday if not _], 'complex': not simple, 'text': text}


def people(comp):
    organizer = ics.person(comp.get('ORGANIZER'))
    attendees = [ics.person(p) for p in comp.all('ATTENDEE')]
    return organizer, attendees


def event_dict(meta, name, master, comp, start, end, key):
    organizer, attendees = people(comp)
    alarm = ics.first_relative_alarm(comp)
    return {
        'id': '%s/%s/%s' % (meta['id'], name, key or ''),
        'calendarId': meta['id'],
        'file': name,
        'uid': comp.text('UID'),
        'title': comp.text('SUMMARY').strip() or 'Sem título',
        'location': comp.text('LOCATION'),
        'notes': comp.text('DESCRIPTION')[:20000],
        'start': iso_local(start),
        'end': iso_local(end),
        'allDay': not isinstance(start, dt.datetime),
        'recurring': master.get('RRULE') is not None or bool(master.all('RDATE')),
        'recurrenceId': key or '',
        'rrule': rule_summary(master),
        'alarm': -1 if alarm is None else alarm,
        'organizer': organizer,
        'attendees': attendees,
        'status': comp.text('STATUS').upper(),
        'color': meta.get('color', 'blue'),
        'readOnly': bool(meta.get('readOnly')),
    }


def grouped_events(cal):
    """{uid: (master or None, [overrides])} of a VCALENDAR."""
    groups = {}
    for comp in cal.walk('VEVENT'):
        uid = comp.text('UID')
        master, overrides = groups.get(uid, (None, []))
        if comp.get('RECURRENCE-ID') is None:
            master = master or comp
        else:
            overrides.append(comp)
        groups[uid] = (master, overrides)
    return groups


def occurrences(range_start, range_end, metas=None, skip_hidden=False):
    out = []
    for meta in metas if metas is not None else all_meta():
        if skip_hidden and meta.get('hidden'):
            continue
        if 'VEVENT' not in meta.get('components', ['VEVENT']):
            continue
        for name, cal in objects(meta['id']):
            zones = ics.timezones_of(cal)
            for uid, (master, overrides) in grouped_events(cal).items():
                items = []
                if master is not None:
                    items = ics.expand(master, overrides, range_start, range_end, zones)
                else:   # instances we were invited to without the series
                    for o in overrides:
                        s, e, _ = ics.event_bounds(o, zones)
                        if s is not None and ics._overlaps(s, e, range_start, range_end):
                            key = ics.instance_key(ics.parse_dt(o.get('RECURRENCE-ID'), zones))
                            items.append((s, e, key, o))
                for s, e, key, comp in items:
                    if comp.text('STATUS').upper() == 'CANCELLED':
                        continue
                    out.append((meta, name, master or comp, comp, s, e, key))
                    if len(out) > MAX_OCCURRENCES:
                        raise Problem('Há eventos demais neste período.')
    out.sort(key=lambda o: (ics.to_local(o[4]), o[3].text('SUMMARY')))
    return out


def op_range(req):
    start, end = parse_day(req.get('start')), parse_day(req.get('end'))
    if end <= start or (end - start).days > 400:
        raise Problem('Período inválido.')
    return [event_dict(*o) for o in occurrences(day_start(start), day_start(end))]


# ================================================================ events

def rrule_value(rule):
    """RRULE text from the dialog's fields, '' for none."""
    if not isinstance(rule, dict):
        raise Problem('Repetição inválida.')
    freq = rule.get('freq', 'NONE')
    if freq == 'NONE':
        return ''
    if freq not in ('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'):
        raise Problem('Repetição inválida.')
    parts = ['FREQ=' + freq]
    try:
        interval = int(rule.get('interval') or 1)
        count = int(rule.get('count') or 0)
    except (TypeError, ValueError):
        raise Problem('Repetição inválida.')
    if not 1 <= interval <= 999 or not 0 <= count <= 999:
        raise Problem('Repetição inválida.')
    if interval > 1:
        parts.append('INTERVAL=%d' % interval)
    byday = rule.get('byday') or []
    if freq == 'WEEKLY' and byday:
        if not isinstance(byday, list) or any(d not in ics.WEEKDAYS for d in byday):
            raise Problem('Repetição inválida.')
        parts.append('BYDAY=' + ','.join(sorted(set(byday), key=ics.WEEKDAYS.index)))
    if count:
        parts.append('COUNT=%d' % count)
    elif rule.get('until'):
        parts.append('UNTIL=%sT235959Z' % ics.format_date(parse_day(rule['until'])))
    return ';'.join(parts)


def alarm_value(value):
    if value is None or value == -1:
        return None
    # Negative: after the start (all-day events: "on the day at 9:00" is -540)
    if not isinstance(value, int) or isinstance(value, bool) or not -1440 <= value <= 60 * 24 * 28:
        raise Problem('Lembrete inválido.')
    return value


def event_times(ev):
    all_day = bool(ev.get('allDay'))
    if all_day:
        start = parse_day(ev.get('start', '')[:10])
        last = parse_day(ev.get('end', '')[:10] or ev.get('start', '')[:10])
        if last < start:
            raise Problem('O fim precisa ser depois do início.')
        return start, last + dt.timedelta(days=1), True
    start, end = parse_local(ev.get('start')), parse_local(ev.get('end') or ev.get('start'))
    if end < start:
        raise Problem('O fim precisa ser depois do início.')
    if (end - start).days > 366:
        raise Problem('O evento é longo demais.')
    return start, end, False


def stamp(comp, bump=True):
    now = ics.format_utc(dt.datetime.now(ics.UTC))
    comp.set('DTSTAMP', now)
    comp.set('LAST-MODIFIED', now)
    if bump:
        comp.set('SEQUENCE', str(ics.sequence(comp) + 1))


def set_times(comp, start, end):
    comp.remove('DURATION')
    start_prop = ics.date_prop('DTSTART', start)
    comp.set('DTSTART', start_prop.value, start_prop.params)
    end_prop = ics.date_prop('DTEND', end)
    comp.set('DTEND', end_prop.value, end_prop.params)


def apply_fields(comp, ev):
    comp.set_text('SUMMARY', line_field(ev.get('title'), 500, 'Título') or 'Sem título')
    comp.set_text('LOCATION', line_field(ev.get('location'), 500, 'Local'))
    comp.set_text('DESCRIPTION', text_field(ev.get('notes'), 20000, 'Notas'))
    if 'alarm' in ev:
        ics.set_alarm(comp, alarm_value(ev.get('alarm')), comp.text('SUMMARY'))


def recurrence_prop(master, key, zones):
    """RECURRENCE-ID/EXDATE value for an instance key, in the master's DTSTART form."""
    start = ics.parse_dt(master.get('DTSTART'), zones)
    when = ics.parse_date_value(key)
    if isinstance(start, dt.datetime):
        if not isinstance(when, dt.datetime):
            raise Problem('Ocorrência inválida.')
        when = when.astimezone(start.tzinfo)
        dtstart = master.get('DTSTART')
        if 'TZID' in dtstart.params:
            return ics.Prop('X', ics.format_naive(when), {'TZID': dtstart.params['TZID']})
        if ics.is_floating(dtstart):
            return ics.Prop('X', ics.format_naive(when))
        return ics.Prop('X', ics.format_utc(when))
    if isinstance(when, dt.datetime):
        when = ics.to_local(when).date()
    return ics.Prop('X', ics.format_date(when), {'VALUE': 'DATE'})


def shift_value(prop, value, delta, zones):
    """One EXDATE/RECURRENCE-ID value moved by `delta`, written in the same form."""
    when = ics.parse_date_value(value, prop.params, zones)
    if not isinstance(when, dt.datetime):
        return ics.format_date(when + dt.timedelta(days=delta.days))
    local = ics.to_local(when).replace(tzinfo=None) + delta
    moved = local.replace(tzinfo=ics.local_zone())
    if 'TZID' in prop.params:
        return ics.format_naive(moved.astimezone(when.tzinfo))
    if value.strip().endswith('Z'):
        return ics.format_utc(moved)
    return ics.format_naive(moved)


def shift_instances(cal, master, old_start, new_start, zones):
    """Moving a series moves its exceptions too, or they would no longer match."""
    uid = master.text('UID')
    overrides = [c for c in cal.walk('VEVENT') if c.text('UID') == uid and c.get('RECURRENCE-ID') is not None]
    if isinstance(old_start, dt.datetime) != isinstance(new_start, dt.datetime):
        master.remove('EXDATE')
        cal.subs = [c for c in cal.subs if c not in overrides]
        return
    if isinstance(old_start, dt.datetime):
        delta = ics.to_local(new_start).replace(tzinfo=None) - ics.to_local(old_start).replace(tzinfo=None)
    else:
        delta = new_start - old_start
    try:
        for prop in master.all('EXDATE'):
            prop.value = ','.join(shift_value(prop, v, delta, zones) for v in prop.value.split(','))
        for o in overrides:
            rid = o.get('RECURRENCE-ID')
            rid.value = shift_value(rid, rid.value, delta, zones)
    except ics.ICalError:
        master.remove('EXDATE')
        cal.subs = [c for c in cal.subs if c not in overrides]


def op_save_event(req):
    ev = req.get('event')
    if not isinstance(ev, dict):
        raise Problem('Evento inválido.')
    cid = check_id(ev.get('calendarId') or default_calendar()['id'])
    meta = writable(cid, 'VEVENT')
    start, end, all_day = event_times(ev)
    scope = ev.get('scope', 'all')
    name = ev.get('file') or ''
    original_cid = check_id(ev.get('originalCalendarId') or cid)

    if not name:   # new event
        cal = ics.new_calendar()
        comp = ics.Component('VEVENT')
        uid = ics.new_uid()
        comp.add('UID', uid)
        now = ics.format_utc(dt.datetime.now(ics.UTC))
        comp.add('CREATED', now)
        comp.add('SEQUENCE', '0')
        stamp(comp, bump=False)
        set_times(comp, start, end)
        if ev.get('rrule'):
            value = rrule_value(ev['rrule'])
            if value:
                comp.set('RRULE', value)
        apply_fields(comp, ev)
        cal.subs.append(comp)
        write_object(meta, file_for_uid(uid), cal)
        return {'calendarId': cid, 'file': file_for_uid(uid), 'uid': uid}

    check_name(name)
    source = load_meta(original_cid) if original_cid != cid else meta
    if source.get('readOnly'):
        raise Problem('Este calendário é somente leitura.')
    cal = read_object(original_cid, name)
    if cal is None:
        raise Problem('O evento não existe mais.')
    zones = ics.timezones_of(cal)
    uid = ev.get('uid') or ''
    events = [c for c in cal.walk('VEVENT') if not uid or c.text('UID') == uid]
    master = next((c for c in events if c.get('RECURRENCE-ID') is None), None)
    key = ev.get('recurrenceId') or ''

    if scope == 'this' and key:
        if original_cid != cid:
            raise Problem('Para mudar de calendário, altere todas as ocorrências.')
        target = None
        for c in events:
            rid = c.get('RECURRENCE-ID')
            if rid is not None and ics.instance_key(ics.parse_dt(rid, zones)) == key:
                target = c
        if target is None:
            if master is None:
                raise Problem('O evento não existe mais.')
            target = ics.Component('VEVENT')
            skip = {'RRULE', 'RDATE', 'EXDATE', 'DTSTART', 'DTEND', 'DURATION', 'RECURRENCE-ID',
                    'SEQUENCE', 'DTSTAMP', 'LAST-MODIFIED'}
            target.props = [ics.Prop(p.name, p.value, p.params) for p in master.props if p.name not in skip]
            rid = recurrence_prop(master, key, zones)
            target.add('RECURRENCE-ID', rid.value, rid.params)
            target.add('SEQUENCE', str(ics.sequence(master)))
            target.subs = [ics.Component(s.name, list(s.props), list(s.subs)) for s in master.subs]
            cal.subs.append(target)
        set_times(target, start, end)
        apply_fields(target, ev)
        stamp(target)
        write_object(meta, name, cal)
        return {'calendarId': cid, 'file': name, 'uid': target.text('UID')}

    comp = master or (events[0] if events else None)
    if comp is None:
        raise Problem('O evento não existe mais.')
    recurring = comp.get('RRULE') is not None or bool(comp.all('RDATE'))
    if recurring and ev.get('occurrenceStart'):
        # The dialog shows one instance: move the series by the same amount
        old_start, _, old_all_day = ics.event_bounds(comp, zones)
        occurrence = parse_day(ev['occurrenceStart'][:10]) if old_all_day \
            else parse_local(ev['occurrenceStart'][:16])
        if old_all_day == all_day:
            if all_day:
                shift = start - occurrence
                new_start = old_start + shift
            else:
                shift = start.replace(tzinfo=None) - occurrence.replace(tzinfo=None)
                new_start = ics.to_local(old_start).replace(tzinfo=None) + shift
                new_start = new_start.replace(tzinfo=ics.local_zone())
            end = ics.add_wall(new_start, (end - start) if all_day
                               else end.replace(tzinfo=None) - start.replace(tzinfo=None))
            start = new_start
    old_start, old_end, old_all_day = ics.event_bounds(comp, zones)
    if (iso_local(old_start), iso_local(old_end), old_all_day) != (iso_local(start), iso_local(end), all_day):
        if recurring and iso_local(old_start) != iso_local(start):
            shift_instances(cal, comp, old_start, start, zones)
        set_times(comp, start, end)
    if ev.get('rrule') is not None and isinstance(ev.get('rrule'), dict):
        value = rrule_value(ev['rrule'])
        if value:
            comp.set('RRULE', value)
        else:
            comp.remove('RRULE')
            comp.remove('EXDATE')
            cal.subs = [c for c in cal.subs if not (c.name == 'VEVENT' and c.get('RECURRENCE-ID') is not None
                                                    and c.text('UID') == comp.text('UID'))]
    apply_fields(comp, ev)
    stamp(comp)
    if original_cid != cid:
        new_name = file_for_uid(comp.text('UID'))
        write_object(meta, new_name, cal)
        remove_object(source, name)
        name = new_name
    else:
        write_object(meta, name, cal)
    return {'calendarId': cid, 'file': name, 'uid': comp.text('UID')}


def op_delete_event(req):
    cid = check_id(req.get('calendarId'))
    name = check_name(req.get('file'))
    meta = load_meta(cid)
    if meta.get('readOnly'):
        raise Problem('Este calendário é somente leitura.')
    key = req.get('recurrenceId') or ''
    if req.get('scope') != 'this' or not key:
        remove_object(meta, name)
        return True
    cal = read_object(cid, name)
    if cal is None:
        return True
    zones = ics.timezones_of(cal)
    uid = req.get('uid') or ''
    events = [c for c in cal.walk('VEVENT') if not uid or c.text('UID') == uid]
    master = next((c for c in events if c.get('RECURRENCE-ID') is None), None)

    def is_instance(c):
        rid = c.get('RECURRENCE-ID')
        return rid is not None and ics.instance_key(ics.parse_dt(rid, zones)) == key

    cal.subs = [c for c in cal.subs if not (c.name == 'VEVENT' and is_instance(c))]
    if master is not None:
        prop = recurrence_prop(master, key, zones)
        master.add('EXDATE', prop.value, prop.params)
        stamp(master)
    if not cal.walk('VEVENT'):
        remove_object(meta, name)
    else:
        write_object(meta, name, cal)
    return True


# ================================================================ tasks

def task_dict(meta, name, comp, zones):
    due = None
    due_prop = comp.get('DUE')
    if due_prop is not None:
        try:
            due = ics.parse_dt(due_prop, zones)
        except ics.ICalError:
            due = None
    status = comp.text('STATUS').upper()
    try:
        priority = int(comp.text('PRIORITY', '0') or 0)
    except ValueError:
        priority = 0
    completed = ''
    if comp.get('COMPLETED') is not None:
        try:
            completed = iso_local(ics.parse_dt(comp.get('COMPLETED'), zones))
        except ics.ICalError:
            completed = ''
    return {
        'id': '%s/%s' % (meta['id'], name),
        'calendarId': meta['id'],
        'file': name,
        'uid': comp.text('UID'),
        'title': comp.text('SUMMARY').strip() or 'Sem título',
        'notes': comp.text('DESCRIPTION')[:20000],
        'due': iso_local(due) if due is not None else '',
        'dueAllDay': due is not None and not isinstance(due, dt.datetime),
        'priority': max(0, min(9, priority)),
        'done': status == 'COMPLETED' or comp.get('COMPLETED') is not None,
        'completed': completed,
        'color': meta.get('color', 'blue'),
        'listName': meta.get('name', ''),
        'readOnly': bool(meta.get('readOnly')),
    }


def op_tasks(req):
    out = []
    for meta in all_meta():
        if 'VTODO' not in meta.get('components', []):
            continue
        for name, cal in objects(meta['id']):
            zones = ics.timezones_of(cal)
            for comp in cal.walk('VTODO'):
                if comp.get('RECURRENCE-ID') is None and comp.text('STATUS').upper() != 'CANCELLED':
                    out.append(task_dict(meta, name, comp, zones))
    return out


def set_done(comp, done):
    if done:
        comp.set('STATUS', 'COMPLETED')
        comp.set('COMPLETED', ics.format_utc(dt.datetime.now(ics.UTC)))
        comp.set('PERCENT-COMPLETE', '100')
    else:
        comp.set('STATUS', 'NEEDS-ACTION')
        comp.remove('COMPLETED')
        comp.remove('PERCENT-COMPLETE')


def op_save_task(req):
    task = req.get('task')
    if not isinstance(task, dict):
        raise Problem('Tarefa inválida.')
    cid = check_id(task.get('calendarId') or default_calendar('VTODO')['id'])
    meta = writable(cid, 'VTODO')
    name = task.get('file') or ''
    original_cid = check_id(task.get('originalCalendarId') or cid)
    if name:
        check_name(name)
        cal = read_object(original_cid, name)
        if cal is None:
            raise Problem('A tarefa não existe mais.')
        comp = next(iter(cal.walk('VTODO')), None)
        if comp is None:
            raise Problem('A tarefa não existe mais.')
        stamp(comp)
    else:
        cal = ics.new_calendar()
        comp = ics.Component('VTODO')
        uid = ics.new_uid()
        comp.add('UID', uid)
        comp.add('CREATED', ics.format_utc(dt.datetime.now(ics.UTC)))
        comp.add('SEQUENCE', '0')
        stamp(comp, bump=False)
        cal.subs.append(comp)
        set_done(comp, False)
    title = line_field(task.get('title'), 500, 'Título')
    if not title:
        raise Problem('Dê um título à tarefa.')
    comp.set_text('SUMMARY', title)
    comp.set_text('DESCRIPTION', text_field(task.get('notes'), 20000, 'Notas'))
    due = task.get('due') or ''
    had_due = comp.get('DUE') is not None
    if due:
        value = parse_day(due) if len(due) == 10 else parse_local(due[:16])
        prop = ics.date_prop('DUE', value)
        comp.set('DUE', prop.value, prop.params)
        # A start after the new due date would make the task invalid
        if comp.get('DTSTART') is not None:
            try:
                begin = ics.parse_dt(comp.get('DTSTART'))
                if ics.to_local(begin) > ics.to_local(value):
                    comp.remove('DTSTART')
            except ics.ICalError:
                comp.remove('DTSTART')
    else:
        comp.remove('DUE')
    if not due and had_due:
        comp.subs = [s for s in comp.subs if s.name != 'VALARM']
    try:
        priority = int(task.get('priority') or 0)
    except (TypeError, ValueError):
        raise Problem('Prioridade inválida.')
    if not 0 <= priority <= 9:
        raise Problem('Prioridade inválida.')
    if priority:
        comp.set('PRIORITY', str(priority))
    else:
        comp.remove('PRIORITY')
    if 'done' in task:
        set_done(comp, bool(task.get('done')))
    if original_cid != cid and name:
        new_name = file_for_uid(comp.text('UID'))
        write_object(meta, new_name, cal)
        remove_object(load_meta(original_cid), name)
        name = new_name
    else:
        name = name or file_for_uid(comp.text('UID'))
        write_object(meta, name, cal)
    return task_dict(meta, name, comp, ics.timezones_of(cal))


def op_complete_task(req):
    cid = check_id(req.get('calendarId'))
    name = check_name(req.get('file'))
    meta = writable(cid, 'VTODO')
    cal = read_object(cid, name)
    comp = next(iter(cal.walk('VTODO')), None) if cal is not None else None
    if comp is None:
        raise Problem('A tarefa não existe mais.')
    set_done(comp, bool(req.get('done')))
    stamp(comp)
    write_object(meta, name, cal)
    return task_dict(meta, name, comp, ics.timezones_of(cal))


def op_delete_task(req):
    cid = check_id(req.get('calendarId'))
    meta = load_meta(cid)
    if meta.get('readOnly'):
        raise Problem('Esta lista é somente leitura.')
    remove_object(meta, check_name(req.get('file')))
    return True


# ================================================================ alarms

def op_alarms(req):
    """Reminders that fire in [from, to] (epoch seconds), for events and tasks."""
    try:
        start = dt.datetime.fromtimestamp(int(req.get('from')), ics.UTC)
        end = dt.datetime.fromtimestamp(int(req.get('to')), ics.UTC)
    except (TypeError, ValueError, OverflowError, OSError):
        raise Problem('Período inválido.')
    if end <= start or end - start > dt.timedelta(days=8):
        raise Problem('Período inválido.')
    out = []
    metas = all_meta()
    for meta, name, master, comp, s, e, key in occurrences(start - dt.timedelta(days=2),
                                                           end + dt.timedelta(days=29), metas):
        mine = [p for p in comp.all('ATTENDEE') if p.params.get('PARTSTAT', '').upper() == 'DECLINED']
        if mine and len(mine) == len(comp.all('ATTENDEE')):
            continue
        for when in ics.alarm_times(comp, s, e):
            if start <= when <= end:
                out.append({
                    'key': hashlib.sha1(('%s|%s|%s|%s' % (meta['id'], comp.text('UID'), key or '',
                                                           ics.format_utc(when))).encode()).hexdigest(),
                    'when': int(when.timestamp()),
                    'kind': 'event',
                    'title': comp.text('SUMMARY').strip() or 'Sem título',
                    'start': iso_local(s),
                    'allDay': not isinstance(s, dt.datetime),
                    'location': comp.text('LOCATION'),
                })
    for meta in metas:
        if 'VTODO' not in meta.get('components', []):
            continue
        for name, cal in objects(meta['id']):
            zones = ics.timezones_of(cal)
            for comp in cal.walk('VTODO'):
                if comp.text('STATUS').upper() in ('COMPLETED', 'CANCELLED') or comp.get('COMPLETED') is not None:
                    continue
                try:
                    due = ics.parse_dt(comp.get('DUE'), zones)
                    begin = ics.parse_dt(comp.get('DTSTART'), zones)
                except ics.ICalError:
                    continue
                if due is None:
                    continue
                if comp.walk('VALARM'):
                    times = ics.alarm_times(comp, begin or due, due)
                elif isinstance(due, dt.datetime):
                    times = [ics.to_local(due)]
                else:
                    times = [ics.to_local(due) + dt.timedelta(hours=9)]
                for when in times:
                    if start <= when <= end:
                        out.append({
                            'key': hashlib.sha1(('%s|%s|task|%s' % (meta['id'], comp.text('UID'),
                                                                     ics.format_utc(when))).encode()).hexdigest(),
                            'when': int(when.timestamp()),
                            'kind': 'task',
                            'title': comp.text('SUMMARY').strip() or 'Sem título',
                            'start': iso_local(due),
                            'allDay': not isinstance(due, dt.datetime),
                            'location': '',
                        })
    out.sort(key=lambda a: a['when'])
    return out


# ================================================================ calendars

def op_calendars(req):
    metas = all_meta()
    accounts = [{k: a.get(k, '') for k in ('id', 'name', 'provider', 'username', 'email', 'lastSync', 'lastError')}
                for a in read_accounts()]
    return {
        'calendars': [public_meta(m) for m in metas],
        'defaultCalendar': default_calendar()['id'],
        'defaultTaskList': default_calendar('VTODO')['id'],
        'accounts': accounts,
    }


def op_calendar_save(req):
    data = req.get('calendar')
    if not isinstance(data, dict):
        raise Problem('Calendário inválido.')
    name = line_field(data.get('name'), 120, 'Nome')
    color = data.get('color', 'blue')
    if color not in COLORS:
        raise Problem('Cor inválida.')
    with locked(CALENDARS / '.lock'):
        if data.get('id'):
            meta = load_meta(check_id(data['id']))
        else:
            if not name:
                raise Problem('Dê um nome ao calendário.')
            meta = {'id': 'local-' + uuid.uuid4().hex[:10], 'source': 'local', 'components': ['VEVENT', 'VTODO'],
                    'order': len(all_meta())}
        if name:
            meta['name'] = name
        meta['color'] = color
        if 'hidden' in data:
            meta['hidden'] = bool(data['hidden'])
        save_meta(meta)
    if data.get('makeDefault'):
        values = settings()
        values['defaultCalendar'] = meta['id']
        write_json(CALENDARS / 'settings.json', values)
    return public_meta(meta)


def op_calendar_delete(req):
    meta = load_meta(check_id(req.get('id')))
    if meta.get('source') != 'local':
        raise Problem('Calendários sincronizados são removidos junto com a conta.')
    local = [m for m in all_meta() if m.get('source') == 'local']
    if len(local) <= 1:
        raise Problem('Mantenha pelo menos um calendário local.')
    shutil.rmtree(cal_dir(meta['id']))
    values = settings()
    for key in ('defaultCalendar', 'defaultTaskList'):
        if values.get(key) == meta['id']:
            values.pop(key)
    write_json(CALENDARS / 'settings.json', values)
    return True


def op_set_default(req):
    meta = load_meta(check_id(req.get('id')))
    key = 'defaultTaskList' if req.get('kind') == 'tasks' else 'defaultCalendar'
    values = settings()
    values[key] = meta['id']
    write_json(CALENDARS / 'settings.json', values)
    return True


# ================================================================ import and invites

def split_objects(cal):
    """[(uid, VCALENDAR with that UID's components + needed VTIMEZONEs)]"""
    zones = cal.walk('VTIMEZONE')
    groups = {}
    for comp in cal.subs:
        if comp.name in ('VEVENT', 'VTODO'):
            uid = comp.text('UID') or ics.new_uid()
            if comp.get('UID') is None:
                comp.add('UID', uid)
            groups.setdefault(uid, []).append(comp)
    out = []
    for uid, comps in groups.items():
        piece = ics.new_calendar()
        used = {p.params.get('TZID') for c in comps for p in c.props if p.params.get('TZID')}
        piece.subs = [z for z in zones if z.text('TZID') in used] + comps
        out.append((uid, piece))
    return out


def op_import_ics(req):
    text = text_field(req.get('text'), 900 * 1024, 'Arquivo')
    roots = ics.parse(text)
    cal = next((r for r in roots if r.name == 'VCALENDAR'), None)
    if cal is None:
        raise Problem('O arquivo não é um calendário.')
    cid = check_id(req.get('calendarId') or default_calendar()['id'])
    meta = load_meta(cid)
    if meta.get('readOnly'):
        raise Problem('Este calendário é somente leitura.')
    count = 0
    for uid, piece in split_objects(cal):
        kind = piece.subs[-1].name
        if kind not in meta.get('components', ['VEVENT', 'VTODO']):
            continue
        existing = find_uid(uid, [meta])
        write_object(meta, existing[1] if existing else file_for_uid(uid), piece)
        count += 1
    if not count:
        raise Problem('Nenhum evento ou tarefa encontrado no arquivo.')
    return {'imported': count, 'calendarId': cid}


def parse_invite(text):
    text = text_field(text, 900 * 1024, 'Convite')
    roots = ics.parse(text)
    cal = next((r for r in roots if r.name == 'VCALENDAR'), None)
    if cal is None or not cal.walk('VEVENT'):
        raise Problem('Este convite não tem um evento.')
    method = cal.text('METHOD', 'PUBLISH').upper().strip() or 'PUBLISH'
    events = cal.walk('VEVENT')
    main = next((e for e in events if e.get('RECURRENCE-ID') is None), events[0])
    return cal, method, main


def op_invite_parse(req):
    cal, method, main = parse_invite(req.get('text'))
    zones = ics.timezones_of(cal)
    email = (req.get('email') or '').strip().lower()
    start, end, all_day = ics.event_bounds(main, zones)
    if start is None:
        raise Problem('O convite não tem data.')
    organizer, attendees = people(main)
    mine = ics.find_attendee(main, email) if email else None
    uid = main.text('UID')
    existing = find_uid(uid) if uid else None
    info = None
    if existing:
        meta, name, stored = existing
        comp = next((c for c in stored.walk('VEVENT') if c.text('UID') == uid and c.get('RECURRENCE-ID') is None),
                    None) or next(iter(stored.walk('VEVENT')), None)
        stored_mine = ics.find_attendee(comp, email) if comp is not None and email else None
        info = {'calendarId': meta['id'], 'calendarName': meta.get('name', ''), 'file': name,
                'sequence': ics.sequence(comp) if comp is not None else 0,
                'partstat': stored_mine.params.get('PARTSTAT', '').upper() if stored_mine is not None else ''}
    conflicts = []
    if method in ('REQUEST', 'PUBLISH') and not all_day:
        for meta, name, master, comp, s, e, key in occurrences(ics.to_local(start), ics.to_local(end)):
            if comp.text('UID') == uid or not isinstance(s, dt.datetime):
                continue
            if comp.text('TRANSP').upper() == 'TRANSPARENT' or meta.get('hidden'):
                continue
            conflicts.append({'title': comp.text('SUMMARY') or 'Sem título', 'start': iso_local(s),
                              'end': iso_local(e), 'calendar': meta.get('name', '')})
            if len(conflicts) >= 5:
                break
    seq = ics.sequence(main)
    return {
        'method': method,
        'uid': uid,
        'sequence': seq,
        'title': main.text('SUMMARY').strip() or 'Sem título',
        'location': main.text('LOCATION'),
        'notes': main.text('DESCRIPTION')[:4000],
        'start': iso_local(start),
        'end': iso_local(end),
        'allDay': all_day,
        'recurring': main.get('RRULE') is not None,
        'ruleText': rule_summary(main)['text'],
        'recurrenceId': ics.instance_key(ics.parse_dt(main.get('RECURRENCE-ID'), zones))
        if main.get('RECURRENCE-ID') is not None else '',
        'organizer': organizer,
        'attendees': attendees,
        'myStatus': mine.params.get('PARTSTAT', 'NEEDS-ACTION').upper() if mine is not None else '',
        'existing': info,
        'outdated': bool(info and info['sequence'] > seq),
        'updated': bool(info and info['sequence'] < seq),
        'conflicts': conflicts,
    }


def op_invite_respond(req):
    cal, method, main = parse_invite(req.get('text'))
    partstat = req.get('partstat')
    if partstat not in ics.PARTSTATS:
        raise Problem('Resposta inválida.')
    email = (req.get('email') or '').strip()
    if not EMAIL.fullmatch(email):
        raise Problem('Não foi possível identificar o seu endereço de e-mail.')
    name = line_field(req.get('name'), 200, 'Nome')
    uid = main.text('UID')
    if not uid:
        raise Problem('Convite sem identificador.')
    organizer = ics.person(main.get('ORGANIZER'))
    if not organizer or not EMAIL.fullmatch(organizer['email']):
        raise Problem('O convite não informa o organizador.')
    existing = find_uid(uid)
    if existing and ics.sequence(next(iter(existing[2].walk('VEVENT')), main)) > ics.sequence(main) \
            and not req.get('force'):
        raise Problem('Este convite foi substituído por uma versão mais nova.')
    calendar_id = ''
    if partstat == 'DECLINED':
        if existing:
            remove_object(existing[0], existing[1])
    else:
        piece = next((p for u, p in split_objects(cal) if u == uid), None)
        for comp in piece.walk('VEVENT'):
            attendee = ics.find_attendee(comp, email)
            if attendee is None:
                attendee = comp.add('ATTENDEE', 'mailto:' + email, {'CN': name} if name else {})
            attendee.params['PARTSTAT'] = partstat
            attendee.params.pop('RSVP', None)
        if existing and not existing[0].get('readOnly'):
            meta, file_name = existing[0], existing[1]
        else:
            meta = load_meta(check_id(req.get('calendarId') or default_calendar()['id']))
            file_name = file_for_uid(uid)
        write_object(meta, file_name, piece)
        calendar_id = meta['id']
    reply = ics.build_reply(main, email, partstat, name)
    return {
        'replyIcs': reply,
        'subject': '%s: %s' % (PARTSTAT_WORDS[partstat], main.text('SUMMARY').strip() or 'Convite'),
        'organizer': organizer['email'],
        'calendarId': calendar_id,
    }


def op_invite_cancel(req):
    cal, method, main = parse_invite(req.get('text'))
    uid = main.text('UID')
    existing = find_uid(uid) if uid else None
    if not existing:
        return {'removed': False}
    meta, name, stored = existing
    rid = main.get('RECURRENCE-ID')
    if rid is not None:
        zones = ics.timezones_of(cal)
        key = ics.instance_key(ics.parse_dt(rid, zones))
        op_delete_event({'calendarId': meta['id'], 'file': name, 'uid': uid, 'scope': 'this', 'recurrenceId': key})
    else:
        remove_object(meta, name)
    return {'removed': True}


def op_invite_apply_reply(req):
    """The organizer received a REPLY: update that attendee's answer."""
    cal, method, main = parse_invite(req.get('text'))
    existing = find_uid(main.text('UID'))
    if not existing:
        raise Problem('O evento deste convite não está no seu calendário.')
    meta, name, stored = existing
    changed = False
    for answer in main.all('ATTENDEE'):
        for comp in stored.walk('VEVENT'):
            mine = ics.find_attendee(comp, ics.mailto(answer.value))
            if mine is not None and answer.params.get('PARTSTAT'):
                mine.params['PARTSTAT'] = answer.params['PARTSTAT'].upper()
                changed = True
    if changed:
        write_object(meta, name, stored)
    return {'updated': changed}


# ================================================================ CalDAV

NS = {'d': 'DAV:', 'c': 'urn:ietf:params:xml:ns:caldav', 'cs': 'http://calendarserver.org/ns/',
      'a': 'http://apple.com/ns/ical/'}
D, C, CS, A = ('{%s}' % NS[k] for k in ('d', 'c', 'cs', 'a'))


def read_accounts():
    return read_json(CONFIG / 'caldav-accounts.json', [])


def update_accounts(transform):
    with locked(CONFIG / 'caldav-accounts.lock'):
        data = transform(read_accounts())
        write_json(CONFIG / 'caldav-accounts.json', data)
    return data


def secret(account_id, value=None, remove=False):
    args = ['secret-tool', 'clear' if remove else 'lookup' if value is None else 'store']
    if value is not None:
        args += ['--label=Lingmo Mail (calendário)']
    args += ['application', SECRET_APP, 'account', account_id]
    try:
        result = subprocess.run(args, input=value, text=True, capture_output=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired):
        raise Problem('Não foi possível acessar o chaveiro. Desbloqueie o chaveiro da sessão e tente novamente.')
    if result.returncode and not remove:
        raise Problem('Não foi possível acessar o chaveiro. Desbloqueie o chaveiro da sessão e tente novamente.')
    return result.stdout.rstrip('\n')


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _open(request, timeout):
    """(status, headers, body) of one HTTPS request; replaced by tests."""
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler(context=TLS))
    try:
        response = opener.open(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        response = exc
    with contextlib.closing(response):
        body = response.read(HTTP_LIMIT + 1) if response.fp is not None else b''
        headers = {k.lower(): v for k, v in response.headers.items()} if response.headers else {}
        return response.status if hasattr(response, 'status') and response.status else response.code, headers, body


def _site(host):
    parts = (host or '').lower().split('.')
    return '.'.join(parts[-2:])


def http(method, url, auth, body=None, headers=None, depth=None):
    headers = dict(headers or {})
    origin = urllib.parse.urlsplit(url).hostname
    for _ in range(6):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != 'https' or not parts.hostname:
            raise DavError('O servidor de calendário precisa usar HTTPS.')
        send = dict(headers)
        send['User-Agent'] = 'Lingmo-Mail/1.0'
        # Credentials only to the same site the user typed (iCloud moves to pNN-caldav.icloud.com)
        if auth and _site(parts.hostname) == _site(origin):
            send['Authorization'] = 'Basic ' + base64.b64encode(('%s:%s' % auth).encode()).decode()
        if depth is not None:
            send['Depth'] = str(depth)
        if body is not None:
            send.setdefault('Content-Type', 'application/xml; charset=utf-8')
        request = urllib.request.Request(url, data=body.encode() if isinstance(body, str) else body,
                                         headers=send, method=method)
        status, reply_headers, data = _open(request, 30)
        if len(data) > HTTP_LIMIT:
            raise DavError('A resposta do servidor de calendário é grande demais.')
        if status in (301, 302, 303, 307, 308) and reply_headers.get('location'):
            url = urllib.parse.urljoin(url, reply_headers['location'])
            continue
        return status, reply_headers, data
    raise DavError('O servidor de calendário redirecionou demais.')


def dav_failure(status):
    if status == 401:
        return DavError('O servidor recusou o acesso. Confira o usuário e a senha de app.')
    if status == 403:
        return DavError('O servidor não permitiu esta operação.')
    if status == 404:
        return DavError('Calendário não encontrado no servidor.')
    if status >= 500:
        return DavError('O servidor de calendário está com problemas. Tente mais tarde.')
    return DavError('O servidor de calendário respondeu de forma inesperada (%d).' % status)


def parse_xml(data):
    if b'<!DOCTYPE' in data[:2048] or b'<!ENTITY' in data:
        raise DavError('Resposta inválida do servidor de calendário.')
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        raise DavError('Resposta inválida do servidor de calendário.')


def multistatus(data, base):
    """[{'href': absolute url, 'status': int, 'props': {tag: element}}]"""
    root = parse_xml(data)
    out = []
    for response in root.findall(D + 'response'):
        href = response.findtext(D + 'href', '').strip()
        if not href:
            continue
        status_text = response.findtext(D + 'status', '')
        props = {}
        for propstat in response.findall(D + 'propstat'):
            code = propstat.findtext(D + 'status', 'HTTP/1.1 200')
            if ' 200' not in code:
                continue
            prop = propstat.find(D + 'prop')
            if prop is not None:
                for child in prop:
                    props[child.tag] = child
        status = 200
        m = re.search(r' (\d{3})', status_text)
        if m:
            status = int(m[1])
        out.append({'href': urllib.parse.urljoin(base, href), 'status': status, 'props': props})
    return out


def propfind(url, auth, props, depth):
    body = ('<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="%s" xmlns:cs="%s" '
            'xmlns:a="%s"><d:prop>%s</d:prop></d:propfind>' % (NS['c'], NS['cs'], NS['a'], props))
    status, headers, data = http('PROPFIND', url, auth, body, depth=depth)
    if status != 207:
        raise dav_failure(status)
    return multistatus(data, url)


def href_of(element, base):
    if element is None:
        return ''
    href = element.findtext(D + 'href', '').strip()
    return urllib.parse.urljoin(base, href) if href else ''


def candidates(provider, email, server):
    out = []
    if provider in PROVIDERS:
        out += [PROVIDERS[provider], PROVIDERS[provider] + '.well-known/caldav']
    else:
        server = (server or '').strip()
        if server:
            if '://' not in server:
                server = 'https://' + server
            parts = urllib.parse.urlsplit(server)
            if parts.scheme != 'https' or not parts.hostname:
                raise DavError('Use um endereço HTTPS para o servidor de calendário.')
            if not re.fullmatch(r'[A-Za-z0-9.-]+', parts.hostname):
                raise DavError('Endereço do servidor inválido.')
            out.append(server)
            out.append('https://%s/.well-known/caldav' % parts.netloc)
        elif email and EMAIL.fullmatch(email):
            out.append('https://%s/.well-known/caldav' % email.rsplit('@', 1)[1].lower())
        else:
            raise DavError('Informe o endereço do servidor de calendário.')
    return out


def nearest_color(value):
    m = re.fullmatch(r'#?([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?', (value or '').strip())
    if not m:
        return None
    r, g, b = (int(m[1][i:i + 2], 16) / 255 for i in (0, 2, 4))
    high, low = max(r, g, b), min(r, g, b)
    if high - low < 0.12:
        return 'grey'
    if high == r:
        hue = (60 * ((g - b) / (high - low))) % 360
    elif high == g:
        hue = 60 * ((b - r) / (high - low)) + 120
    else:
        hue = 60 * ((r - g) / (high - low)) + 240
    for limit, name in ((15, 'red'), (65, 'orange'), (170, 'green'), (255, 'blue'), (290, 'purple'),
                        (340, 'pink'), (361, 'red')):
        if hue < limit:
            return name
    return 'blue'


def discover(provider, email, server, username, password):
    auth = (username, password)
    principal = ''
    last = None
    for url in candidates(provider, email, server):
        try:
            found = propfind(url, auth, '<d:current-user-principal/>', 0)
        except DavError as exc:
            last = exc
            if 'recusou o acesso' in str(exc):
                raise
            continue
        for item in found:
            principal = href_of(item['props'].get(D + 'current-user-principal'), item['href'])
            if principal:
                break
        if principal:
            break
    if not principal:
        raise last or DavError('Não encontramos calendários neste servidor.')
    found = propfind(principal, auth, '<c:calendar-home-set/>', 0)
    home = ''
    for item in found:
        home = href_of(item['props'].get(C + 'calendar-home-set'), item['href'])
        if home:
            break
    if not home:
        raise DavError('Não encontramos calendários neste servidor.')
    return principal, home, list_remote_calendars(home, auth)


def list_remote_calendars(home, auth):
    props = ('<d:resourcetype/><d:displayname/><a:calendar-color/><c:supported-calendar-component-set/>'
             '<cs:getctag/><d:sync-token/><d:current-user-privilege-set/>')
    calendars = []
    for item in propfind(home, auth, props, 1):
        kind = item['props'].get(D + 'resourcetype')
        if kind is None or kind.find(C + 'calendar') is None:
            continue
        components = []
        supported = item['props'].get(C + 'supported-calendar-component-set')
        if supported is not None:
            components = [c.get('name', '').upper() for c in supported.findall(C + 'comp')]
        else:
            components = ['VEVENT', 'VTODO']
        components = [c for c in components if c in ('VEVENT', 'VTODO')]
        if not components:
            continue
        read_only = False
        privileges = item['props'].get(D + 'current-user-privilege-set')
        if privileges is not None:
            granted = {p.tag for priv in privileges.findall(D + 'privilege') for p in priv}
            read_only = not ({D + 'write', D + 'write-content', D + 'all'} & granted)
        name = (item['props'].get(D + 'displayname').text or '').strip() \
            if item['props'].get(D + 'displayname') is not None else ''
        color = item['props'].get(A + 'calendar-color')
        calendars.append({
            'href': item['href'],
            'name': ' '.join(name.split())[:120] or 'Calendário',
            'color': nearest_color(color.text if color is not None else '') or 'blue',
            'components': components,
            'readOnly': read_only,
        })
    return calendars


def account_input(req):
    provider = req.get('provider', 'other')
    if provider not in ('icloud', 'yahoo', 'fastmail', 'other'):
        raise Problem('Provedor inválido.')
    username = line_field(req.get('username') or req.get('email'), 320, 'Usuário')
    email = line_field(req.get('email'), 320, 'E-mail')
    password = req.get('password') or ''
    if not isinstance(password, str) or len(password) > 1024 or any(c in password for c in '\r\n\x00'):
        raise Problem('Senha inválida.')
    if provider in ('icloud', 'yahoo', 'fastmail') and not EMAIL.fullmatch(username):
        raise Problem('Informe o seu e-mail completo.')
    if not username:
        raise Problem('Informe o usuário.')
    if provider == 'yahoo' or provider == 'icloud':
        password = password.replace(' ', '') if re.fullmatch(r'[a-z ]{16,23}', password) else password
    return provider, email, username, password


def op_caldav_discover(req):
    provider, email, username, password = account_input(req)
    if not password:
        raise Problem('Informe a senha de app.')
    principal, home, calendars = discover(provider, email, req.get('url'), username, password)
    return {'calendars': [{k: c[k] for k in ('name', 'color', 'components', 'readOnly')} for c in calendars]}


def calendar_id_for(account_id, href):
    return 'dav-' + hashlib.sha1(('%s|%s' % (account_id, urllib.parse.unquote(href))).encode()).hexdigest()[:16]


def attach_calendars(account, calendars):
    """Create/refresh local copies of the account's calendars; drop vanished ones."""
    wanted = set()
    for index, remote in enumerate(calendars):
        cid = calendar_id_for(account['id'], remote['href'])
        wanted.add(cid)
        try:
            meta = load_meta(cid)
        except ValueError:
            meta = {'id': cid, 'source': 'caldav', 'accountId': account['id'], 'hidden': False,
                    'color': remote['color'], 'name': remote['name']}
        meta.update({'url': remote['href'], 'components': remote['components'], 'readOnly': remote['readOnly'],
                     'order': index, 'remoteName': remote['name']})
        if not meta.get('renamed'):
            meta['name'] = remote['name']
        save_meta(meta)
    for meta in all_meta():
        if meta.get('accountId') == account['id'] and meta['id'] not in wanted:
            state = sync_state(meta['id'])
            if not state['dirty']:
                shutil.rmtree(cal_dir(meta['id']), ignore_errors=True)


def op_caldav_add_account(req):
    provider, email, username, password = account_input(req)
    if not password:
        raise Problem('Informe a senha de app.')
    principal, home, calendars = discover(provider, email, req.get('url'), username, password)
    if not calendars:
        raise DavError('Esta conta não tem calendários.')
    existing = next((a for a in read_accounts() if a.get('username') == username and a.get('home') == home), None)
    account = existing or {'id': uuid.uuid4().hex}
    account.update({'provider': provider, 'username': username, 'email': email or username, 'principal': principal,
                    'home': home, 'name': line_field(req.get('name'), 120, 'Nome') or {
                        'icloud': 'iCloud', 'yahoo': 'Yahoo', 'fastmail': 'Fastmail'}.get(provider, 'CalDAV')})
    secret(account['id'], password)
    update_accounts(lambda items: [a for a in items if a.get('id') != account['id']] + [account])
    with locked(CALENDARS / '.lock'):
        attach_calendars(account, calendars)
    result = sync_account(account, password)
    return {'account': {k: account.get(k, '') for k in ('id', 'name', 'provider', 'username')}, 'sync': result}


def op_caldav_remove(req):
    account_id = req.get('accountId')
    account = next((a for a in read_accounts() if a.get('id') == account_id), None)
    if account is None:
        raise Problem('Conta não encontrada.')
    secret(account['id'], remove=True)
    for meta in all_meta():
        if meta.get('accountId') == account['id']:
            shutil.rmtree(cal_dir(meta['id']), ignore_errors=True)
    update_accounts(lambda items: [a for a in items if a.get('id') != account['id']])
    return True


def op_caldav_sync(req):
    accounts = read_accounts()
    if req.get('accountId'):
        accounts = [a for a in accounts if a.get('id') == req['accountId']]
    CONFIG.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(CONFIG / 'caldav-sync.lock', 'a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise Problem('A sincronização já está em andamento.')
        results = []
        for account in accounts:
            try:
                password = secret(account['id'])
                if not password:
                    raise Problem('A senha desta conta não está no chaveiro. Remova e adicione a conta de novo.')
                calendars = list_remote_calendars(account['home'], (account['username'], password))
                with locked(CALENDARS / '.lock'):
                    attach_calendars(account, calendars)
                result = sync_account(account, password)
            except (ValueError, OSError) as exc:
                result = {'errors': [friendly(exc)], 'changed': 0}
                def failed(items, account_id=account['id'], message=result['errors'][0]):
                    for a in items:
                        if a.get('id') == account_id:
                            a['lastError'] = message
                    return items
                update_accounts(failed)
            results.append(dict(result, accountId=account['id'], name=account.get('name', '')))
        return {'accounts': results, 'when': dt.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}


def sync_account(account, password):
    auth = (account['username'], password)
    changed, errors = 0, []
    for meta in all_meta():
        if meta.get('accountId') != account['id']:
            continue
        try:
            changed += sync_calendar(meta, auth)
        except (ValueError, OSError) as exc:
            errors.append('%s: %s' % (meta.get('name', ''), friendly(exc)))
    now = dt.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')

    def remember(items):
        for a in items:
            if a.get('id') == account['id']:
                a['lastSync'] = now
                a['lastError'] = errors[0] if errors else ''
        return items
    update_accounts(remember)
    return {'changed': changed, 'errors': errors}


def object_url(meta, name):
    base = meta['url'] if meta['url'].endswith('/') else meta['url'] + '/'
    return urllib.parse.urljoin(base, urllib.parse.quote(name))


def content_hash(cid, name):
    try:
        return hashlib.sha1((cal_dir(cid) / name).read_bytes()).hexdigest()
    except FileNotFoundError:
        return None


def push_changes(meta, auth):
    """Upload local changes. Returns (pushed count, set of names that conflicted)."""
    cid = meta['id']
    state = sync_state(cid)
    pushed, conflicts = 0, set()
    for name in list(state['dirty']):
        digest = content_hash(cid, name)
        if digest is None:
            with locked(cal_dir(cid) / '.lock'):
                s = sync_state(cid)
                s['dirty'] = [d for d in s['dirty'] if d != name]
                save_state(cid, s)
            continue
        if meta.get('readOnly'):
            continue
        data = (cal_dir(cid) / name).read_bytes()
        known = state['objects'].get(name)
        headers = {'Content-Type': 'text/calendar; charset=utf-8'}
        for attempt in range(2):
            if known and known.get('href'):
                href = known['href']
                if known.get('etag'):
                    headers['If-Match'] = known['etag']
            else:
                href = object_url(meta, name if attempt == 0 else uuid.uuid4().hex + '.ics')
                headers['If-None-Match'] = '*'
            status, reply, _ = http('PUT', href, auth, data, headers)
            if status == 412 and not known and attempt == 0:
                continue   # the name is taken on the server: try another
            break
        if status in (200, 201, 204):
            with locked(cal_dir(cid) / '.lock'):
                s = sync_state(cid)
                s['objects'][name] = {'href': href, 'etag': reply.get('etag', '')}
                if content_hash(cid, name) == digest:
                    s['dirty'] = [d for d in s['dirty'] if d != name]
                elif reply.get('etag'):
                    pass   # edited again meanwhile: next sync uploads it with the new etag
                save_state(cid, s)
            pushed += 1
        elif status == 412:
            conflicts.add(name)
        elif status == 403:
            # Read-only for us after all: the server's copy wins on the next pull
            with locked(cal_dir(cid) / '.lock'):
                s = sync_state(cid)
                s['dirty'] = [d for d in s['dirty'] if d != name]
                if name in s['objects']:
                    s['objects'][name]['etag'] = ''
                else:
                    try:
                        os.unlink(cal_dir(cid) / name)
                    except FileNotFoundError:
                        pass
                save_state(cid, s)
        else:
            raise dav_failure(status)
    for tomb in list(state['deleted']):
        headers = {'If-Match': tomb['etag']} if tomb.get('etag') else {}
        status, _, _ = http('DELETE', tomb['href'], auth, None, headers)
        if status in (200, 204, 404, 410, 412):
            # 412: changed on the server meanwhile; it comes back on the pull (server wins)
            with locked(cal_dir(cid) / '.lock'):
                s = sync_state(cid)
                s['deleted'] = [t for t in s['deleted'] if t.get('href') != tomb['href']]
                save_state(cid, s)
            pushed += 1
        elif status == 403:
            with locked(cal_dir(cid) / '.lock'):
                s = sync_state(cid)
                s['deleted'] = [t for t in s['deleted'] if t.get('href') != tomb['href']]
                s['ctag'] = ''
                s['token'] = ''
                save_state(cid, s)
        else:
            raise dav_failure(status)
    return pushed, conflicts


def remote_etags(meta, auth):
    body = ('<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="%s">'
            '<d:prop><d:getetag/></d:prop><c:filter><c:comp-filter name="VCALENDAR"/></c:filter>'
            '</c:calendar-query>' % NS['c'])
    status, _, data = http('REPORT', meta['url'], auth, body, depth=1)
    if status != 207:
        raise dav_failure(status)
    out = {}
    for item in multistatus(data, meta['url']):
        etag = item['props'].get(D + 'getetag')
        if item['status'] == 200 and etag is not None and not item['href'].rstrip('/') == meta['url'].rstrip('/'):
            out[item['href']] = (etag.text or '').strip()
    return out


def sync_changes(meta, auth, token):
    """(changed {href: etag}, deleted hrefs, new token), or None if the token was refused."""
    body = ('<?xml version="1.0" encoding="utf-8"?><d:sync-collection xmlns:d="DAV:"><d:sync-token>%s'
            '</d:sync-token><d:sync-level>1</d:sync-level><d:prop><d:getetag/></d:prop></d:sync-collection>'
            % xml_text(token))
    status, _, data = http('REPORT', meta['url'], auth, body)
    if status in (403, 409, 400, 412):
        return None
    if status != 207:
        raise dav_failure(status)
    root = parse_xml(data)
    changed, deleted = {}, []
    for item in multistatus(data, meta['url']):
        if item['href'].rstrip('/') == meta['url'].rstrip('/'):
            continue
        etag = item['props'].get(D + 'getetag')
        if item['status'] == 404:
            deleted.append(item['href'])
        elif etag is not None:
            changed[item['href']] = (etag.text or '').strip()
    return changed, deleted, (root.findtext(D + 'sync-token') or '').strip()


def xml_text(value):
    return (value or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def fetch(meta, auth, hrefs):
    """{href: (etag, ics text)} via calendar-multiget, 50 at a time."""
    out = {}
    hrefs = list(hrefs)
    for i in range(0, len(hrefs), 50):
        chunk = hrefs[i:i + 50]
        refs = ''.join('<d:href>%s</d:href>' % xml_text(urllib.parse.urlsplit(h).path) for h in chunk)
        body = ('<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget xmlns:d="DAV:" xmlns:c="%s">'
                '<d:prop><d:getetag/><c:calendar-data/></d:prop>%s</c:calendar-multiget>' % (NS['c'], refs))
        status, _, data = http('REPORT', meta['url'], auth, body, depth=1)
        if status != 207:
            raise dav_failure(status)
        for item in multistatus(data, meta['url']):
            calendar_data = item['props'].get(C + 'calendar-data')
            etag = item['props'].get(D + 'getetag')
            if calendar_data is not None and calendar_data.text:
                out[item['href']] = ((etag.text or '').strip() if etag is not None else '', calendar_data.text)
    return out


def same_href(a, b):
    return urllib.parse.unquote(urllib.parse.urlsplit(a).path) == urllib.parse.unquote(urllib.parse.urlsplit(b).path)


def name_for_href(cid, href, taken):
    base = urllib.parse.unquote(urllib.parse.urlsplit(href).path.rstrip('/').rsplit('/', 1)[-1])
    if not base.endswith('.ics'):
        base += '.ics'
    if not SAFE_NAME.fullmatch(base) or base in taken:
        base = hashlib.sha1(href.encode()).hexdigest()[:24] + '.ics'
    return base


def keep_conflict_copy(meta, name):
    """Server wins: the local version is kept as a separate, new item."""
    cal = read_object(meta['id'], name)
    if cal is None:
        return
    uid = ics.new_uid()
    for comp in cal.subs:
        if comp.name in ('VEVENT', 'VTODO'):
            comp.set('UID', uid)
            comp.remove('ORGANIZER')
            comp.remove('ATTENDEE')
            if comp.get('RECURRENCE-ID') is None:
                comp.set_text('SUMMARY', comp.text('SUMMARY') + ' (cópia em conflito)')
    cal.subs = [c for c in cal.subs if not (c.name in ('VEVENT', 'VTODO') and c.get('RECURRENCE-ID') is not None)]
    write_object(meta, file_for_uid(uid), cal)


def sync_calendar(meta, auth):
    cid = meta['id']
    pushed, conflicts = push_changes(meta, auth)
    info = propfind(meta['url'], auth, '<cs:getctag/><d:sync-token/>', 0)
    ctag = token = ''
    for item in info:
        if item['props'].get(CS + 'getctag') is not None:
            ctag = (item['props'][CS + 'getctag'].text or '').strip()
        if item['props'].get(D + 'sync-token') is not None:
            token = (item['props'][D + 'sync-token'].text or '').strip()
    state = sync_state(cid)
    if not pushed and not conflicts and ctag and ctag == state.get('ctag') and state.get('complete'):
        return 0
    known = {o['href']: (name, o.get('etag', '')) for name, o in state['objects'].items() if o.get('href')}

    def lookup(href):
        for h, value in known.items():
            if same_href(h, href):
                return h, value
        return None, (None, None)

    delta = sync_changes(meta, auth, state['token']) if state.get('token') and token and state.get('complete') else None
    if delta is not None:
        changed, gone, new_token = delta
        token = new_token or token
    else:
        remote = remote_etags(meta, auth)
        changed = {h: e for h, e in remote.items() if lookup(h)[1][1] != e or not e}
        gone = [h for h in known if not any(same_href(h, r) for r in remote)]
    fetched = fetch(meta, auth, changed.keys()) if changed else {}
    count = 0
    with locked(cal_dir(cid) / '.lock'):
        s = sync_state(cid)
        taken = set(os.listdir(cal_dir(cid)))
        for href, (etag, text) in fetched.items():
            if len(text.encode()) > OBJECT_LIMIT:
                continue
            try:
                roots = ics.parse(text)
            except ics.ICalError:
                continue
            cal = next((r for r in roots if r.name == 'VCALENDAR'), None)
            if cal is None or not (cal.walk('VEVENT') or cal.walk('VTODO')):
                continue
            _, (name, old_etag) = lookup(href)
            if name is None:
                name = name_for_href(cid, href, taken)
                taken.add(name)
            if name in s['dirty']:
                if name in conflicts or old_etag != etag:
                    s['dirty'] = [d for d in s['dirty'] if d != name]
                    save_state(cid, s)
                    keep_conflict_copy(meta, name)
                    s = sync_state(cid)
                else:
                    continue
            write_atomic(cal_dir(cid) / name, text if text.endswith('\n') else text + '\r\n')
            s['objects'][name] = {'href': href, 'etag': etag}
            count += 1
        for href in gone:
            h, (name, _) = lookup(href)
            if name is None:
                continue
            if name in s['dirty']:
                s['objects'].pop(name, None)   # deleted remotely, edited here: upload as new
                continue
            try:
                os.unlink(cal_dir(cid) / name)
            except FileNotFoundError:
                pass
            s['objects'].pop(name, None)
            count += 1
        s['ctag'] = ctag
        s['token'] = token
        s['complete'] = True
        save_state(cid, s)
    # Conflict copies and edits made during the sync are uploaded right away
    if sync_state(cid)['dirty'] and not meta.get('readOnly'):
        more, _ = push_changes(meta, auth)
        count += more
    return count + pushed


def op_mail_accounts(req):
    """Mail accounts (read-only) that can be reused for iCloud/Yahoo/Fastmail calendars."""
    try:
        with open(MAIL_ACCOUNTS, encoding='utf-8') as f:
            items = json.load(f)
    except (OSError, ValueError):
        return []
    out = []
    for a in items if isinstance(items, list) else []:
        address = str(a.get('email', '')) if isinstance(a, dict) else ''
        if not EMAIL.fullmatch(address):
            continue
        domain = address.rsplit('@', 1)[1].lower()
        provider = ('icloud' if domain in ('icloud.com', 'me.com', 'mac.com')
                    else 'yahoo' if domain.startswith('yahoo.') or domain in ('ymail.com', 'rocketmail.com')
                    else 'fastmail' if domain in ('fastmail.com', 'fastmail.fm') else '')
        out.append({'id': str(a.get('id', '')), 'email': address, 'name': str(a.get('name', '')),
                    'provider': provider})
    return out


# ================================================================ entry point

OPS = {
    'calendars': op_calendars,
    'range': op_range,
    'save_event': op_save_event,
    'delete_event': op_delete_event,
    'tasks': op_tasks,
    'save_task': op_save_task,
    'complete_task': op_complete_task,
    'delete_task': op_delete_task,
    'alarms': op_alarms,
    'calendar_save': op_calendar_save,
    'calendar_delete': op_calendar_delete,
    'set_default': op_set_default,
    'import_ics': op_import_ics,
    'invite_parse': op_invite_parse,
    'invite_reply': op_invite_respond,
    'invite_cancel': op_invite_cancel,
    'invite_apply_reply': op_invite_apply_reply,
    'caldav_discover': op_caldav_discover,
    'caldav_add_account': op_caldav_add_account,
    'caldav_sync': op_caldav_sync,
    'caldav_remove': op_caldav_remove,
    'mail_accounts': op_mail_accounts,
}


def dispatch(req):
    if not isinstance(req, dict) or req.get('op') not in OPS:
        raise Problem('Operação desconhecida.')
    return OPS[req['op']](req)


def friendly(exc):
    if isinstance(exc, Problem):
        return str(exc)
    if isinstance(exc, ics.ICalError):
        message = str(exc)
        return message if message[:1].isupper() else 'Arquivo de calendário inválido.'
    reason = getattr(exc, 'reason', None)
    if isinstance(exc, ssl.SSLCertVerificationError) or isinstance(reason, ssl.SSLCertVerificationError):
        return 'O certificado do servidor de calendário não é válido.'
    if isinstance(exc, (TimeoutError, )) or isinstance(reason, TimeoutError):
        return 'O servidor de calendário demorou para responder. Tente novamente.'
    if isinstance(reason, OSError) and type(reason).__name__ == 'gaierror':
        return 'Servidor de calendário não encontrado. Confira o endereço e a conexão.'
    if isinstance(exc, OSError):
        return 'Não foi possível falar com o servidor de calendário. Confira a conexão.'
    return 'Não foi possível concluir a operação.'


def main():
    try:
        req = json.loads(sys.stdin.buffer.readline(1024 * 1024))
        result = dispatch(req)
        print(json.dumps({'ok': True, 'data': result}, ensure_ascii=False))
    except Exception as exc:   # never echo server bodies or tracebacks
        print(json.dumps({'ok': False, 'error': friendly(exc)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
