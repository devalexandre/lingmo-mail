"""Unit tests for backend/ics.py: parsing, serialising, recurrences, alarms, iTIP."""
import datetime as dt
import sys
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'backend'))
import ics  # noqa: E402

SP = ZoneInfo('America/Sao_Paulo')
BERLIN = ZoneInfo('Europe/Berlin')
NY = ZoneInfo('America/New_York')


def event(lines):
    text = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n%s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' % '\r\n'.join(lines)
    return ics.parse(text)[0].walk('VEVENT')[0]


def starts(master, a, b, overrides=(), zone=None):
    zone = zone or ics.local_zone()
    items = ics.expand(master, list(overrides), dt.datetime(*a, tzinfo=zone), dt.datetime(*b, tzinfo=zone))
    return [s for s, _, _, _ in items]


class LocalZone(unittest.TestCase):
    zone = BERLIN

    def setUp(self):
        ics.set_local_zone(self.zone)
        self.addCleanup(ics.set_local_zone, None)


class LinesTest(LocalZone):
    def test_folding_round_trip_keeps_utf8(self):
        text = 'Reunião de planejamento — ' + 'çãõé' * 40
        comp = ics.Component('VEVENT')
        comp.set_text('SUMMARY', text)
        out = ics.serialize(comp)
        for line in out.split('\r\n'):
            self.assertLessEqual(len(line.encode()), 75)
        again = ics.parse(out)[0]
        self.assertEqual(again.text('SUMMARY'), text)

    def test_escaping(self):
        value = 'a,b;c\\d\nnova linha'
        self.assertEqual(ics.unescape(ics.escape(value)), value)
        self.assertEqual(ics.escape('x,y'), 'x\\,y')
        self.assertEqual(ics.unescape('Linha\\Noutra'), 'Linha\noutra')

    def test_quoted_parameters(self):
        p = ics.parse_line('ATTENDEE;CN="Silva, Ana";PARTSTAT=ACCEPTED:mailto:ana@example.com')
        self.assertEqual(p.params['CN'], 'Silva, Ana')
        self.assertEqual(p.params['PARTSTAT'], 'ACCEPTED')
        self.assertEqual(p.value, 'mailto:ana@example.com')
        comp = ics.Component('VEVENT', [p])
        self.assertIn('CN="Silva, Ana"', ics.serialize(comp))

    def test_unfolds_tabs_and_crlf(self):
        roots = ics.parse('BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Lo\n ng\n\tdesc\nEND:VEVENT\nEND:VCALENDAR\n')
        self.assertEqual(roots[0].walk('VEVENT')[0].text('SUMMARY'), 'Longdesc')

    def test_unknown_properties_survive(self):
        text = ('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-WR-CALNAME:Casa\r\nBEGIN:VEVENT\r\nUID:1\r\n'
                'X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC\r\nDTSTART:20260101T100000Z\r\nEND:VEVENT\r\n'
                'END:VCALENDAR\r\n')
        out = ics.serialize(ics.parse(text)[0])
        self.assertIn('X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC', out)
        self.assertIn('X-WR-CALNAME:Casa', out)

    def test_broken_nesting_is_rejected(self):
        with self.assertRaises(ics.ICalError):
            ics.parse('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VCALENDAR\r\n')
        with self.assertRaises(ics.ICalError):
            ics.parse('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n')

    def test_durations(self):
        self.assertEqual(ics.parse_duration('-PT15M'), dt.timedelta(minutes=-15))
        self.assertEqual(ics.parse_duration('P1W'), dt.timedelta(days=7))
        self.assertEqual(ics.parse_duration('P1DT2H'), dt.timedelta(days=1, hours=2))
        self.assertEqual(ics.format_duration(dt.timedelta(minutes=-15)), '-PT15M')
        self.assertEqual(ics.format_duration(dt.timedelta(days=1)), 'P1D')
        self.assertEqual(ics.format_duration(dt.timedelta(0)), 'PT0S')
        for bad in ('P', 'PT', '15M', 'P1H'):
            with self.assertRaises(ics.ICalError):
                ics.parse_duration(bad)


