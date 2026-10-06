"""Small iCalendar (RFC 5545) toolkit for Lingmo Mail, standard library only.

Parsing keeps every property it does not understand (raw value and parameters),
so editing a file and writing it back does not lose data from other clients.
Recurrences (RRULE/RDATE/EXDATE/RECURRENCE-ID) are expanded in the wall time of
the event's own time zone, so a weekly 9:00 meeting stays at 9:00 across DST.
"""
import calendar as _calendar
import datetime as dt
import os
import re
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

UTC = dt.timezone.utc
PRODID = '-//LingmoOS//Lingmo Mail 1.0//PT'
WEEKDAYS = ('MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU')
MAX_DEPTH = 8
MAX_LINES = 200000
# Hard cap on recurrence periods walked for one event (about 550 years of a daily rule)
MAX_PERIODS = 200000


class ICalError(ValueError):
    pass


# ---------------------------------------------------------------- local zone

_local = None


def local_zone():
    """The system time zone as a ZoneInfo when possible (DST-aware)."""
    global _local
    if _local is not None:
        return _local
    name = os.environ.get('TZ', '').lstrip(':')
    zone = None
    if name:
        try:
            zone = ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            zone = None
    if zone is None:
        try:
            link = os.readlink('/etc/localtime')
            index = link.find('zoneinfo/')
            if index >= 0:
                zone = ZoneInfo(link[index + len('zoneinfo/'):])
        except (OSError, ZoneInfoNotFoundError, ValueError):
            zone = None
    if zone is None:
        zone = dt.datetime.now().astimezone().tzinfo or UTC
    _local = zone
    return zone


def set_local_zone(zone):
    """Tests: force the local zone (None resets to the system one)."""
    global _local
    _local = zone


def zone_key(zone):
    return getattr(zone, 'key', None)


# Common Windows / Outlook names
WINDOWS_ZONES = {
    'E. South America Standard Time': 'America/Sao_Paulo',
    'SA Eastern Standard Time': 'America/Cayenne',
    'Argentina Standard Time': 'America/Argentina/Buenos_Aires',
    'Pacific Standard Time': 'America/Los_Angeles',
    'Mountain Standard Time': 'America/Denver',
    'Central Standard Time': 'America/Chicago',
    'Eastern Standard Time': 'America/New_York',
    'GMT Standard Time': 'Europe/London',
    'W. Europe Standard Time': 'Europe/Berlin',
    'Romance Standard Time': 'Europe/Paris',
    'Central European Standard Time': 'Europe/Warsaw',
    'GTB Standard Time': 'Europe/Bucharest',
    'China Standard Time': 'Asia/Shanghai',
    'Tokyo Standard Time': 'Asia/Tokyo',
    'India Standard Time': 'Asia/Kolkata',
    'AUS Eastern Standard Time': 'Australia/Sydney',
    'UTC': 'UTC',
    'Coordinated Universal Time': 'UTC',
}


def resolve_zone(tzid, timezones=None):
    """ZoneInfo for a TZID; VTIMEZONE offset or the local zone as fallback."""
    tzid = (tzid or '').strip().strip('"')
    if not tzid:
        return local_zone()
    candidates = [tzid, WINDOWS_ZONES.get(tzid, '')]
    parts = tzid.strip('/').split('/')
    # "/mozilla.org/20050126_1/America/Sao_Paulo" and similar prefixes
    for i in range(len(parts)):
        candidates.append('/'.join(parts[i:]))
    for name in candidates:
        if not name or '..' in name or len(name) > 100:
            continue
        try:
            return ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            continue
    if timezones and tzid in timezones:
        return timezones[tzid]
    return local_zone()


# ---------------------------------------------------------------- content lines

class Prop:
    __slots__ = ('name', 'params', 'value')

    def __init__(self, name, value='', params=None):
        self.name = name.upper()
        self.value = value
        self.params = dict(params or {})

    def param(self, key, default=''):
        return self.params.get(key.upper(), default)

    def __repr__(self):
        return 'Prop(%r, %r, %r)' % (self.name, self.value, self.params)


