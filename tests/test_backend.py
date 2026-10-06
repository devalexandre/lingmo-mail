"""Unit tests for the Lingmo Mail worker: pure functions only.

No network, no Secret Service: anything that would reach them is patched to fail.
"""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'backend'))
import backend  # noqa: E402


def account(**changes):
    a = dict(id='abc', name='Ana', email='ana@example.com', protocol='imap',
             incomingHost='imap.example.com', incomingPort='993', incomingSecurity='tls',
             smtpHost='smtp.example.com', smtpPort=587, smtpSecurity='starttls', auth='password')
    a.update(changes)
    return a


def no_network(*args, **kwargs):
    raise AssertionError('network or keyring access in a unit test')


class Isolated(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        patches = [
            mock.patch.object(backend, 'CONFIG', Path(self.tmp.name) / 'cfg'),
            mock.patch.object(backend.urllib.request, 'urlopen', side_effect=no_network),
            mock.patch.object(backend.subprocess, 'run', side_effect=no_network),
            mock.patch.object(backend.smtplib, 'SMTP', side_effect=no_network),
            mock.patch.object(backend.smtplib, 'SMTP_SSL', side_effect=no_network),
            mock.patch.object(backend.imaplib, 'IMAP4', side_effect=no_network),
            mock.patch.object(backend.imaplib, 'IMAP4_SSL', side_effect=no_network),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)


class ValidateTest(Isolated):
    def test_normalizes_ports_and_usernames(self):
        a = backend.validate(account())
        self.assertEqual(a['incomingPort'], 993)
        self.assertEqual(a['smtpPort'], 587)
        self.assertEqual(a['username'], 'ana@example.com')
        self.assertEqual(a['smtpUsername'], 'ana@example.com')

    def test_drops_unknown_fields(self):
        a = backend.validate(account(password='hunter2', extra='x'))
        self.assertNotIn('password', a)
        self.assertNotIn('extra', a)

    def test_rejects_bad_values(self):
        bad = [
            dict(email='not-an-email'),
            dict(email='a b@example.com'),
            dict(protocol='exchange'),
            dict(incomingHost='imaps://imap.example.com'),
            dict(smtpHost='smtp.example.com/path'),
            dict(incomingHost='-oProxyCommand'),
            dict(incomingPort='abc'),
            dict(smtpPort=0),
            dict(smtpPort=70000),
            dict(incomingSecurity='none'),
            dict(name='Ana\r\nBcc: x@evil.com'),
            dict(username='ana\nx'),
        ]
        for change in bad:
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    backend.validate(account(**change))

    def test_missing_port(self):
        a = account()
        del a['smtpPort']
        with self.assertRaises(ValueError):
            backend.validate(a)


class DiscoverTest(Isolated):
    def test_known_domains_without_network(self):
        cases = {
            'eu@gmail.com': ('imap.gmail.com', 'smtp.gmail.com'),
            'eu@GoogleMail.com': ('imap.gmail.com', 'smtp.gmail.com'),
            'eu@outlook.com': ('outlook.office365.com', 'smtp-mail.outlook.com'),
            'eu@hotmail.com': ('outlook.office365.com', 'smtp-mail.outlook.com'),
            'eu@yahoo.com': ('imap.mail.yahoo.com', 'smtp.mail.yahoo.com'),
            'eu@icloud.com': ('imap.mail.me.com', 'smtp.mail.me.com'),
        }
        for address, (imap, smtp) in cases.items():
            with self.subTest(address=address):
                a = backend.discover(address)
                self.assertEqual((a['incomingHost'], a['smtpHost']), (imap, smtp))
                self.assertEqual(a['protocol'], 'imap')
                self.assertEqual((a['incomingPort'], a['incomingSecurity']), (993, 'tls'))
                self.assertEqual((a['smtpPort'], a['smtpSecurity']), (587, 'starttls'))
                self.assertEqual(a['username'], address)
                backend.validate(a)

    def test_invalid_address(self):
        with self.assertRaises(ValueError):
            backend.discover('ninguem')

    def test_unknown_provider_is_a_friendly_error(self):
        with mock.patch.object(backend.urllib.request, 'urlopen', side_effect=OSError('offline')):
            with self.assertRaises(ValueError) as ctx:
                backend.discover('eu@provedor-desconhecido.example')
        self.assertIn('manualmente', str(ctx.exception))


class SummaryTest(unittest.TestCase):
    def test_decodes_headers(self):
        raw = (b'From: =?utf-8?q?Jo=C3=A3o?= <joao@example.com>\r\n'
               b'To: ana@example.com\r\n'
               b'Subject: =?utf-8?b?T2zDoSE=?=\r\n'
               b'Date: Tue, 06 Oct 2026 10:00:00 -0300\r\n\r\n')
        s = backend.summary(raw, 42)
        self.assertEqual(s['id'], '42')
        self.assertEqual(s['subject'], 'Olá!')
        self.assertIn('João', s['sender'])
        self.assertEqual(s['to'], 'ana@example.com')
        self.assertTrue(s['date'].startswith('Tue, 06 Oct 2026'))

    def test_missing_subject(self):
        s = backend.summary(b'From: a@example.com\r\n\r\n', '1')
        self.assertEqual(s['subject'], '(Sem assunto)')
        self.assertEqual(s['date'], '')


class ParseMessageTest(unittest.TestCase):
    def test_plain_body_and_attachments(self):
        msg = backend.EmailMessage()
        msg['From'] = 'a@example.com'
        msg['Subject'] = 'Relatório'
        msg['Message-ID'] = '<id1@example.com>'
        msg['References'] = '<id0@example.com>'
        msg.set_content('Olá,\nsegue o relatório.')
        msg.add_attachment(b'%PDF', maintype='application', subtype='pdf', filename='relatorio.pdf')
        result = backend.parse_message(msg.as_bytes(), '7')
        self.assertEqual(result['body'].strip(), 'Olá,\nsegue o relatório.')
        self.assertEqual(result['attachments'], ['relatorio.pdf'])
        self.assertEqual(result['messageId'], '<id1@example.com>')
        self.assertEqual(result['references'], '<id0@example.com>')

    def test_html_only_is_reduced_to_text(self):
        msg = backend.EmailMessage()
        msg['From'] = 'a@example.com'
        msg.set_content('<p>Oi</p><script>alert(1)</script><img src="https://tracker/x.png"><style>p{}</style>fim',
                        subtype='html')
        body = backend.parse_message(msg.as_bytes(), '1')['body']
        self.assertIn('Oi', body)
        self.assertIn('fim', body)
        self.assertNotIn('alert', body)
        self.assertNotIn('tracker', body)
        self.assertNotIn('<', body)

    def test_bad_message_id_is_dropped(self):
        raw = b'From: a@example.com\r\nMessage-ID: not an id\r\n\r\nx'
        self.assertEqual(backend.parse_message(raw, '1')['messageId'], '')


class SendTest(Isolated):
    def setUp(self):
        super().setUp()
        p = mock.patch.object(backend, 'credentials', side_effect=no_network)
        p.start()
        self.addCleanup(p.stop)
        self.a = backend.validate(account())

    def test_header_injection_rejected_before_network(self):
        drafts = [
            dict(to='b@example.com', subject='Oi\r\nBcc: x@evil.com', body=''),
            dict(to='b@example.com\nBcc: x@evil.com', subject='Oi', body=''),
            dict(to='b@example.com', cc='c@example.com\r\nBcc: x@evil.com', subject='Oi', body=''),
            dict(to='b@example.com', subject='Oi\x00', body=''),
            dict(to='b@example.com', subject='Oi', inReplyTo='<a@b>\r\nBcc: x@evil.com', body=''),
            dict(to='b@example.com', subject='Oi', references='<a@b> injected', body=''),
        ]
        for draft in drafts:
            with self.subTest(draft=draft):
                with self.assertRaises(ValueError):
                    backend.send(self.a, draft)

    def test_invalid_recipients_rejected(self):
        for to in ['', 'ninguem', 'a@b.com, lixo', '<>']:
            with self.subTest(to=to):
                with self.assertRaises(ValueError):
                    backend.send(self.a, dict(to=to, subject='Oi', body=''))
        with self.assertRaises(ValueError):
            backend.send(self.a, dict(to='b@example.com', cc='lixo', subject='Oi', body=''))

    def test_build_message_headers(self):
        msg = backend.build_message(self.a, dict(to='Bia <b@example.com>', cc='c@example.com', subject='Re: Oi',
                                                 body='texto', inReplyTo='<1@x>', references='<0@x> <1@x>'))
        self.assertEqual(msg['To'], 'Bia <b@example.com>')
        self.assertEqual(msg['Cc'], 'c@example.com')
        self.assertEqual(msg['In-Reply-To'], '<1@x>')
        self.assertEqual(msg['References'], '<0@x> <1@x>')
        self.assertIn('ana@example.com', msg['From'])
        self.assertEqual(msg.get_content().strip(), 'texto')
        self.assertIsNone(msg['Bcc'])


class AccountsFileTest(Isolated):
    def test_update_and_read(self):
        self.assertEqual(backend.read_accounts(), [])
        backend.update_accounts(lambda items: items + [backend.validate(account())])
        self.assertEqual(backend.read_accounts()[0]['email'], 'ana@example.com')
        self.assertEqual(oct(os.stat(backend.CONFIG).st_mode & 0o777), '0o700')

    def test_unknown_account(self):
        with self.assertRaises(ValueError):
            backend.account_by_id('nope')


class MainTest(Isolated):
    def run_main(self, request):
        stdin = io.TextIOWrapper(io.BytesIO((json.dumps(request) + '\n').encode()))
        out = io.StringIO()
        with mock.patch.object(sys, 'stdin', stdin), mock.patch.object(sys, 'stdout', out):
            code = backend.main()
        return code, json.loads(out.getvalue())

    def test_accounts_ok(self):
        self.assertEqual(self.run_main({'op': 'accounts'}), (0, {'ok': True, 'data': []}))

    def test_discover_ok(self):
        code, reply = self.run_main({'op': 'discover', 'email': 'eu@gmail.com'})
        self.assertEqual(code, 0)
        self.assertEqual(reply['data']['incomingHost'], 'imap.gmail.com')

    def test_errors_are_friendly_and_do_not_echo_input(self):
        code, reply = self.run_main({'op': 'save', 'account': account(email='x'), 'password': 's3cr3t-pass'})
        self.assertEqual(code, 1)
        self.assertFalse(reply['ok'])
        self.assertNotIn('s3cr3t-pass', json.dumps(reply))
        code, reply = self.run_main({'op': 'inbox', 'id': 'missing'})
        self.assertEqual(reply, {'ok': False, 'error': 'Selecione uma conta.'})

    def test_server_refusal_is_not_echoed(self):
        error = backend.AUTH_ERRORS[0]   # imaplib.IMAP4.error
        with mock.patch.object(backend, 'dispatch', side_effect=error(b'[AUTHENTICATIONFAILED] token=abc123')):
            code, reply = self.run_main({'op': 'inbox', 'id': 'x'})
        self.assertEqual(code, 1)
        self.assertIn('senha', reply['error'])
        self.assertNotIn('abc123', reply['error'])

    @unittest.skipIf(Path('/etc/lingmo-mail/google-oauth.json').exists(), 'system OAuth client configured')
    def test_google_without_client_id(self):
        env = {k: v for k, v in os.environ.items() if k != 'LINGMO_GOOGLE_CLIENT_ID'}
        with mock.patch.dict(os.environ, env, clear=True):
            code, reply = self.run_main({'op': 'google'})
        self.assertEqual(code, 1)
        self.assertIn('client ID', reply['error'])

class GmailSaveTest(Isolated):
    def account(self):
        return backend.discover('eu@gmail.com')

    def test_app_password_spaces_are_removed(self):
        seen = []
        @backend.contextlib.contextmanager
        def ok(a, pw, oauth):
            seen.append(pw)
            yield None
        with mock.patch.object(backend, 'incoming', ok), mock.patch.object(backend, 'outgoing', ok), \
                mock.patch.object(backend, 'secret') as secret:
            backend.save(self.account(), 'abcd efgh ijkl mnop')
        self.assertEqual(seen, ['abcdefghijklmnop'] * 2)
        secret.assert_called_once_with(mock.ANY, 'abcdefghijklmnop')

    def test_refused_login_explains_app_password(self):
        @backend.contextlib.contextmanager
        def refused(a, pw, oauth):
            raise backend.AUTH_ERRORS[0]('[AUTHENTICATIONFAILED] Invalid credentials')
            yield
        with mock.patch.object(backend, 'incoming', refused):
            with self.assertRaisesRegex(ValueError, 'senha de app'):
                backend.save(self.account(), 'senhanormal')


class ErrorMessageTest(unittest.TestCase):
    def run_main(self, exc):
        out = io.StringIO()
        with mock.patch.object(backend.sys, 'stdin', io.TextIOWrapper(io.BytesIO(b'{"op":"accounts"}\n'))), \
                mock.patch.object(backend, 'dispatch', side_effect=exc), mock.patch('sys.stdout', out):
            backend.main()
        return json.loads(out.getvalue())['error']

    def test_certificate_error_is_translated(self):
        import ssl
        exc = ssl.SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed')
        self.assertEqual(self.run_main(exc), 'O certificado do servidor não é válido.')

    def test_library_value_errors_are_not_echoed(self):
        message = self.run_main(UnicodeDecodeError('utf-8', b'\xff', 0, 1, 'segredo'))
        self.assertNotIn('segredo', message)

    def test_own_messages_are_shown(self):
        self.assertEqual(self.run_main(ValueError('Selecione uma conta.')), 'Selecione uma conta.')


if __name__ == '__main__':
    unittest.main()