class DatesTest(LocalZone):
    def test_utc_tzid_floating_and_date(self):
        e = event(['DTSTART;TZID=America/New_York:20260310T090000', 'DTEND:20260310T150000Z'])
        start, end, all_day = ics.event_bounds(e)
        self.assertFalse(all_day)
        self.assertEqual(start.utcoffset(), dt.timedelta(hours=-4))   # EDT since 8 March
        self.assertEqual(end, dt.datetime(2026, 3, 10, 15, tzinfo=ics.UTC))
        floating = ics.parse_date_value('20260101T080000')
        self.assertEqual(floating.tzinfo, BERLIN)
        self.assertEqual(ics.parse_date_value('20260101'), dt.date(2026, 1, 1))

    def test_outlook_and_prefixed_tzids(self):
        self.assertEqual(ics.resolve_zone('E. South America Standard Time').key, 'America/Sao_Paulo')
        self.assertEqual(ics.resolve_zone('/mozilla.org/20050126_1/Europe/Berlin').key, 'Europe/Berlin')

    def test_unknown_tzid_uses_vtimezone_offset(self):
        cal = ics.parse('BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:Custom\r\nBEGIN:STANDARD\r\n'
                        'DTSTART:19700101T000000\r\nTZOFFSETFROM:+0530\r\nTZOFFSETTO:+0530\r\nEND:STANDARD\r\n'
                        'END:VTIMEZONE\r\nEND:VCALENDAR\r\n')[0]
        zones = ics.timezones_of(cal)
        value = ics.parse_date_value('20260101T120000', {'TZID': 'Custom'}, zones)
        self.assertEqual(value.utcoffset(), dt.timedelta(hours=5, minutes=30))

    def test_duration_and_defaults(self):
        e = event(['DTSTART:20260101T100000Z', 'DURATION:PT90M'])
        s, end, _ = ics.event_bounds(e)
        self.assertEqual(end - s, dt.timedelta(minutes=90))
        e = event(['DTSTART;VALUE=DATE:20260101'])
        s, end, all_day = ics.event_bounds(e)
        self.assertTrue(all_day)
        self.assertEqual(end, dt.date(2026, 1, 2))

    def test_date_prop_writes_zone_key(self):
        p = ics.date_prop('DTSTART', dt.datetime(2026, 5, 1, 9, tzinfo=BERLIN))
        self.assertEqual(p.params, {'TZID': 'Europe/Berlin'})
        self.assertEqual(p.value, '20260501T090000')
        p = ics.date_prop('DTSTART', dt.date(2026, 5, 1))
        self.assertEqual((p.value, p.params), ('20260501', {'VALUE': 'DATE'}))
        p = ics.date_prop('DTSTART', dt.datetime(2026, 5, 1, 9, tzinfo=ics.UTC))
        self.assertEqual(p.value, '20260501T090000Z')

    def test_vtimezone_generation(self):
        comp = ics.vtimezone(BERLIN, 2026)
        text = ics.serialize(comp)
        self.assertIn('BEGIN:DAYLIGHT', text)
        self.assertIn('RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU', text)
        self.assertIn('RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU', text)
        self.assertIn('TZOFFSETTO:+0200', text)
        sp = ics.serialize(ics.vtimezone(SP, 2026))
        self.assertIn('TZOFFSETTO:-0300', sp)
        self.assertNotIn('DAYLIGHT', sp)