class Component:
    __slots__ = ('name', 'props', 'subs')

    def __init__(self, name, props=None, subs=None):
        self.name = name.upper()
        self.props = list(props or [])
        self.subs = list(subs or [])

    # properties
    def get(self, name):
        name = name.upper()
        for p in self.props:
            if p.name == name:
                return p
        return None

    def all(self, name):
        name = name.upper()
        return [p for p in self.props if p.name == name]

    def text(self, name, default=''):
        p = self.get(name)
        return unescape(p.value) if p else default

    def remove(self, name):
        name = name.upper()
        self.props = [p for p in self.props if p.name != name]

    def set(self, name, value, params=None):
        """Replace every `name` property by one, keeping its position."""
        name = name.upper()
        new = Prop(name, value, params)
        for i, p in enumerate(self.props):
            if p.name == name:
                self.props[i] = new
                self.props = self.props[:i + 1] + [q for q in self.props[i + 1:] if q.name != name]
                return new
        self.props.append(new)
        return new

    def add(self, name, value, params=None):
        p = Prop(name, value, params)
        self.props.append(p)
        return p

    def set_text(self, name, value):
        if value:
            self.set(name, escape(value))
        else:
            self.remove(name)

    # sub-components
    def walk(self, name):
        name = name.upper()
        return [c for c in self.subs if c.name == name]

    def __repr__(self):
        return 'Component(%s, %d props, %d subs)' % (self.name, len(self.props), len(self.subs))


def escape(text):
    return (str(text).replace('\\', '\\\\').replace(';', '\\;').replace(',', '\\,')
            .replace('\r\n', '\n').replace('\r', '\n').replace('\n', '\\n'))


def unescape(value):
    out = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == '\\' and i + 1 < len(value):
            nxt = value[i + 1]
            out.append('\n' if nxt in 'nN' else nxt)
            i += 2
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def unfold(text):
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    return re.sub(r'\n[ \t]', '', text).split('\n')


def fold(line):
    """Fold to 75 octets per line without splitting UTF-8 sequences."""
    data = line.encode('utf-8')
    if len(data) <= 75:
        return line
    out = []
    limit = 75
    while data:
        cut = min(limit, len(data))
        # Don't cut inside a multi-byte character
        while cut < len(data) and cut > 0 and (data[cut] & 0xC0) == 0x80:
            cut -= 1
        out.append(data[:cut].decode('utf-8'))
        data = data[cut:]
        limit = 74   # continuation lines start with a space
    return '\r\n '.join(out)


_NAME = re.compile(r'[A-Za-z0-9-]+')


def parse_line(line):
    m = _NAME.match(line)
    if not m:
        raise ICalError('linha inválida')
    name = m.group(0).upper()
    i = m.end()
    params = {}
    while i < len(line) and line[i] == ';':
        i += 1
        m = _NAME.match(line, i)
        if not m:
            raise ICalError('parâmetro inválido')
        key = m.group(0).upper()
        i = m.end()
        if i >= len(line) or line[i] != '=':
            raise ICalError('parâmetro inválido')
        i += 1
        values = []
        while True:
            if i < len(line) and line[i] == '"':
                end = line.find('"', i + 1)
                if end < 0:
                    raise ICalError('aspas sem fim')
                values.append(line[i + 1:end])
                i = end + 1
            else:
                m = re.compile(r'[^";:,]*').match(line, i)
                values.append(m.group(0))
                i = m.end()
            if i < len(line) and line[i] == ',':
                i += 1
                continue
            break
        params[key] = ','.join(values)
    if i >= len(line) or line[i] != ':':
        raise ICalError('linha sem valor')
    return Prop(name, line[i + 1:], params)


def parse(text):
    """Top-level components (normally VCALENDARs) of an iCalendar text."""
    if isinstance(text, bytes):
        text = text.decode('utf-8', 'replace')
    text = text.lstrip('﻿')
    lines = unfold(text)
    if len(lines) > MAX_LINES:
        raise ICalError('Arquivo de calendário grande demais.')
    roots, stack = [], []
    for raw in lines:
        if not raw.strip():
            continue
        try:
            prop = parse_line(raw)
        except ICalError:
            continue   # tolerate junk lines, as other clients do
        if prop.name == 'BEGIN':
            if len(stack) >= MAX_DEPTH:
                raise ICalError('Arquivo de calendário inválido.')
            comp = Component(prop.value.strip())
            if stack:
                stack[-1].subs.append(comp)
            else:
                roots.append(comp)
            stack.append(comp)
        elif prop.name == 'END':
            if not stack or stack[-1].name != prop.value.strip().upper():
                raise ICalError('Arquivo de calendário inválido.')
            stack.pop()
        elif stack:
            stack[-1].props.append(prop)
    if stack:
        raise ICalError('Arquivo de calendário incompleto.')
    return roots


def _param_value(value):
    if any(c in value for c in ';:,') or value != value.strip():
        return '"%s"' % value.replace('"', '')
    return value


def serialize_prop(p):
    head = p.name + ''.join(';%s=%s' % (k, _param_value(v)) for k, v in p.params.items())
    return fold(head + ':' + p.value.replace('\r', '').replace('\n', '\\n'))


