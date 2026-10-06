#!/usr/bin/python3
"""Lingmo Mail worker. JSON stdin/stdout; credentials only in Secret Service.
No message HTML is rendered and no remote content is fetched.
"""
import base64
import contextlib
import email
import email.policy
import fcntl
import hashlib
import http.server
import imaplib
import json
import os
from pathlib import Path
import poplib
import re
import secrets
import smtplib
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from email.message import EmailMessage
from email.utils import getaddresses, formataddr

CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'lingmo-online-accounts'
LIMIT = 20 * 1024 * 1024
TLS = ssl.create_default_context()
# Login refusals and protocol errors (abort = dropped connection, reported generically)
AUTH_ERRORS = (imaplib.IMAP4.error, poplib.error_proto)
IMAP_ABORT = imaplib.IMAP4.abort


def read_accounts():
    try:
        data = json.loads((CONFIG / 'accounts.json').read_text())
        return data if isinstance(data, list) else []
    except FileNotFoundError:
        return []


def update_accounts(transform):
    CONFIG.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (CONFIG / 'accounts.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = transform(read_accounts())
        fd, path = tempfile.mkstemp(dir=CONFIG)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(data, out, ensure_ascii=False)
                out.flush()
                os.fsync(out.fileno())
            os.replace(path, CONFIG / 'accounts.json')
        finally:
            if os.path.exists(path):
                os.unlink(path)
    return data


def secret(account_id, value=None, remove=False):
    args = ['secret-tool', 'clear' if remove else 'lookup' if value is None else 'store']
    if value is not None:
        args += ['--label=Lingmo Mail']
    args += ['application', 'lingmo-mail', 'account', account_id]
    result = subprocess.run(args, input=value, text=True, capture_output=True, timeout=90)
    if result.returncode and not remove:
        raise ValueError('Não foi possível acessar o chaveiro. Desbloqueie o chaveiro da sessão e tente novamente.')
    return result.stdout.rstrip('\n')


def validate(a):
    a = dict(a)
    if not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', a.get('email', '')):
        raise ValueError('Informe um endereço de e-mail válido.')
    if a.get('protocol') not in ('imap', 'pop3'):
        raise ValueError('Escolha IMAP ou POP3.')
    for key in ('incoming', 'smtp'):
        host = a.get(key + 'Host', '')
        if not re.fullmatch(r'[A-Za-z0-9.-]+', host) or host.startswith('-'):
            raise ValueError('Informe o nome do servidor, sem protocolo ou caminho.')
        try:
            port = int(a[key + 'Port'])
        except (KeyError, ValueError, TypeError):
            raise ValueError('Informe uma porta válida.')
        if not 1 <= port <= 65535:
            raise ValueError('A porta deve estar entre 1 e 65535.')
        a[key + 'Port'] = port
        if a.get(key + 'Security') not in ('tls', 'starttls'):
            raise ValueError('Escolha TLS ou STARTTLS.')
    a['username'] = a.get('username') or a['email']
    a['smtpUsername'] = a.get('smtpUsername') or a['username']
    for field in ('name', 'username', 'smtpUsername'):
        if any(c in a.get(field, '') for c in '\r\n\x00'):
            raise ValueError('Campo inválido.')
    return {k: a[k] for k in ('id', 'name', 'email', 'protocol', 'username', 'smtpUsername',
                              'incomingHost', 'incomingPort', 'incomingSecurity',
                              'smtpHost', 'smtpPort', 'smtpSecurity', 'auth') if k in a}


def discover(address):
    if not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', address):
        raise ValueError('Informe um endereço de e-mail válido.')
    domain = address.rsplit('@', 1)[1].lower().encode('idna').decode()
    defaults = {
        'gmail.com': ('imap.gmail.com', 'smtp.gmail.com'),
        'googlemail.com': ('imap.gmail.com', 'smtp.gmail.com'),
        'outlook.com': ('outlook.office365.com', 'smtp-mail.outlook.com'),
        'hotmail.com': ('outlook.office365.com', 'smtp-mail.outlook.com'),
        'live.com': ('outlook.office365.com', 'smtp-mail.outlook.com'),
        'yahoo.com': ('imap.mail.yahoo.com', 'smtp.mail.yahoo.com'),
        'icloud.com': ('imap.mail.me.com', 'smtp.mail.me.com'),
    }
    a = dict(email=address, name='', username=address, smtpUsername=address, protocol='imap',
             incomingPort=993, incomingSecurity='tls', smtpPort=587, smtpSecurity='starttls', auth='password')
    if domain in defaults:
        a['incomingHost'], a['smtpHost'] = defaults[domain]
        return a
    # Thunderbird's public provider database: only the domain is submitted.
    request = urllib.request.Request('https://autoconfig.thunderbird.net/v1.1/' + urllib.parse.quote(domain),
                                     headers={'User-Agent': 'Lingmo-Mail/1.0'})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if urllib.parse.urlparse(response.url).scheme != 'https':
                raise ValueError('A configuração automática exige HTTPS.')
            root = ET.fromstring(response.read(512 * 1024))
    except (OSError, ET.ParseError):
        # URLError/HTTPError (404 = unknown provider) and timeouts are OSErrors
        raise ValueError('Não encontramos a configuração deste provedor. Preencha os servidores manualmente.')
    def choose(tag, kinds):
        for kind in kinds:
            for node in root.findall('.//' + tag):
                if node.get('type') == kind and node.findtext('socketType') in ('SSL', 'STARTTLS'):
                    return node
        raise ValueError('Provedor sem configuração segura publicada. Preencha os servidores manualmente.')
    incoming = choose('incomingServer', ('imap', 'pop3'))
    smtp = choose('outgoingServer', ('smtp',))
    a['protocol'] = incoming.get('type')
    for key, node in [('incoming', incoming), ('smtp', smtp)]:
        a[key + 'Host'] = node.findtext('hostname', '')
        a[key + 'Port'] = int(node.findtext('port', '0'))
        a[key + 'Security'] = 'tls' if node.findtext('socketType') == 'SSL' else 'starttls'
        user = node.findtext('username', '%EMAILADDRESS%').replace('%EMAILADDRESS%', address).replace('%EMAILLOCALPART%', address.split('@')[0]).replace('%EMAILDOMAIN%', domain)
        a['username' if key == 'incoming' else 'smtpUsername'] = user
    return validate(a)


def oauth_config():
    config = {}
    for path in [Path('/etc/lingmo-mail/google-oauth.json'), CONFIG / 'google-oauth.json']:
        if path.exists():
            config = json.loads(path.read_text()).get('installed', {}) or json.loads(path.read_text())
    if os.environ.get('LINGMO_GOOGLE_CLIENT_ID'):
        config['client_id'] = os.environ['LINGMO_GOOGLE_CLIENT_ID']
    if not config.get('client_id'):
        raise ValueError('O login Google ainda precisa do client ID OAuth do ArchLingmo. Você pode configurar o Gmail manualmente com uma senha de app.')
    return config


def post_token(values):
    data = urllib.parse.urlencode(values).encode()
    with urllib.request.urlopen(urllib.request.Request('https://oauth2.googleapis.com/token', data=data), timeout=30) as r:
        return json.load(r)


def google_login():
    cfg = oauth_config()
    verifier = secrets.token_urlsafe(48)
    state = secrets.token_urlsafe(32)
    result = {}
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if urllib.parse.urlparse(self.path).path != '/oauth2callback' or q.get('state') != [state]:
                self.send_error(400); return
            result.update(q)
            self.send_response(200); self.send_header('Content-Type', 'text/plain; charset=utf-8'); self.end_headers()
            self.wfile.write('Pode voltar ao Lingmo Mail.'.encode())
        def log_message(self, *args):
            pass
    with http.server.HTTPServer(('127.0.0.1', 0), Handler) as server:
        redirect = f'http://127.0.0.1:{server.server_port}/oauth2callback'
        params = dict(client_id=cfg['client_id'], redirect_uri=redirect, response_type='code',
                      scope='https://mail.google.com/ openid email', state=state, access_type='offline', prompt='consent',
                      code_challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('='),
                      code_challenge_method='S256')
        print(json.dumps({'event': 'openUrl', 'url': 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode(params)}), flush=True)
        server.timeout = 1
        deadline = time.monotonic() + 180
        while not result and time.monotonic() < deadline:
            server.handle_request()
    if 'code' not in result:
        raise ValueError('Login Google cancelado ou expirado.')
    values = dict(client_id=cfg['client_id'], code=result['code'][0], redirect_uri=redirect,
                  code_verifier=verifier, grant_type='authorization_code')
    if cfg.get('client_secret'):
        values['client_secret'] = cfg['client_secret']
    tokens = post_token(values)
    if not tokens.get('refresh_token'):
        raise ValueError('O Google não forneceu autorização persistente. Tente novamente.')
    request = urllib.request.Request('https://openidconnect.googleapis.com/v1/userinfo',
                                     headers={'Authorization': 'Bearer ' + tokens['access_token']})
    with urllib.request.urlopen(request, timeout=30) as r:
        profile = json.load(r)
    if not profile.get('email_verified'):
        raise ValueError('O Google não confirmou o endereço de e-mail.')
    a = discover(profile['email']) if profile['email'].split('@')[1] in ('gmail.com','googlemail.com') else dict(discover('user@gmail.com'),email=profile['email'],username=profile['email'],smtpUsername=profile['email'])
    a.update(name=profile.get('name',''), auth='google')
    return save(a, json.dumps({'refresh_token':tokens['refresh_token']}))


def credentials(a, supplied=None):
    raw = supplied if supplied else secret(a['id'])
    if not raw:
        raise ValueError('Informe a senha da conta.')
    if a.get('auth') != 'google':
        return raw, False
    cfg = oauth_config()
    values = dict(client_id=cfg['client_id'], refresh_token=json.loads(raw)['refresh_token'], grant_type='refresh_token')
    if cfg.get('client_secret'):
        values['client_secret'] = cfg['client_secret']
    return post_token(values)['access_token'], True


def auth_bytes(user, token):
    return f'user={user}\x01auth=Bearer {token}\x01\x01'.encode()


@contextlib.contextmanager
def incoming(a, password, oauth):
    c = None
    try:
        if a['protocol'] == 'imap':
            if a['incomingSecurity'] == 'tls':
                c = imaplib.IMAP4_SSL(a['incomingHost'], a['incomingPort'], ssl_context=TLS, timeout=25)
            else:
                c = imaplib.IMAP4(a['incomingHost'], a['incomingPort'], timeout=25); c.starttls(ssl_context=TLS)
            if oauth:
                c.authenticate('XOAUTH2', lambda _: auth_bytes(a['username'], password))
            else:
                c.login(a['username'], password)
        else:
            if oauth:
                raise ValueError('Use IMAP para uma conta Google conectada por OAuth.')
            if a['incomingSecurity'] == 'tls':
                c = poplib.POP3_SSL(a['incomingHost'], a['incomingPort'], context=TLS, timeout=25)
            else:
                c = poplib.POP3(a['incomingHost'], a['incomingPort'], timeout=25); c.stls(context=TLS)
            c.user(a['username']); c.pass_(password)
        yield c
    finally:
        if c:
            try:
                c.logout() if a['protocol'] == 'imap' else c.quit()
            except Exception:
                pass


@contextlib.contextmanager
def outgoing(a, password, oauth):
    c = None
    try:
        if a['smtpSecurity'] == 'tls':
            c = smtplib.SMTP_SSL(a['smtpHost'], a['smtpPort'], timeout=25, context=TLS)
        else:
            c = smtplib.SMTP(a['smtpHost'], a['smtpPort'], timeout=25)
            c.ehlo(); c.starttls(context=TLS); c.ehlo()
        if oauth:
            c.auth('XOAUTH2', lambda challenge=None: auth_bytes(a['smtpUsername'], password).decode() if challenge is None else '')
        else:
            c.login(a['smtpUsername'], password)
        yield c
    finally:
        if c:
            try: c.quit()
            except Exception: c.close()


def save(account, password):
    a = validate(account)
    old = next((x for x in read_accounts() if x.get('id') == a.get('id')), None)
    if not old:
        old = next((x for x in read_accounts() if x['email'].lower() == a['email'].lower()), None)
    a['id'] = old['id'] if old else str(uuid.uuid4())
    if not password and old and any(a.get(k) != old.get(k) for k in ('incomingHost','incomingPort','smtpHost','smtpPort','username','smtpUsername','auth')):
        raise ValueError('Informe novamente a senha ao alterar servidores ou autenticação.')
    google = a['incomingHost'].lower() == 'imap.gmail.com'
    if google and a.get('auth') != 'google':
        # Google shows app passwords as 'abcd efgh ijkl mnop'; the spaces aren't part of it
        password = password.replace(' ', '')
    pw, oauth = credentials(a, password)
    try:
        with incoming(a, pw, oauth): pass
        with outgoing(a, pw, oauth): pass
    except AUTH_ERRORS + (smtplib.SMTPAuthenticationError,) as exc:
        if google and not oauth and not isinstance(exc, IMAP_ABORT):
            raise ValueError('O Gmail não aceita a senha normal da conta Google. Ative a verificação em duas etapas '
                             'e crie uma senha de app (16 letras) em myaccount.google.com/apppasswords.')
        raise
    if password:
        secret(a['id'], password)
    update_accounts(lambda items: [x for x in items if x['id'] != a['id']] + [a])
    return a


def account_by_id(value):
    for a in read_accounts():
        if a['id'] == value:
            return validate(a)
    raise ValueError('Selecione uma conta.')


def summary(raw, uid):
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    return dict(id=str(uid), subject=str(msg.get('Subject', '(Sem assunto)')), sender=str(msg.get('From','')),
                to=str(msg.get('To','')), date=str(msg.get('Date','')))


def inbox(a):
    pw, oauth = credentials(a)
    items = []
    with incoming(a, pw, oauth) as c:
        if a['protocol'] == 'imap':
            if c.select('INBOX', readonly=True)[0] != 'OK': raise ValueError('Não foi possível abrir a caixa de entrada.')
            status, data = c.uid('search', None, 'ALL')
            if status != 'OK': raise ValueError('Falha ao listar as mensagens.')
            for uid in reversed(data[0].split()[-50:]):
                status, data = c.uid('fetch', uid, '(BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)])')
                if status == 'OK':
                    raw = b''.join(v[1] for v in data if isinstance(v, tuple))
                    items.append(summary(raw, uid.decode()))
        else:
            _, entries, _ = c.uidl()
            for entry in reversed(entries[-50:]):
                number, uid = entry.split()
                try:
                    _, lines, _ = c.top(int(number), 0)
                except poplib.error_proto:
                    raise ValueError('Este servidor POP3 não oferece prévia de mensagens (TOP). Use IMAP.')
                items.append(summary(b'\r\n'.join(lines), uid.decode()))
    return items


def read_message(a, uid):
    pw, oauth = credentials(a)
    with incoming(a, pw, oauth) as c:
        if a['protocol'] == 'imap':
            if not str(uid).isdigit(): raise ValueError('Mensagem inválida.')
            c.select('INBOX', readonly=True)
            status, sizes = c.uid('fetch', uid, '(RFC822.SIZE)')
            if status != 'OK': raise ValueError('Mensagem não encontrada.')
            size = re.search(rb'RFC822.SIZE (\d+)', b' '.join(x for x in sizes if isinstance(x, bytes)))
            if not size or int(size[1]) > LIMIT: raise ValueError('Mensagem maior que 20 MB ou indisponível.')
            status, data = c.uid('fetch', uid, '(BODY.PEEK[])')
            if status != 'OK': raise ValueError('Não foi possível ler a mensagem.')
            raw = b''.join(v[1] for v in data if isinstance(v, tuple))
        else:
            _, entries, _ = c.uidl()
            number = next((int(x.split()[0]) for x in entries if x.split()[1].decode() == uid), None)
            if number is None: raise ValueError('Mensagem não encontrada.')
            size = int(c.list(number).split()[2])
            if size > LIMIT: raise ValueError('Mensagem maior que 20 MB.')
            _, lines, _ = c.retr(number); raw = b'\r\n'.join(lines)
    if len(raw) > LIMIT: raise ValueError('Mensagem maior que 20 MB.')
    return parse_message(raw, uid)


def message_ids(value):
    """Message-ID list from a header, or '' when it isn't a clean list of <ids>."""
    value = ' '.join(str(value or '').split())
    if len(value) > 4096 or not re.fullmatch(r'(<[^<>\s]+>\s?)*', value):
        return ''
    return value


def parse_message(raw, uid):
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    result = summary(raw, uid)
    result['cc'] = str(msg.get('Cc', ''))
    result['replyTo'] = str(msg.get('Reply-To', ''))
    result['messageId'] = message_ids(msg.get('Message-ID', ''))
    result['references'] = message_ids(msg.get('References', ''))
    part = msg.get_body(preferencelist=('plain',))
    if part:
        result['body'] = part.get_content()
    else:
        from html.parser import HTMLParser
        class TextOnly(HTMLParser):
            def __init__(self): super().__init__(); self.parts=[]; self.hidden=0
            def handle_starttag(self, tag, attrs):
                if tag in ('script','style'): self.hidden += 1
                if tag in ('br','p','div','tr'): self.parts.append('\n')
            def handle_endtag(self, tag):
                if tag in ('script','style'): self.hidden = max(0,self.hidden-1)
            def handle_data(self, data):
                if not self.hidden: self.parts.append(data)
        html = msg.get_body(preferencelist=('html',)); parser = TextOnly()
        if html: parser.feed(html.get_content())
        result['body'] = ''.join(parser.parts) or '(Mensagem sem texto)'
    result['attachments'] = [p.get_filename() or 'Anexo' for p in msg.iter_attachments()]
    return result


def valid_recipients(value, required):
    if not value.strip():
        return not required
    recipients = getaddresses([value])
    return bool(recipients) and all(re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', addr) for _, addr in recipients)


def build_message(a, draft):
    """The outgoing message; raises ValueError before any network access."""
    for key in ('to', 'cc', 'subject', 'inReplyTo', 'references'):
        value = draft.get(key, '')
        if not isinstance(value, str) or any(ch in value for ch in '\r\n\x00'):
            raise ValueError('Cabeçalho inválido.')
    if not isinstance(draft.get('body', ''), str):
        raise ValueError('Mensagem inválida.')
    if not valid_recipients(draft.get('to', ''), True):
        raise ValueError('Informe destinatários válidos, separados por vírgula.')
    if not valid_recipients(draft.get('cc', ''), False):
        raise ValueError('Informe destinatários em cópia válidos, separados por vírgula.')
    for key in ('inReplyTo', 'references'):
        if draft.get(key) and message_ids(draft[key]) != ' '.join(draft[key].split()):
            raise ValueError('Cabeçalho inválido.')
    msg = EmailMessage()
    msg['From'] = formataddr((a.get('name',''),a['email']))
    msg['To'] = draft['to']; msg['Subject'] = draft.get('subject','')
    if draft.get('cc', '').strip():
        msg['Cc'] = draft['cc']
    if draft.get('inReplyTo'):
        msg['In-Reply-To'] = message_ids(draft['inReplyTo'])
    if draft.get('references'):
        msg['References'] = message_ids(draft['references'])
    msg['Date'] = email.utils.formatdate(localtime=True); msg['Message-ID'] = email.utils.make_msgid()
    msg.set_content(draft.get('body',''))
    return msg


def send(a, draft):
    msg = build_message(a, draft)
    raw = msg.as_bytes()
    if len(raw) > LIMIT: raise ValueError('Mensagem maior que 20 MB.')
    pw, oauth = credentials(a)
    with outgoing(a, pw, oauth) as c:
        refused = c.send_message(msg)
    return {'sent': True, 'refused': list(refused)}


def dispatch(req):
    op = req.get('op')
    if op == 'accounts': return read_accounts()
    if op == 'discover': return discover(req['email'])
    if op == 'save': return save(req['account'], req.get('password',''))
    if op == 'google': return google_login()
    a = account_by_id(req.get('id'))
    if op == 'inbox': return inbox(a)
    if op == 'read': return read_message(a, req['message'])
    if op == 'send': return send(a, req['draft'])
    if op == 'remove':
        secret(a['id'], remove=True)
        return update_accounts(lambda items: [x for x in items if x['id'] != a['id']])
    raise ValueError('Operação desconhecida.')


def main():
    try:
        req = json.loads(sys.stdin.buffer.readline(1024 * 1024))
        result = dispatch(req)
        print(json.dumps({'ok': True, 'data': result}, ensure_ascii=False))
    except Exception as exc:
        # Never echo protocol responses: they may contain credentials or message data.
        if isinstance(exc, AUTH_ERRORS) and not isinstance(exc, IMAP_ABORT):
            exc = ValueError('O servidor recusou o acesso. Confira o usuário e a senha (ou senha de app).')
        message = str(exc) if isinstance(exc, ValueError) else {
            'SSLCertVerificationError': 'O certificado do servidor não é válido.',
            'TimeoutError': 'O servidor demorou para responder. Tente novamente.',
            'gaierror': 'Servidor não encontrado. Confira o endereço e a conexão.',
            'SMTPAuthenticationError': 'O servidor recusou a autenticação. Confira a senha de app ou a autorização da conta.',
        }.get(type(exc).__name__, 'Não foi possível concluir. Confira os servidores, a conexão e a senha de app ou autorização do provedor.')
        print(json.dumps({'ok': False, 'error': message}, ensure_ascii=False))
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