class RecurrenceTest(LocalZone):
    def test_weekly_keeps_wall_time_across_dst(self):
        e = event(['DTSTART;TZID=Europe/Berlin:20260316T090000', 'DTEND;TZID=Europe/Berlin:20260316T100000',
                   'RRULE:FREQ=WEEKLY;COUNT=4'])
        got = starts(e, (2026, 3, 1), (2026, 5, 1))
        self.assertEqual([s.hour for s in got], [9, 9, 9, 9])
        self.assertEqual([s.utcoffset().total_seconds() / 3600 for s in got], [1, 1, 2, 2])

    def test_monthly_31st_skips_short_months(self):
        e = event(['DTSTART;VALUE=DATE:20260131', 'RRULE:FREQ=MONTHLY;COUNT=4'])
        got = starts(e, (2026, 1, 1), (2027, 1, 1))
        self.assertEqual(got, [dt.date(2026, 1, 31), dt.date(2026, 3, 31), dt.date(2026, 5, 31),
                               dt.date(2026, 7, 31)])

    def test_last_day_of_month(self):
        e = event(['DTSTART;VALUE=DATE:20260131', 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3'])
        got = starts(e, (2026, 1, 1), (2027, 1, 1))
        self.assertEqual(got, [dt.date(2026, 1, 31), dt.date(2026, 2, 28), dt.date(2026, 3, 31)])

    def test_last_friday_and_second_monday(self):
        e = event(['DTSTART:20260130T150000Z', 'RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3'])
        got = [s.date() for s in starts(e, (2026, 1, 1), (2027, 1, 1))]
        self.assertEqual(got, [dt.date(2026, 1, 30), dt.date(2026, 2, 27), dt.date(2026, 3, 27)])
        e = event(['DTSTART;VALUE=DATE:20260112', 'RRULE:FREQ=MONTHLY;BYDAY=2MO;UNTIL=20260430'])
        got = starts(e, (2026, 1, 1), (2027, 1, 1))
        self.assertEqual(got, [dt.date(2026, 1, 12), dt.date(2026, 2, 9), dt.date(2026, 3, 9),
                               dt.date(2026, 4, 13)])

    def test_yearly_feb_29(self):
        e = event(['DTSTART;VALUE=DATE:20240229', 'RRULE:FREQ=YEARLY'])
        got = starts(e, (2024, 1, 1), (2033, 1, 1))
        self.assertEqual(got, [dt.date(2024, 2, 29), dt.date(2028, 2, 29), dt.date(2032, 2, 29)])

    def test_yearly_thanksgiving(self):
        e = event(['DTSTART;VALUE=DATE:20261126', 'RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH'])
        got = starts(e, (2026, 1, 1), (2029, 1, 1))
        self.assertEqual(got, [dt.date(2026, 11, 26), dt.date(2027, 11, 25), dt.date(2028, 11, 23)])

    def test_weekly_byday_interval_until_utc(self):
        e = event(['DTSTART;TZID=America/Sao_Paulo:20261005T080000',
                   'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20261021T110000Z'])
        got = [s.date() for s in starts(e, (2026, 10, 1), (2026, 12, 1))]
        # Until 21 Oct 08:00 BRT (11:00Z) inclusive
        self.assertEqual(got, [dt.date(2026, 10, 5), dt.date(2026, 10, 7), dt.date(2026, 10, 19),
                               dt.date(2026, 10, 21)])

    def test_daily_count_with_exdate(self):
        e = event(['DTSTART:20260101T100000Z', 'RRULE:FREQ=DAILY;COUNT=5', 'EXDATE:20260102T100000Z,20260104T100000Z'])
        got = [s.day for s in starts(e, (2026, 1, 1), (2026, 2, 1))]
        self.assertEqual(got, [1, 3, 5])   # EXDATE doesn't extend COUNT

    def test_exdate_with_tzid(self):
        e = event(['DTSTART;TZID=America/New_York:20260105T090000', 'RRULE:FREQ=DAILY;COUNT=3',
                   'EXDATE;TZID=America/New_York:20260106T090000'])
        got = [s.day for s in starts(e, (2026, 1, 1), (2026, 2, 1))]
        self.assertEqual(got, [5, 7])

    def test_override_moves_instance(self):
        master = event(['UID:x', 'DTSTART:20260105T100000Z', 'DTEND:20260105T110000Z', 'RRULE:FREQ=DAILY;COUNT=3',
                        'SUMMARY:Daily'])
        override = event(['UID:x', 'RECURRENCE-ID:20260106T100000Z', 'DTSTART:20260106T140000Z',
                          'DTEND:20260106T150000Z', 'SUMMARY:Moved'])
        items = ics.expand(master, [override], dt.datetime(2026, 1, 1, tzinfo=ics.UTC),
                           dt.datetime(2026, 2, 1, tzinfo=ics.UTC))
        self.assertEqual([(s.day, s.astimezone(ics.UTC).hour, c.text('SUMMARY')) for s, _, _, c in items],
                         [(5, 10, 'Daily'), (6, 14, 'Moved'), (7, 10, 'Daily')])
        self.assertEqual(items[1][2], '20260106T100000Z')

    def test_cancelled_override_hides_instance(self):
        master = event(['UID:x', 'DTSTART:20260105T100000Z', 'RRULE:FREQ=DAILY;COUNT=3'])
        override = event(['UID:x', 'RECURRENCE-ID:20260106T100000Z', 'DTSTART:20260106T100000Z', 'STATUS:CANCELLED'])
        got = [s.day for s, _, _, _ in ics.expand(master, [override], dt.datetime(2026, 1, 1, tzinfo=ics.UTC),
                                                     dt.datetime(2026, 2, 1, tzinfo=ics.UTC))]
        self.assertEqual(got, [5, 7])

    def test_range_window_and_infinite_rules(self):
        e = event(['DTSTART;VALUE=DATE:20200101', 'RRULE:FREQ=DAILY'])
        got = starts(e, (2026, 3, 10), (2026, 3, 13))
        self.assertEqual(got, [dt.date(2026, 3, 10), dt.date(2026, 3, 11), dt.date(2026, 3, 12)])
        # A rule that never matches again must terminate
        e = event(['DTSTART;VALUE=DATE:20260101', 'RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30'])
        self.assertEqual(starts(e, (2026, 1, 1), (2030, 1, 1)), [dt.date(2026, 1, 1)])

    def test_bysetpos_last_weekday(self):
        e = event(['DTSTART;VALUE=DATE:20260130', 'RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3'])
        got = starts(e, (2026, 1, 1), (2027, 1, 1))
        self.assertEqual(got, [dt.date(2026, 1, 30), dt.date(2026, 2, 27), dt.date(2026, 3, 31)])

    def test_multi_day_event_overlaps_range(self):
        e = event(['DTSTART;VALUE=DATE:20260301', 'DTEND;VALUE=DATE:20260305'])
        self.assertEqual(starts(e, (2026, 3, 3), (2026, 3, 4)), [dt.date(2026, 3, 1)])
        self.assertEqual(starts(e, (2026, 3, 5), (2026, 3, 6)), [])

    def test_rdate(self):
        e = event(['DTSTART:20260101T100000Z', 'RDATE:20260110T100000Z,20260120T100000Z'])
        got = [s.day for s in starts(e, (2026, 1, 1), (2026, 2, 1))]
        self.assertEqual(got, [1, 10, 20])

    def test_unsupported_frequency_is_single(self):
        e = event(['DTSTART:20260101T100000Z', 'RRULE:FREQ=HOURLY;COUNT=5'])
        self.assertEqual(len(starts(e, (2026, 1, 1), (2026, 2, 1))), 1)


class AlarmTest(LocalZone):
    def test_relative_and_absolute_triggers(self):
        cal = ics.parse('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T100000Z\r\nDTEND:20260101T110000Z\r\n'
                        'BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n'
                        'BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER;RELATED=END:PT5M\r\nEND:VALARM\r\n'
                        'BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER;VALUE=DATE-TIME:20251231T120000Z\r\nEND:VALARM\r\n'
                        'END:VEVENT\r\nEND:VCALENDAR\r\n')[0]
        comp = cal.walk('VEVENT')[0]
        s, e, _ = ics.event_bounds(comp)
        times = [t.astimezone(ics.UTC) for t in ics.alarm_times(comp, s, e)]
        self.assertEqual(times, [dt.datetime(2025, 12, 31, 12, tzinfo=ics.UTC),
                                 dt.datetime(2026, 1, 1, 9, 45, tzinfo=ics.UTC),
                                 dt.datetime(2026, 1, 1, 11, 5, tzinfo=ics.UTC)])
        self.assertEqual(ics.first_relative_alarm(comp), 15)

    def test_alarm_for_each_occurrence(self):
        master = event(['DTSTART:20260105T100000Z', 'RRULE:FREQ=DAILY;COUNT=2'])
        ics.set_alarm(master, 30)
        items = ics.expand(master, [], dt.datetime(2026, 1, 1, tzinfo=ics.UTC), dt.datetime(2026, 2, 1, tzinfo=ics.UTC))
        times = [ics.alarm_times(c, s, e)[0].astimezone(ics.UTC) for s, e, _, c in items]
        self.assertEqual(times, [dt.datetime(2026, 1, 5, 9, 30, tzinfo=ics.UTC),
                                 dt.datetime(2026, 1, 6, 9, 30, tzinfo=ics.UTC)])

    def test_all_day_alarm_uses_local_midnight(self):
        master = event(['DTSTART;VALUE=DATE:20260105'])
        ics.set_alarm(master, 15 * 60)   # 15 h before: 09:00 the day before
        s, e, _ = ics.event_bounds(master)
        self.assertEqual(ics.alarm_times(master, s, e)[0], dt.datetime(2026, 1, 4, 9, tzinfo=BERLIN))


class ReplyTest(LocalZone):
    def test_reply_has_only_my_attendee(self):
        e = event(['UID:meet-1', 'SEQUENCE:2', 'DTSTART:20260101T100000Z', 'SUMMARY:Planejamento',
                   'ORGANIZER;CN=Bia:mailto:bia@example.com',
                   'ATTENDEE;CN=Ana;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:ana@example.com',
                   'ATTENDEE;PARTSTAT=ACCEPTED:mailto:carlos@example.com'])
        text = ics.build_reply(e, 'ana@example.com', 'ACCEPTED')
        cal = ics.parse(text)[0]
        self.assertEqual(cal.text('METHOD'), 'REPLY')
        reply = cal.walk('VEVENT')[0]
        self.assertEqual(reply.text('UID'), 'meet-1')
        self.assertEqual(reply.text('SEQUENCE'), '2')
        attendees = reply.all('ATTENDEE')
        self.assertEqual(len(attendees), 1)
        self.assertEqual(attendees[0].value, 'mailto:ana@example.com')
        self.assertEqual(attendees[0].params, {'PARTSTAT': 'ACCEPTED', 'CN': 'Ana'})
        self.assertEqual(reply.get('ORGANIZER').value, 'mailto:bia@example.com')
        with self.assertRaises(ics.ICalError):
            ics.build_reply(e, 'ana@example.com', 'MAYBE')


if __name__ == '__main__':
    unittest.main()