def serialize(comp):
    lines = ['BEGIN:' + comp.name]
    lines += [serialize_prop(p) for p in comp.props]
    for sub in comp.subs:
        lines.append(serialize(sub).rstrip('\r\n'))
    lines.append('END:' + comp.name)
    return '\r\n'.join(lines) + '\r\n'


def new_calendar(method=None):
    cal = Component('VCALENDAR')
    cal.add('VERSION', '2.0')
    cal.add('PRODID', PRODID)
    cal.add('CALSCALE', 'GREGORIAN')
    if method:
        cal.add('METHOD', method)
    return cal


def new_uid():
    return str(uuid.uuid4()) + '@lingmo'


# ---------------------------------------------------------------- values

def timezones_of(cal):
    """TZID -> fixed-offset tzinfo from the VTIMEZONEs of a calendar (fallback only)."""
    zones = {}
    if cal is None:
        return zones
    for vtz in cal.walk('VTIMEZONE'):
        tzid = vtz.text('TZID')
        for kind in ('STANDARD', 'DAYLIGHT'):
            for obs in vtz.walk(kind):
                off = parse_offset(obs.text('TZOFFSETTO'))
                if off is not None and (kind == 'STANDARD' or tzid not in zones):
                    zones[tzid] = dt.timezone(off)
    return zones


def parse_offset(value):
    m = re.fullmatch(r'([+-])(\d\d)(\d\d)(\d\d)?', (value or '').strip())
    if not m:
        return None
    delta = dt.timedelta(hours=int(m[2]), minutes=int(m[3]), seconds=int(m[4] or 0))
    return -delta if m[1] == '-' else delta


def format_offset(delta):
    seconds = int(delta.total_seconds())
    sign = '-' if seconds < 0 else '+'
    seconds = abs(seconds)
    return '%s%02d%02d' % (sign, seconds // 3600, seconds // 60 % 60)


def parse_date_value(value, params=None, timezones=None):
    """date for VALUE=DATE, else an aware datetime (floating -> local zone)."""
    params = params or {}
    value = (value or '').strip()
    if params.get('VALUE', '').upper() == 'DATE' or re.fullmatch(r'\d{8}', value):
        m = re.fullmatch(r'(\d{4})(\d{2})(\d{2})', value)
        if not m:
            raise ICalError('data inválida')
        return dt.date(int(m[1]), int(m[2]), int(m[3]))
    m = re.fullmatch(r'(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)', value)
    if not m:
        raise ICalError('data e hora inválidas')
    second = min(int(m[6]), 59)   # leap seconds
    naive = dt.datetime(int(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5]), second)
    if m[7]:
        return naive.replace(tzinfo=UTC)
    tzid = params.get('TZID')
    zone = resolve_zone(tzid, timezones) if tzid else local_zone()
    return naive.replace(tzinfo=zone)


def is_floating(prop):
    return prop is not None and 'TZID' not in prop.params and not prop.value.strip().endswith('Z') \
        and 'T' in prop.value


def parse_dt(prop, timezones=None):
    if prop is None:
        return None
    return parse_date_value(prop.value, prop.params, timezones)


def format_date(d):
    return '%04d%02d%02d' % (d.year, d.month, d.day)


def format_naive(t):
    return '%04d%02d%02dT%02d%02d%02d' % (t.year, t.month, t.day, t.hour, t.minute, t.second)


def date_prop(name, value, zone=None):
    """Property for a date or datetime. Aware datetimes keep their zone key, or go UTC."""
    if not isinstance(value, dt.datetime):
        return Prop(name, format_date(value), {'VALUE': 'DATE'})
    if value.tzinfo is None:
        value = value.replace(tzinfo=zone or local_zone())
    key = zone_key(value.tzinfo)
    if key and key != 'UTC':
        return Prop(name, format_naive(value), {'TZID': key})
    return Prop(name, format_naive(value.astimezone(UTC)) + 'Z')


def format_utc(value):
    return format_naive(value.astimezone(UTC)) + 'Z'


_DURATION = re.compile(r'([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?')


def parse_duration(value):
    value = (value or '').strip()
    m = _DURATION.fullmatch(value)
    if not m or value in ('P', '+P', '-P') or value.endswith('T'):
        raise ICalError('duração inválida')
    delta = dt.timedelta(weeks=int(m[2] or 0), days=int(m[3] or 0), hours=int(m[4] or 0),
                         minutes=int(m[5] or 0), seconds=int(m[6] or 0))
    return -delta if m[1] == '-' else delta


def format_duration(delta):
    seconds = int(delta.total_seconds())
    sign = '-' if seconds < 0 else ''
    seconds = abs(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    out = sign + 'P'
    if days:
        out += '%dD' % days
    if hours or minutes or secs or not days:
        out += 'T'
        if hours:
            out += '%dH' % hours
        if minutes:
            out += '%dM' % minutes
        if secs or not (hours or minutes):
            out += '%dS' % secs
    return out


def to_local(value):
    """Aware local datetime; dates become local midnight."""
    if isinstance(value, dt.datetime):
        return value.astimezone(local_zone())
    return dt.datetime(value.year, value.month, value.day, tzinfo=local_zone())


def instance_key(value):
    """Stable identity of a recurrence instance (matches RECURRENCE-ID / EXDATE)."""
    if isinstance(value, dt.datetime):
        return format_utc(value)
    return format_date(value)


def add_wall(start, delta):
    """start + delta in wall time (keeps 9:00 at 9:00 across DST for whole days)."""
    if isinstance(start, dt.datetime):
        naive = start.replace(tzinfo=None) + delta
        return naive.replace(tzinfo=start.tzinfo)
    return start + dt.timedelta(days=delta.days)


# ---------------------------------------------------------------- recurrence

class Rule:
    __slots__ = ('freq', 'interval', 'count', 'until', 'byday', 'bymonthday', 'bymonth',
                 'byyearday', 'bysetpos', 'wkst', 'raw')

    def __init__(self):
        self.freq = None
        self.interval = 1
        self.count = None
        self.until = None
        self.byday = []          # [(ordinal or 0, weekday 0..6)]
        self.bymonthday = []
        self.bymonth = []
        self.byyearday = []
        self.bysetpos = []
        self.wkst = 0
        self.raw = ''


def _ints(value, low, high, allow_negative=True):
    out = []
    for part in value.split(','):
        part = part.strip()
        if not re.fullmatch(r'[+-]?\d{1,3}', part):
            raise ICalError('regra inválida')
        n = int(part)
        if n == 0 or abs(n) < low or abs(n) > high or (n < 0 and not allow_negative):
            raise ICalError('regra inválida')
        out.append(n)
    return out


def parse_rrule(value, timezones=None):
    """Rule, or None for frequencies we don't expand (hourly etc.)."""
    rule = Rule()
    rule.raw = value.strip()
    parts = {}
    for part in value.strip().split(';'):
        if '=' in part:
            k, v = part.split('=', 1)
            parts[k.strip().upper()] = v.strip()
    freq = parts.get('FREQ', '').upper()
    if freq not in ('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'):
        return None
    rule.freq = freq
    if parts.get('INTERVAL'):
        if not parts['INTERVAL'].isdigit() or int(parts['INTERVAL']) < 1:
            raise ICalError('regra inválida')
        rule.interval = min(int(parts['INTERVAL']), 10000)
    if parts.get('COUNT'):
        if not parts['COUNT'].isdigit():
            raise ICalError('regra inválida')
        rule.count = int(parts['COUNT'])
    if parts.get('UNTIL'):
        value = parts['UNTIL']
        if re.fullmatch(r'\d{8}', value):
            rule.until = parse_date_value(value)
        else:
            m = re.fullmatch(r'(\d{8}T\d{6})(Z?)', value)
            if not m:
                raise ICalError('regra inválida')
            until = parse_date_value(value, {}, timezones)
            # A floating UNTIL is compared in wall time: keep it naive
            rule.until = until if m[2] else until.replace(tzinfo=None)
    if parts.get('BYDAY'):
        for item in parts['BYDAY'].split(','):
            m = re.fullmatch(r'([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)', item.strip().upper())
            if not m:
                raise ICalError('regra inválida')
            n = int(m[1]) if m[1] else 0
            if abs(n) > 53:
                raise ICalError('regra inválida')
            rule.byday.append((n, WEEKDAYS.index(m[2])))
    if parts.get('BYMONTHDAY'):
        rule.bymonthday = _ints(parts['BYMONTHDAY'], 1, 31)
    if parts.get('BYMONTH'):
        rule.bymonth = _ints(parts['BYMONTH'], 1, 12, allow_negative=False)
    if parts.get('BYYEARDAY'):
        rule.byyearday = _ints(parts['BYYEARDAY'], 1, 366)
    if parts.get('BYSETPOS'):
        rule.bysetpos = _ints(parts['BYSETPOS'], 1, 366)
    if parts.get('WKST', '').upper() in WEEKDAYS:
        rule.wkst = WEEKDAYS.index(parts['WKST'].upper())
    return rule


def _month_dates(year, month, rule, start, ordinals_in_month=True):
    days = _calendar.monthrange(year, month)[1]
    by_md = None
    if rule.bymonthday:
        by_md = set()
        for n in rule.bymonthday:
            day = n if n > 0 else days + 1 + n
            if 1 <= day <= days:
                by_md.add(dt.date(year, month, day))
    by_wd = None
    if rule.byday:
        by_wd = set()
        for ordinal, weekday in rule.byday:
            matches = [dt.date(year, month, d) for d in range(1, days + 1)
                       if dt.date(year, month, d).weekday() == weekday]
            if ordinal and ordinals_in_month:
                if -len(matches) <= ordinal <= len(matches):
                    by_wd.add(matches[ordinal - 1 if ordinal > 0 else ordinal])
            else:
                by_wd.update(matches)
    if by_md is not None and by_wd is not None:
        return by_md & by_wd
    if by_md is not None:
        return by_md
    if by_wd is not None:
        return by_wd
    if start.day <= days:
        return {dt.date(year, month, start.day)}
    return set()


def _year_dates(year, rule, start):
    if rule.byyearday:
        length = 366 if _calendar.isleap(year) else 365
        out = set()
        for n in rule.byyearday:
            day = n if n > 0 else length + 1 + n
            if 1 <= day <= length:
                out.add(dt.date(year, 1, 1) + dt.timedelta(days=day - 1))
        if rule.bymonth:
            out = {d for d in out if d.month in rule.bymonth}
        if rule.byday:
            out = {d for d in out if d.weekday() in {w for _, w in rule.byday}}
        return out
    if rule.bymonth or rule.bymonthday:
        months = rule.bymonth or (range(1, 13) if rule.bymonthday else [start.month])
        out = set()
        for month in months:
            out |= _month_dates(year, month, rule, start)
        return out
    if rule.byday:
        out = set()
        first = dt.date(year, 1, 1)
        length = 366 if _calendar.isleap(year) else 365
        for ordinal, weekday in rule.byday:
            matches = [first + dt.timedelta(days=i) for i in range(length)
                       if (first + dt.timedelta(days=i)).weekday() == weekday]
            if ordinal:
                if -len(matches) <= ordinal <= len(matches):
                    out.add(matches[ordinal - 1 if ordinal > 0 else ordinal])
            else:
                out.update(matches)
        return out
    try:
        return {dt.date(year, start.month, start.day)}
    except ValueError:   # Feb 29 in a common year
        return set()


def _period(rule, start, k):
    """(first day of period k, candidate dates of that period)."""
    if rule.freq == 'DAILY':
        day = start + dt.timedelta(days=k * rule.interval)
        ok = (not rule.bymonth or day.month in rule.bymonth) \
            and (not rule.byday or day.weekday() in {w for _, w in rule.byday})
        if ok and rule.bymonthday:
            days = _calendar.monthrange(day.year, day.month)[1]
            ok = any((n if n > 0 else days + 1 + n) == day.day for n in rule.bymonthday)
        return day, ({day} if ok else set())
    if rule.freq == 'WEEKLY':
        week = start - dt.timedelta(days=(start.weekday() - rule.wkst) % 7)
        week += dt.timedelta(days=7 * k * rule.interval)
        days = [week + dt.timedelta(days=i) for i in range(7)]
        wanted = {w for _, w in rule.byday} if rule.byday else {start.weekday()}
        out = {d for d in days if d.weekday() in wanted}
        if rule.bymonth:
            out = {d for d in out if d.month in rule.bymonth}
        return week, out
    if rule.freq == 'MONTHLY':
        index = start.year * 12 + start.month - 1 + k * rule.interval
        year, month = divmod(index, 12)
        month += 1
        first = dt.date(year, month, 1) if 1 <= year <= 9999 else None
        if first is None:
            return dt.date.max, set()
        if rule.bymonth and month not in rule.bymonth:
            return first, set()
        return first, _month_dates(year, month, rule, start)
    year = start.year + k * rule.interval
    if year > 9999:
        return dt.date.max, set()
    return dt.date(year, 1, 1), _year_dates(year, rule, start)


def _beyond_until(rule, occurrence):
    until = rule.until
    if until is None:
        return False
    if not isinstance(until, dt.datetime):
        day = occurrence.date() if isinstance(occurrence, dt.datetime) else occurrence
        return day > until
    if not isinstance(occurrence, dt.datetime):
        return occurrence > until.date()
    if until.tzinfo is None:
        return occurrence.replace(tzinfo=None) > until
    return occurrence > until


def rrule_iter(dtstart, rule, stop=None):
    """Instance starts of a rule, ascending, DTSTART first.

    `stop` (a date) ends the walk once a period starts after it, so infinite
    rules and rules that never match can't spin forever.
    """
    if rule is None:
        yield dtstart
        return
    timed = isinstance(dtstart, dt.datetime)
    start_day = dtstart.date() if timed else dtstart
    wall = dtstart.replace(tzinfo=None).time() if timed else None

    def make(day):
        if not timed:
            return day
        return dt.datetime.combine(day, wall).replace(tzinfo=dtstart.tzinfo)

    if _beyond_until(rule, dtstart):
        return
    produced = 1
    yield dtstart
    if rule.count is not None and produced >= rule.count:
        return
    for k in range(MAX_PERIODS):
        first, dates = _period(rule, start_day, k)
        if first == dt.date.max:
            return
        if stop is not None and first > stop and (rule.freq != 'WEEKLY' or first - dt.timedelta(days=7) > stop):
            return
        dates = sorted(dates)
        if rule.bysetpos and dates:
            picked = set()
            for pos in rule.bysetpos:
                if -len(dates) <= pos <= len(dates):
                    picked.add(dates[pos - 1 if pos > 0 else pos])
            dates = sorted(picked)
        for day in dates:
            if day <= start_day:
                continue
            occurrence = make(day)
            if _beyond_until(rule, occurrence):
                return
            if stop is not None and day > stop:
                return
            produced += 1
            yield occurrence
            if rule.count is not None and produced >= rule.count:
                return


# ---------------------------------------------------------------- events

def event_bounds(comp, timezones=None):
    """(start, end, all_day) of a VEVENT/VTODO; end is exclusive."""
    start = parse_dt(comp.get('DTSTART'), timezones)
    if start is None:
        due = parse_dt(comp.get('DUE'), timezones)
        if due is None:
            return None, None, False
        return due, due, not isinstance(due, dt.datetime)
    all_day = not isinstance(start, dt.datetime)
    end_prop = comp.get('DTEND') or (comp.get('DUE') if comp.name == 'VTODO' else None)
    end = None
    if end_prop is not None:
        try:
            end = parse_dt(end_prop, timezones)
        except ICalError:
            end = None
        if end is not None and isinstance(end, dt.datetime) != (not all_day):
            end = None
    if end is None and comp.get('DURATION') is not None:
        try:
            end = add_wall(start, parse_duration(comp.get('DURATION').value))
        except ICalError:
            end = None
    if end is None or end < start:
        end = start + dt.timedelta(days=1) if all_day else start
    return start, end, all_day


def exclusions(comp, timezones=None):
    keys, days = set(), set()
    for prop in comp.all('EXDATE'):
        for value in prop.value.split(','):
            try:
                when = parse_date_value(value, prop.params, timezones)
            except ICalError:
                continue
            if isinstance(when, dt.datetime):
                keys.add(instance_key(when))
            else:
                days.add(when)
    return keys, days


def extra_dates(comp, start, timezones=None):
    out = []
    for prop in comp.all('RDATE'):
        if prop.params.get('VALUE', '').upper() == 'PERIOD':
            continue
        for value in prop.value.split(','):
            try:
                when = parse_date_value(value, prop.params, timezones)
            except ICalError:
                continue
            if isinstance(when, dt.datetime) == isinstance(start, dt.datetime):
                out.append(when)
    return out


def _overlaps(start, end, range_start, range_end):
    s, e = to_local(start), to_local(end)
    if e <= s:
        return range_start <= s < range_end
    return s < range_end and e > range_start


def expand(master, overrides, range_start, range_end, timezones=None, stop_after=5000):
    """Instances of an event overlapping [range_start, range_end) (aware datetimes).

    Returns [(start, end, recurrence_key or None, component)] sorted by start.
    """
    start, end, all_day = event_bounds(master, timezones)
    out = []
    if start is None:
        return out
    duration_wall = (end - start) if all_day else end.replace(tzinfo=None) - start.replace(tzinfo=None) \
        if end.tzinfo == start.tzinfo else None
    exact = end - start if isinstance(start, dt.datetime) else None
    rrule_prop = master.get('RRULE')
    rule = None
    if rrule_prop is not None:
        try:
            rule = parse_rrule(rrule_prop.value, timezones)
        except ICalError:
            rule = None
    by_key = {}
    for o in overrides:
        rid = o.get('RECURRENCE-ID')
        if rid is None:
            continue
        try:
            by_key[instance_key(parse_dt(rid, timezones))] = o
        except ICalError:
            continue
    recurring = rule is not None or bool(master.all('RDATE'))
    if not recurring:
        if _overlaps(start, end, range_start, range_end):
            out.append((start, end, None, master))
        return out

    def end_of(s):
        if duration_wall is not None:
            return add_wall(s, duration_wall)
        return s + exact

    ex_keys, ex_days = exclusions(master, timezones)
    stop_day = (range_end + dt.timedelta(days=1)).date()
    instances = list(rrule_iter(start, rule, stop_day)) if rule else [start]
    instances += [d for d in extra_dates(master, start, timezones) if d not in instances]
    instances.sort(key=to_local)
    seen = set()
    for s in instances:
        key = instance_key(s)
        if key in seen:
            continue
        seen.add(key)
        day = s.date() if isinstance(s, dt.datetime) else s
        if key in ex_keys or (day in ex_days):
            continue
        if key in by_key:
            continue   # handled below with its own times
        e = end_of(s)
        if to_local(s) >= range_end:
            break
        if _overlaps(s, e, range_start, range_end):
            out.append((s, e, key, master))
            if len(out) >= stop_after:
                break
    for key, o in by_key.items():
        if o.text('STATUS').upper() == 'CANCELLED':
            continue
        if key in ex_keys:
            continue
        s, e, _ = event_bounds(o, timezones)
        if s is None:
            continue
        if _overlaps(s, e, range_start, range_end):
            out.append((s, e, key, o))
    out.sort(key=lambda item: to_local(item[0]))
    return out


# ---------------------------------------------------------------- alarms

def alarm_offsets(comp):
    """[(kind, value, related)] for each VALARM: kind 'relative' (timedelta) or 'absolute'."""
    out = []
    for alarm in comp.walk('VALARM'):
        trigger = alarm.get('TRIGGER')
        if trigger is None:
            continue
        action = alarm.text('ACTION', 'DISPLAY').upper()
        if action not in ('DISPLAY', 'AUDIO', 'EMAIL'):
            continue
        try:
            if trigger.params.get('VALUE', '').upper() == 'DATE-TIME':
                out.append(('absolute', parse_date_value(trigger.value, {}), 'START'))
            else:
                related = trigger.params.get('RELATED', 'START').upper()
                out.append(('relative', parse_duration(trigger.value), related))
        except ICalError:
            continue
    return out


def alarm_times(comp, start, end):
    """Trigger instants (aware) of a component's alarms for one instance."""
    times = []
    for kind, value, related in alarm_offsets(comp):
        if kind == 'absolute':
            times.append(to_local(value))
        else:
            base = end if related == 'END' else start
            times.append(to_local(base) + value)
    return sorted(set(times))


def first_relative_alarm(comp):
    """Minutes before the start of the first relative alarm, or None."""
    for kind, value, related in alarm_offsets(comp):
        if kind == 'relative' and related == 'START':
            return int(-value.total_seconds() // 60)
    return None


def set_alarm(comp, minutes_before, description='Lembrete'):
    """Replace the component's alarms by one (None removes them)."""
    comp.subs = [s for s in comp.subs if s.name != 'VALARM']
    if minutes_before is None:
        return
    alarm = Component('VALARM')
    alarm.add('ACTION', 'DISPLAY')
    alarm.add('DESCRIPTION', escape(description or 'Lembrete'))
    params = {'RELATED': 'END'} if comp.name == 'VTODO' and comp.get('DTSTART') is None else {}
    alarm.add('TRIGGER', format_duration(dt.timedelta(minutes=-int(minutes_before))), params)
    comp.subs.append(alarm)


# ---------------------------------------------------------------- time zones

def _transitions(zone, year):
    """[(utc instant, offset before, offset after, is_dst, name)] in a year."""
    out = []
    t = dt.datetime(year, 1, 1, tzinfo=UTC)
    end = dt.datetime(year + 1, 1, 1, tzinfo=UTC)
    prev = t.astimezone(zone).utcoffset()
    step = dt.timedelta(days=1)
    while t < end:
        nxt = t + step
        off = nxt.astimezone(zone).utcoffset()
        if off != prev:
            lo, hi = t, nxt
            while hi - lo > dt.timedelta(minutes=1):
                mid = lo + (hi - lo) / 2
                if mid.astimezone(zone).utcoffset() == prev:
                    lo = mid
                else:
                    hi = mid
            hi = hi.replace(second=0, microsecond=0)
            local = hi.astimezone(zone)
            out.append((hi, prev, off, bool(local.dst()), local.tzname() or ''))
            prev = off
        t = nxt
    return out


def vtimezone(zone, year):
    """VTIMEZONE for a ZoneInfo, as yearly rules derived from `year`'s transitions."""
    key = zone_key(zone)
    comp = Component('VTIMEZONE')
    comp.add('TZID', key)
    changes = _transitions(zone, year)
    if not changes:
        moment = dt.datetime(year, 7, 1, tzinfo=UTC).astimezone(zone)
        obs = Component('STANDARD')
        obs.add('DTSTART', '19700101T000000')
        obs.add('TZOFFSETFROM', format_offset(moment.utcoffset()))
        obs.add('TZOFFSETTO', format_offset(moment.utcoffset()))
        if moment.tzname():
            obs.add('TZNAME', escape(moment.tzname()))
        comp.subs.append(obs)
        return comp
    for instant, before, after, dst, name in changes:
        wall = (instant + before).replace(tzinfo=None)
        obs = Component('DAYLIGHT' if dst else 'STANDARD')
        obs.add('DTSTART', format_naive(wall))
        days = _calendar.monthrange(wall.year, wall.month)[1]
        ordinal = -1 if wall.day > days - 7 else (wall.day - 1) // 7 + 1
        obs.add('RRULE', 'FREQ=YEARLY;BYMONTH=%d;BYDAY=%d%s' % (wall.month, ordinal, WEEKDAYS[wall.weekday()]))
        obs.add('TZOFFSETFROM', format_offset(before))
        obs.add('TZOFFSETTO', format_offset(after))
        if name:
            obs.add('TZNAME', escape(name))
        comp.subs.append(obs)
    return comp


def ensure_timezones(cal):
    """Add a VTIMEZONE for every IANA TZID used and not yet defined."""
    defined = {v.text('TZID') for v in cal.walk('VTIMEZONE')}
    used = {}
    for comp in cal.subs:
        for prop in comp.props:
            tzid = prop.params.get('TZID')
            if tzid and tzid not in defined and tzid not in used:
                try:
                    zone = ZoneInfo(tzid)
                except (ZoneInfoNotFoundError, ValueError):
                    continue
                year = dt.date.today().year
                try:
                    year = parse_date_value(prop.value.split(',')[0], {}).year
                except ICalError:
                    pass
                used[tzid] = vtimezone(zone, year)
    if used:
        others = [c for c in cal.subs if c.name != 'VTIMEZONE']
        cal.subs = [c for c in cal.subs if c.name == 'VTIMEZONE'] + list(used.values()) + others


# ---------------------------------------------------------------- people and iTIP

def mailto(value):
    value = (value or '').strip()
    if value.lower().startswith('mailto:'):
        value = value[7:]
    return value.strip()


def person(prop):
    if prop is None:
        return None
    return {
        'name': unescape(prop.params.get('CN', '')).strip('"'),
        'email': mailto(prop.value),
        'partstat': prop.params.get('PARTSTAT', 'NEEDS-ACTION').upper(),
        'role': prop.params.get('ROLE', 'REQ-PARTICIPANT').upper(),
    }


def find_attendee(comp, address):
    address = (address or '').strip().lower()
    for prop in comp.all('ATTENDEE'):
        if mailto(prop.value).lower() == address:
            return prop
    return None


def sequence(comp):
    try:
        return int(comp.text('SEQUENCE', '0').strip() or 0)
    except ValueError:
        return 0


PARTSTATS = ('ACCEPTED', 'TENTATIVE', 'DECLINED')


def build_reply(event, attendee_email, partstat, name=''):
    """METHOD:REPLY calendar answering one VEVENT of a REQUEST."""
    if partstat not in PARTSTATS:
        raise ICalError('Resposta inválida.')
    cal = new_calendar('REPLY')
    reply = Component('VEVENT')
    for key in ('UID', 'RECURRENCE-ID', 'SEQUENCE', 'DTSTART', 'DTEND', 'DURATION', 'SUMMARY', 'ORGANIZER'):
        for prop in event.all(key):
            reply.props.append(Prop(prop.name, prop.value, prop.params))
    reply.set('DTSTAMP', format_utc(dt.datetime.now(UTC)))
    params = {'PARTSTAT': partstat}
    original = find_attendee(event, attendee_email)
    if original is not None and original.params.get('CN'):
        params['CN'] = original.params['CN']
    elif name:
        params['CN'] = name
    reply.add('ATTENDEE', 'mailto:' + attendee_email, params)
    cal.subs.append(reply)
    ensure_timezones(cal)
    return serialize(cal)
