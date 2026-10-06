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


# ---------- Local storage (rules, processing state, contacts)

def mail_config():
    return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'lingmo-mail'


def mail_data():
    return Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local' / 'share') / 'lingmo-mail'


def read_json(path, default):
    try:
        data = json.loads(path.read_text())
    except (FileNotFoundError, ValueError):
        return default
    return data if isinstance(data, type(default)) else default


def update_json(path, default, transform):
    """Read-modify-write under an exclusive lock, replaced atomically."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (path.parent / (path.name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = transform(read_json(path, default))
        fd, tmp = tempfile.mkstemp(dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(data, out, ensure_ascii=False)
                out.flush()
                os.fsync(out.fileno())
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    return data


def single_line(value, limit, what='Campo'):
    if not isinstance(value, str) or len(value) > limit or any(c in value for c in '\r\n\x00'):
        raise ValueError(f'{what} inválido.')
    return value.strip()


ADDRESS = re.compile(r'[^\s@<>,;"]+@[^\s@<>,;"]+\.[^\s@<>,;"]+')


# ---------- IMAP folders

def utf7_decode(value):
    """IMAP modified UTF-7 (RFC 3501 5.1.3) to text."""
    out, i = [], 0
    while i < len(value):
        if value[i] != '&':
            out.append(value[i]); i += 1; continue
        end = value.index('-', i)
        if end == i + 1:
            out.append('&')
        else:
            chunk = value[i + 1:end].replace(',', '/')
            out.append(base64.b64decode(chunk + '=' * (-len(chunk) % 4)).decode('utf-16-be'))
        i = end + 1
    return ''.join(out)


def utf7_encode(value):
    out, pending = [], []
    def flush():
        if pending:
            encoded = base64.b64encode(''.join(pending).encode('utf-16-be')).decode().rstrip('=')
            out.append('&' + encoded.replace('/', ',') + '-'); pending.clear()
    for ch in value:
        if 0x20 <= ord(ch) <= 0x7e:
            flush(); out.append('&-' if ch == '&' else ch)
        else:
            pending.append(ch)
    flush()
    return ''.join(out)


def quote(value):
    """An IMAP quoted string; only for ASCII values without line breaks."""
    if not value.isascii() or any(c in value for c in '\r\n\x00'):
        raise ValueError('Valor inválido.')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def unquote(token):
    token = token.strip()
    if token.startswith(b'"') and token.endswith(b'"') and len(token) >= 2:
        token = re.sub(rb'\\(.)', rb'\1', token[1:-1])
    return token.decode('utf-8', 'replace')


LIST_LINE = re.compile(rb'\((?P<flags>[^)]*)\)\s+(?P<delim>NIL|"(?:[^"\\]|\\.)*")\s+(?P<name>.+)$', re.I | re.S)

ROLE_FLAGS = {'\\sent': 'sent', '\\drafts': 'drafts', '\\trash': 'trash', '\\junk': 'junk',
              '\\archive': 'archive', '\\all': 'all'}
ROLE_NAMES = {
    'sent': {'sent', 'sent mail', 'sent items', 'sent messages', 'enviados', 'enviadas', 'itens enviados',
             'mensagens enviadas', 'e-mails enviados', 'emails enviados'},
    'drafts': {'drafts', 'draft', 'rascunhos', 'rascunho'},
    'trash': {'trash', 'deleted', 'deleted items', 'deleted messages', 'bin', 'lixeira', 'lixo',
              'itens excluídos', 'itens excluidos', 'excluídos', 'excluidos', 'itens apagados'},
    'junk': {'junk', 'spam', 'junk e-mail', 'junk email', 'bulk mail', 'lixo eletrônico', 'lixo eletronico',
             'e-mail de lixo eletrônico'},
    'archive': {'archive', 'archives', 'arquivo', 'arquivos', 'arquivados', 'arquivadas'},
    'all': {'all mail', 'todos os e-mails', 'todos os emails', 'todas as mensagens'},
}
ROLE_ORDER = ['inbox', 'drafts', 'sent', 'archive', 'all', 'junk', 'trash']


def parse_list(data):
    """LIST response -> [{path, name, delimiter, flags, selectable}]; path is the server's own name."""
    found = []
    for item in data or []:
        literal = None
        if isinstance(item, tuple):
            item, literal = item[0], item[1]
        if not isinstance(item, bytes):
            continue
        m = LIST_LINE.match(item.strip())
        if not m:
            continue
        flags = [f.lower() for f in m['flags'].decode('ascii', 'replace').split()]
        delimiter = '' if m['delim'].upper() == b'NIL' else unquote(m['delim'])
        name = m['name'].strip()
        if literal is not None and re.fullmatch(rb'\{\d+\}', name):
            path = literal.decode('utf-8', 'replace')
        elif name.startswith(b'"'):
            path = unquote(name)
        else:
            path = name.decode('utf-8', 'replace')
        # Only names we can send back safely (mUTF-7 is ASCII)
        if not path or len(path) > 1000 or not path.isascii() or any(c in path for c in '\r\n\x00'):
            continue
        if path.upper() == 'INBOX':
            path = 'INBOX'
        try:
            display = utf7_decode(path)
        except (ValueError, UnicodeError):
            display = path
        leaf = display.rsplit(delimiter, 1)[-1] if delimiter else display
        found.append(dict(path=path, name=leaf or display, display=display, delimiter=delimiter, flags=flags,
                          selectable=not ({'\\noselect', '\\nonexistent'} & set(flags))))
    return found


def assign_roles(folders):
    """RFC 6154 special-use flags first, then well-known names (English, pt-BR, Gmail)."""
    taken = {}
    for f in folders:
        f['role'] = ''
    for f in folders:
        if f['path'] == 'INBOX':
            f['role'] = 'inbox'; taken['inbox'] = f
    for f in folders:
        if not f['selectable'] or f['role']:
            continue
        for flag in f['flags']:
            role = ROLE_FLAGS.get(flag)
            if role and role not in taken:
                f['role'] = role; taken[role] = f
                break
    for f in folders:
        if not f['selectable'] or f['role']:
            continue
        leaf = f['name'].casefold()
        for role, names in ROLE_NAMES.items():
            if role not in taken and leaf in names:
                f['role'] = role; taken[role] = f
                break
    return folders


def folder_depth(f, paths):
    if not f['delimiter']:
        return 0
    parts = f['path'].split(f['delimiter'])
    return sum(1 for n in range(1, len(parts)) if f['delimiter'].join(parts[:n]) in paths)


def list_folders(c):
    status, data = c.list()
    if status != 'OK':
        raise ValueError('Não foi possível listar as pastas.')
    folders = assign_roles(parse_list(data))
    if not any(f['path'] == 'INBOX' for f in folders):
        folders.insert(0, dict(path='INBOX', name='INBOX', display='INBOX', delimiter='', flags=[],
                               selectable=True, role='inbox'))
    selectable = [f for f in folders if f['selectable']]
    paths = {f['path'] for f in selectable}
    for f in selectable:
        f['depth'] = folder_depth(f, paths)
    def key(f):
        role = f['role']
        return (ROLE_ORDER.index(role) if role else len(ROLE_ORDER), f['display'].casefold())
    # Special folders on top, the rest alphabetically (parents sort before their children)
    return sorted(selectable, key=key)


def public_folder(f):
    return {k: f[k] for k in ('path', 'name', 'role', 'depth', 'unread') if k in f}


def add_unread_counts(c, folders, limit=80):
    for f in folders[:limit]:
        f['unread'] = -1
        try:
            status, data = c.status(quote(f['path']), '(UNSEEN)')
        except (imaplib.IMAP4.error, ValueError):
            continue
        m = re.search(rb'UNSEEN (\d+)', b' '.join(x for x in data if isinstance(x, bytes))) if status == 'OK' else None
        if m:
            f['unread'] = int(m[1])
    for f in folders[limit:]:
        f['unread'] = -1
    return folders


def find_folder(folders, path=None, role=None):
    for f in folders:
        if (path is not None and f['path'] == path) or (role and f['role'] == role):
            return f
    return None


def checked_folder(folders, path):
    if not isinstance(path, str) or not path:
        return find_folder(folders, 'INBOX')
    f = find_folder(folders, path)
    if not f:
        raise ValueError('Pasta não encontrada no servidor.')
    return f


def select(c, folder, readonly):
    status, _ = c.select(quote(folder['path']), readonly=readonly)
    if status != 'OK':
        raise ValueError('Não foi possível abrir a pasta.')


def uid_set(values):
    if not isinstance(values, list) or not 1 <= len(values) <= 1000:
        raise ValueError('Selecione mensagens válidas.')
    uids = []
    for v in values:
        v = str(v)
        if not re.fullmatch(r'[1-9][0-9]{0,9}', v):
            raise ValueError('Mensagem inválida.')
        uids.append(v)
    return ','.join(dict.fromkeys(uids))


# ---------- Message list: search, flags and structure without downloading bodies

FILTERS = {'all': [], 'unread': ['UNSEEN'], 'flagged': ['FLAGGED'],
           # No IMAP key for "has attachment": mixed multiparts are the usual carrier; the page is
           # filtered again with BODYSTRUCTURE below.
           'attachment': ['HEADER', '"Content-Type"', '"multipart/mixed"']}
SEARCH_KEYS = {'text': 'TEXT', 'from': 'FROM', 'subject': 'SUBJECT'}


def search_criteria(filter_name='all', field='text', query=''):
    """(arguments, literal) for UID SEARCH. A non-ASCII query goes as a UTF-8 literal, last."""
    if filter_name not in FILTERS or field not in SEARCH_KEYS:
        raise ValueError('Filtro inválido.')
    query = single_line(query or '', 200, 'Termo de busca')
    args, literal = list(FILTERS[filter_name]), None
    if query:
        if query.isascii():
            args += [SEARCH_KEYS[field], quote(query)]
        else:
            args = ['CHARSET', 'UTF-8'] + args + [SEARCH_KEYS[field]]
            literal = query.encode()
    return (args or ['ALL']), literal


def uid_search(c, args, literal=None):
    if literal is not None:
        c.literal = literal
    status, data = c.uid('SEARCH', *args)
    if status != 'OK':
        raise ValueError('O servidor não aceitou a busca.' if literal is not None else 'Falha ao listar as mensagens.')
    return [int(x) for x in b' '.join(x for x in data if isinstance(x, bytes)).split() if x.isdigit()]


HEADER_FIELDS = 'BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE)]'
FETCH_ITEMS = '(UID FLAGS BODYSTRUCTURE ' + HEADER_FIELDS + ')'


def parse_fetch(data):
    """FETCH responses -> [{meta, header}], tolerant of item order and extra literals."""
    records, current = [], None
    for item in data or []:
        if isinstance(item, tuple):
            meta, literal = item[0], item[1]
            if re.match(rb'\d+ \(', meta):
                current = dict(meta=b'', header=b''); records.append(current)
            if current is None:
                continue
            current['meta'] += meta
            if re.search(rb'BODY\[HEADER\.FIELDS[^\]]*\]\s*\{\d+\}\s*$', meta, re.I):
                current['header'] = literal
            else:
                current['meta'] += b'"' + literal.replace(b'"', b'').replace(b'\\', b'') + b'"'
        elif isinstance(item, bytes):
            if re.match(rb'\d+ \(', item):
                current = dict(meta=item, header=b''); records.append(current)
            elif current is not None:
                current['meta'] += item
    return records


ATTACHMENT_HINT = re.compile(rb'"(ATTACHMENT|FILENAME|NAME)"', re.I)


def fetch_record_summary(record):
    meta = record['meta']
    uid = re.search(rb'UID (\d+)', meta)
    if not uid:
        return None
    flags = re.search(rb'FLAGS \(([^)]*)\)', meta)
    flags = flags[1].decode('ascii', 'replace').lower().split() if flags else []
    s = summary(record['header'], uid[1].decode())
    msg = email.message_from_bytes(record['header'], policy=email.policy.default)
    s['cc'] = str(msg.get('Cc', ''))
    structure = meta[meta.upper().find(b'BODYSTRUCTURE'):] if b'BODYSTRUCTURE' in meta.upper() else b''
    s.update(unread='\\seen' not in flags, starred='\\flagged' in flags, answered='\\answered' in flags,
             hasAttachment=bool(ATTACHMENT_HINT.search(structure)))
    return s


def fetch_summaries(c, uids):
    if not uids:
        return []
    found = {}
    for start in range(0, len(uids), 200):
        chunk = uids[start:start + 200]
        status, data = c.uid('FETCH', ','.join(str(u) for u in chunk), FETCH_ITEMS)
        if status != 'OK':
            raise ValueError('Falha ao listar as mensagens.')
        for record in parse_fetch(data):
            s = fetch_record_summary(record)
            if s:
                found[int(s['id'])] = s
    return [found[u] for u in uids if u in found]


def capabilities(c):
    return {str(x).upper() for x in getattr(c, 'capabilities', ())}


def move_uids(c, uids, target):
    """UID MOVE when the server has it, else COPY + \\Deleted + (UID) EXPUNGE."""
    caps = capabilities(c)
    if 'MOVE' in caps:
        status, _ = c.uid('MOVE', uids, quote(target['path']))
        if status != 'OK':
            raise ValueError('Não foi possível mover as mensagens.')
        return
    status, _ = c.uid('COPY', uids, quote(target['path']))
    if status != 'OK':
        raise ValueError('Não foi possível mover as mensagens.')
    delete_uids(c, uids)


def delete_uids(c, uids):
    status, _ = c.uid('STORE', uids, '+FLAGS.SILENT', '(\\Deleted)')
    if status != 'OK':
        raise ValueError('Não foi possível apagar as mensagens.')
    if 'UIDPLUS' in capabilities(c):
        c.uid('EXPUNGE', uids)
    else:
        c.expunge()


def store_flag(c, uids, flag, on):
    status, _ = c.uid('STORE', uids, '+FLAGS.SILENT' if on else '-FLAGS.SILENT', '(' + flag + ')')
    if status != 'OK':
        raise ValueError('Não foi possível alterar as mensagens.')


# ---------- Rules

RULE_FIELDS = ('from', 'to', 'subject', 'attachment')
RULE_ACTIONS = ('move', 'read', 'star', 'delete')


def rules_path():
    return mail_config() / 'rules.json'


def clean_rules(rules):
    if not isinstance(rules, list) or len(rules) > 200:
        raise ValueError('Regras inválidas.')
    out = []
    for r in rules:
        if not isinstance(r, dict):
            raise ValueError('Regra inválida.')
        rid = r.get('id') if isinstance(r.get('id'), str) and re.fullmatch(r'[0-9a-f-]{36}', r.get('id', '')) else str(uuid.uuid4())
        name = single_line(r.get('name', ''), 120, 'Nome da regra') or 'Regra'
        match = r.get('match', 'all')
        if match not in ('all', 'any'):
            raise ValueError('Regra inválida.')
        conditions = []
        for cond in r.get('conditions') or []:
            if not isinstance(cond, dict) or cond.get('field') not in RULE_FIELDS:
                raise ValueError('Condição inválida.')
            value = '' if cond['field'] == 'attachment' else single_line(cond.get('value', ''), 200, 'Condição')
            if cond['field'] != 'attachment' and not value:
                raise ValueError('Preencha o texto de cada condição.')
            conditions.append(dict(field=cond['field'], value=value))
        actions, kinds = [], set()
        for act in r.get('actions') or []:
            if not isinstance(act, dict) or act.get('type') not in RULE_ACTIONS or act['type'] in kinds:
                raise ValueError('Ação inválida.')
            kinds.add(act['type'])
            entry = dict(type=act['type'])
            if act['type'] == 'move':
                entry['folder'] = single_line(act.get('folder', ''), 1000, 'Pasta')
                if not entry['folder'] or not entry['folder'].isascii():
                    raise ValueError('Escolha a pasta de destino.')
            actions.append(entry)
        if not 1 <= len(conditions) <= 10 or not 1 <= len(actions) <= 4:
            raise ValueError('Cada regra precisa de pelo menos uma condição e uma ação.')
        if {'move', 'delete'} <= kinds:
            raise ValueError('Uma regra não pode mover e apagar ao mesmo tempo.')
        out.append(dict(id=rid, name=name, enabled=bool(r.get('enabled', True)), match=match,
                        conditions=conditions, actions=actions))
    return out


def load_rules(account_id):
    data = read_json(rules_path(), {}).get(account_id, [])
    try:
        return clean_rules(data)
    except ValueError:
        return []


def save_rules(account_id, rules):
    rules = clean_rules(rules)
    def change(data):
        data[account_id] = rules
        return data
    update_json(rules_path(), {}, change)
    return rules


def rule_matches(rule, msg):
    results = []
    for cond in rule['conditions']:
        if cond['field'] == 'attachment':
            results.append(bool(msg.get('hasAttachment')))
            continue
        text = {'from': msg.get('sender', ''), 'subject': msg.get('subject', ''),
                'to': msg.get('to', '') + ' ' + msg.get('cc', '')}[cond['field']]
        results.append(cond['value'].casefold() in text.casefold())
    return all(results) if rule['match'] == 'all' else any(results)


def plan_rules(rules, messages, folders):
    """What to do: {'read': [uid], 'star': [uid], 'delete': [uid], 'move': {path: [uid]}}.
    Rules run in order; a move or delete ends processing for that message."""
    plan = {'read': [], 'star': [], 'delete': [], 'move': {}}
    for msg in messages:
        uid = msg['id']
        for rule in rules:
            if not rule['enabled'] or not rule_matches(rule, msg):
                continue
            final = False
            for act in rule['actions']:
                if act['type'] in ('read', 'star') and uid not in plan[act['type']]:
                    plan[act['type']].append(uid)
                elif act['type'] == 'delete':
                    plan['delete'].append(uid); final = True
                elif act['type'] == 'move':
                    target = find_folder(folders, act['folder'])
                    if target and target['path'] != 'INBOX':
                        plan['move'].setdefault(target['path'], []).append(uid); final = True
            if final:
                break
    return plan


def run_plan(c, plan, folders):
    """Applies a plan in the selected INBOX; returns the UIDs that left it."""
    removed = set()
    for kind, flag in (('read', '\\Seen'), ('star', '\\Flagged')):
        if plan[kind]:
            store_flag(c, ','.join(plan[kind]), flag, True)
    for path, uids in plan['move'].items():
        move_uids(c, ','.join(uids), find_folder(folders, path)); removed.update(uids)
    trash = find_folder(folders, role='trash')
    if plan['delete'] and trash and trash['path'] != 'INBOX':
        # Rules only ever move to the Trash: nothing is destroyed without the user
        move_uids(c, ','.join(plan['delete']), trash); removed.update(plan['delete'])
    return removed


def state_path():
    return mail_config() / 'state.json'


@contextlib.contextmanager
def account_lock(account_id):
    """Non-blocking per-account lock so two workers never process the same new mail."""
    directory = mail_config()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = hashlib.sha256(account_id.encode()).hexdigest()[:16]
    with (directory / f'inbox-{name}.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True


def inbox_status(c):
    status, data = c.status('"INBOX"', '(UIDNEXT UIDVALIDITY)')
    joined = b' '.join(x for x in data if isinstance(x, bytes)) if status == 'OK' else b''
    nxt, validity = re.search(rb'UIDNEXT (\d+)', joined), re.search(rb'UIDVALIDITY (\d+)', joined)
    if not nxt or not validity:
        return None
    return int(validity[1]), int(nxt[1])


def process_new_mail(c, a, folders):
    """Rules for INBOX messages that arrived since the last run, each processed once
    (tracked by UIDVALIDITY + last UID). Returns what to notify about."""
    result = dict(count=0, items=[])
    with account_lock(a['id']) as mine:
        if not mine:
            return result
        info = inbox_status(c)
        if not info:
            return result
        validity, uidnext = info
        state = read_json(state_path(), {}).get(a['id'])
        def remember(last):
            def change(data):
                data[a['id']] = dict(uidvalidity=validity, lastUid=last)
                return data
            update_json(state_path(), {}, change)
        if not isinstance(state, dict) or state.get('uidvalidity') != validity or not isinstance(state.get('lastUid'), int):
            # First run (or the server renumbered): start from here, nothing old is touched
            remember(uidnext - 1)
            return result
        last = state['lastUid']
        if uidnext - 1 <= last:
            return result
        select(c, find_folder(folders, 'INBOX'), readonly=False)
        uids = [u for u in uid_search(c, ['UID', f'{last + 1}:*']) if u > last]
        if not uids:
            remember(max(last, uidnext - 1))
            return result
        try:
            messages = fetch_summaries(c, sorted(uids)[-300:])
            rules = [r for r in load_rules(a['id']) if r['enabled']]
            removed = set()
            if rules:
                try:
                    removed = run_plan(c, plan_rules(rules, messages, folders), folders)
                except (ValueError, imaplib.IMAP4.error):
                    pass   # the mail is still there; rules are best effort
            fresh = [m for m in messages if m['id'] not in removed and m['unread']]
            result['count'] = len(fresh)
            result['items'] = [dict(subject=m['subject'], sender=m['sender']) for m in fresh[-3:]][::-1]
        finally:
            remember(max(uids))
    return result


def apply_rules_now(a):
    if a['protocol'] != 'imap':
        raise ValueError('Regras funcionam apenas com contas IMAP.')
    rules = [r for r in load_rules(a['id']) if r['enabled']]
    if not rules:
        raise ValueError('Não há regras ativas para esta conta.')
    pw, oauth = credentials(a)
    with incoming(a, pw, oauth) as c:
        folders = list_folders(c)
        select(c, find_folder(folders, 'INBOX'), readonly=False)
        uids = uid_search(c, ['ALL'])[-1000:]
        messages = fetch_summaries(c, uids)
        plan = plan_rules(rules, messages, folders)
        touched = set(plan['read']) | set(plan['star']) | set(plan['delete'])
        for v in plan['move'].values():
            touched.update(v)
        run_plan(c, plan, folders)
    return dict(matched=len(touched))


# ---------- Folder listing, actions, reading

def pop3_folders():
    return [dict(path='INBOX', name='INBOX', role='inbox', depth=0, unread=-1)]


def list_messages(a, req):
    folder_path = req.get('folder') or 'INBOX'
    try:
        limit = max(1, min(int(req.get('limit', 50)), 500))
    except (TypeError, ValueError):
        raise ValueError('Pedido inválido.')
    newest_first = req.get('sort', 'desc') != 'asc'
    search = req.get('search') or {}
    if not isinstance(search, dict):
        raise ValueError('Pedido inválido.')
    args, literal = search_criteria(req.get('filter', 'all'), search.get('field', 'text'), search.get('query', ''))
    if a['protocol'] != 'imap':
        if folder_path != 'INBOX':
            raise ValueError('Contas POP3 têm apenas a caixa de entrada.')
        items = inbox(a)
        return dict(id=a['id'], folders=pop3_folders(), folder='INBOX', messages=items, total=len(items),
                    hasMore=False, pop3=True, newMail=dict(count=0, items=[]))
    pw, oauth = credentials(a)
    with incoming(a, pw, oauth) as c:
        folders = list_folders(c)
        folder = checked_folder(folders, folder_path)
        new_mail = process_new_mail(c, a, folders) if req.get('checkNew', True) else dict(count=0, items=[])
        select(c, folder, readonly=True)
        uids = sorted(uid_search(c, args, literal), reverse=newest_first)
        messages = fetch_summaries(c, uids[:limit])
        if req.get('filter') == 'attachment':
            messages = [m for m in messages if m['hasAttachment']]
        add_unread_counts(c, folders)
    return dict(id=a['id'], folders=[public_folder(f) for f in folders], folder=folder['path'], messages=messages,
                total=len(uids), hasMore=len(uids) > limit, pop3=False, newMail=new_mail)


def check_account(a):
    """Background check of another account: new mail (with rules) and folder counts."""
    if a['protocol'] != 'imap':
        return dict(id=a['id'], folders=pop3_folders(), newMail=dict(count=0, items=[]), pop3=True)
    pw, oauth = credentials(a)
    with incoming(a, pw, oauth) as c:
        folders = list_folders(c)
        new_mail = process_new_mail(c, a, folders)
        add_unread_counts(c, folders)
    return dict(id=a['id'], folders=[public_folder(f) for f in folders], newMail=new_mail, pop3=False)


def act(a, req):
    """Flags, archive, move and delete on UIDs of one folder."""
    if a['protocol'] != 'imap':
        raise ValueError('Esta ação precisa de uma conta IMAP.')
    action = req.get('action')
    if action not in ('read', 'unread', 'star', 'unstar', 'archive', 'move', 'delete'):
        raise ValueError('Ação desconhecida.')
    uids = uid_set(req.get('uids'))
    pw, oauth = credentials(a)
    with incoming(a, pw, oauth) as c:
        folders = list_folders(c)
        folder = checked_folder(folders, req.get('folder'))
        target = None
        if action == 'archive':
            target = find_folder(folders, role='archive') or find_folder(folders, role='all')
            if not target:
                raise ValueError('Esta conta não tem uma pasta de arquivo.')
        elif action == 'move':
            target = find_folder(folders, req.get('target')) if isinstance(req.get('target'), str) else None
            if not target:
                raise ValueError('Pasta de destino não encontrada no servidor.')
        elif action == 'delete':
            trash = find_folder(folders, role='trash')
            if not trash or trash['path'] == folder['path']:
                if req.get('permanent') is not True:
                    return dict(confirm=True)
            else:
                target = trash
        if target and target['path'] == folder['path']:
            raise ValueError('As mensagens já estão nesta pasta.')
        select(c, folder, readonly=False)
        if action in ('read', 'unread'):
            store_flag(c, uids, '\\Seen', action == 'read')
        elif action in ('star', 'unstar'):
            store_flag(c, uids, '\\Flagged', action == 'star')
        elif target:
            move_uids(c, uids, target)
        else:
            delete_uids(c, uids)
    return dict(done=True)


def inbox(a):
    pw, oauth = credentials(a)
    items = []
    with incoming(a, pw, oauth) as c:
        _, entries, _ = c.uidl()
        for entry in reversed(entries[-50:]):
            number, uid = entry.split()
            try:
                _, lines, _ = c.top(int(number), 0)
            except poplib.error_proto:
                raise ValueError('Este servidor POP3 não oferece prévia de mensagens (TOP). Use IMAP.')
            s = summary(b'\r\n'.join(lines), uid.decode())
            s.update(unread=False, starred=False, answered=False, hasAttachment=False, cc='')
            items.append(s)
    return items


def read_message(a, uid, folder_path='INBOX'):
    uid = str(uid)
    pw, oauth = credentials(a)
    with incoming(a, pw, oauth) as c:
        if a['protocol'] == 'imap':
            if not re.fullmatch(r'[1-9][0-9]{0,9}', uid): raise ValueError('Mensagem inválida.')
            folders = list_folders(c)
            select(c, checked_folder(folders, folder_path), readonly=False)
            status, sizes = c.uid('fetch', uid, '(RFC822.SIZE)')
            if status != 'OK': raise ValueError('Mensagem não encontrada.')
            size = re.search(rb'RFC822.SIZE (\d+)', b' '.join(x for x in sizes if isinstance(x, bytes)))
            if not size or int(size[1]) > LIMIT: raise ValueError('Mensagem maior que 20 MB ou indisponível.')
            status, data = c.uid('fetch', uid, '(BODY.PEEK[])')
            if status != 'OK': raise ValueError('Não foi possível ler a mensagem.')
            raw = b''.join(v[1] for v in data if isinstance(v, tuple))
            # Opening a message marks it read, explicitly (the fetch above never does)
            try:
                c.uid('STORE', uid, '+FLAGS.SILENT', '(\\Seen)')
            except imaplib.IMAP4.error:
                pass
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


CALENDAR_LIMIT = 256 * 1024


def calendar_parts(msg):
    """Raw iCalendar parts (invites), at most 3 of up to 256 KB each, duplicates dropped."""
    found = []
    for part in msg.walk():
        if part.is_multipart():
            continue
        ctype = part.get_content_type()
        filename = (part.get_filename() or '').lower()
        if ctype not in ('text/calendar', 'application/ics') and not filename.endswith('.ics'):
            continue
        try:
            payload = part.get_payload(decode=True) or b''
        except Exception:
            continue
        if len(payload) > CALENDAR_LIMIT:
            continue
        text = payload.decode(part.get_content_charset() or 'utf-8', 'replace')
        same = text.replace('\r\n', '\n').strip()
        if 'BEGIN:VCALENDAR' in text.upper() and same not in (x.replace('\r\n', '\n').strip() for x in found):
            found.append(text)
        if len(found) == 3:
            break
    return found


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
    result['hasAttachment'] = bool(result['attachments'])
    result['calendarParts'] = calendar_parts(msg)
    return result


def valid_recipients(value, required):
    if not value.strip():
        return not required
    recipients = getaddresses([value])
    return bool(recipients) and all(re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', addr) for _, addr in recipients)


def check_headers(draft, keys):
    for key in keys:
        value = draft.get(key, '')
        if not isinstance(value, str) or any(ch in value for ch in '\r\n\x00'):
            raise ValueError('Cabeçalho inválido.')


def new_message(a, to, subject, cc=''):
    msg = EmailMessage()
    msg['From'] = formataddr((a.get('name',''),a['email']))
    msg['To'] = to; msg['Subject'] = subject
    if cc.strip():
        msg['Cc'] = cc
    msg['Date'] = email.utils.formatdate(localtime=True); msg['Message-ID'] = email.utils.make_msgid()
    return msg


def build_message(a, draft):
    """The outgoing message; raises ValueError before any network access."""
    check_headers(draft, ('to', 'cc', 'subject', 'inReplyTo', 'references'))
    if not isinstance(draft.get('body', ''), str):
        raise ValueError('Mensagem inválida.')
    if not valid_recipients(draft.get('to', ''), True):
        raise ValueError('Informe destinatários válidos, separados por vírgula.')
    if not valid_recipients(draft.get('cc', ''), False):
        raise ValueError('Informe destinatários em cópia válidos, separados por vírgula.')
    for key in ('inReplyTo', 'references'):
        if draft.get(key) and message_ids(draft[key]) != ' '.join(draft[key].split()):
            raise ValueError('Cabeçalho inválido.')
    msg = new_message(a, draft['to'], draft.get('subject', ''), draft.get('cc', ''))
    if draft.get('inReplyTo'):
        msg['In-Reply-To'] = message_ids(draft['inReplyTo'])
    if draft.get('references'):
        msg['References'] = message_ids(draft['references'])
    msg.set_content(draft.get('body',''))
    return msg


def build_calendar_reply(a, to, subject, ics):
    """A short text plus a text/calendar; method=REPLY part (RFC 6047)."""
    draft = dict(to=to, subject=subject)
    check_headers(draft, ('to', 'subject'))
    if not valid_recipients(to, True):
        raise ValueError('Informe um destinatário válido para a resposta.')
    if (not isinstance(ics, str) or not ics.strip() or '\x00' in ics or len(ics.encode()) > CALENDAR_LIMIT
            or not ics.lstrip().upper().startswith('BEGIN:VCALENDAR')):
        raise ValueError('Convite inválido.')
    if len(subject) > 400:
        raise ValueError('Cabeçalho inválido.')
    msg = new_message(a, to, subject)
    msg.set_content(f'{subject}\n\nResposta enviada pelo Lingmo Mail.\n')
    msg.add_alternative(ics, subtype='calendar', params={'method': 'REPLY'})
    return msg


def deliver(a, msg):
    raw = msg.as_bytes()
    if len(raw) > LIMIT: raise ValueError('Mensagem maior que 20 MB.')
    pw, oauth = credentials(a)
    with outgoing(a, pw, oauth) as c:
        refused = c.send_message(msg)
    return list(refused)


def send(a, draft):
    msg = build_message(a, draft)
    refused = deliver(a, msg)
    try:
        collect_addresses(draft.get('to', '') + ', ' + draft.get('cc', ''), own=a['email'])
    except (OSError, ValueError):
        pass   # the address book is a convenience; the message is already sent
    return {'sent': True, 'refused': refused}


def send_calendar_reply(a, req):
    msg = build_calendar_reply(a, req.get('to', ''), req.get('subject', ''), req.get('ics', ''))
    return {'sent': True, 'refused': deliver(a, msg)}


# ---------- Contacts

def contacts_path():
    return mail_data() / 'contacts.json'


def clean_contact(c):
    if not isinstance(c, dict):
        raise ValueError('Contato inválido.')
    name = single_line(c.get('name', ''), 200, 'Nome')
    emails = c.get('emails', [])
    if isinstance(emails, str):
        emails = [e for e in re.split(r'[,;\s]+', emails) if e]
    if not isinstance(emails, list) or len(emails) > 20:
        raise ValueError('E-mails inválidos.')
    clean = []
    for e in emails:
        e = single_line(e, 254, 'E-mail')
        if not ADDRESS.fullmatch(e):
            raise ValueError(f'E-mail inválido: {e}')
        if e.lower() not in (x.lower() for x in clean):
            clean.append(e)
    phone = single_line(c.get('phone', ''), 40, 'Telefone')
    if phone and not re.fullmatch(r'[0-9+()\-. ]+', phone):
        raise ValueError('Telefone inválido.')
    notes = c.get('notes', '')
    if not isinstance(notes, str) or len(notes) > 5000 or '\x00' in notes:
        raise ValueError('Notas inválidas.')
    if not name and not clean:
        raise ValueError('Informe um nome ou um e-mail.')
    cid = c.get('id') if isinstance(c.get('id'), str) and re.fullmatch(r'[0-9a-f-]{36}', c.get('id', '')) else str(uuid.uuid4())
    return dict(id=cid, name=name, emails=clean, phone=phone, notes=notes, collected=bool(c.get('collected', False)))


def read_contacts():
    items = []
    for c in read_json(contacts_path(), []):
        try:
            items.append(clean_contact(c))
        except ValueError:
            continue
    return sorted(items, key=lambda c: (c['collected'], (c['name'] or c['emails'][0]).casefold()))


def save_contact(contact):
    contact = clean_contact(dict(contact, collected=False))   # edited by the user: a real contact now
    def change(items):
        return [c for c in items if c.get('id') != contact['id']] + [contact]
    update_json(contacts_path(), [], change)
    return read_contacts()


def delete_contact(contact_id):
    if not isinstance(contact_id, str):
        raise ValueError('Contato inválido.')
    update_json(contacts_path(), [], lambda items: [c for c in items if c.get('id') != contact_id])
    return read_contacts()


def collect_addresses(value, own=''):
    """Adds unknown recipients as 'collected' contacts."""
    found = [(n.strip(), addr.strip()) for n, addr in getaddresses([value]) if ADDRESS.fullmatch(addr.strip())]
    found = [(n, addr) for n, addr in found if addr.lower() != own.lower()]
    if not found:
        return
    def change(items):
        known = {e.lower() for c in items if isinstance(c, dict) for e in c.get('emails', []) if isinstance(e, str)}
        collected = sum(1 for c in items if isinstance(c, dict) and c.get('collected'))
        for name, addr in found:
            if addr.lower() in known or collected >= 2000:
                continue
            if any(ch in name for ch in '\r\n\x00') or len(name) > 200:
                name = ''
            items.append(dict(id=str(uuid.uuid4()), name=name, emails=[addr], phone='', notes='', collected=True))
            known.add(addr.lower()); collected += 1
        return items
    update_json(contacts_path(), [], change)


# ---------- Dispatch

def dispatch(req):
    op = req.get('op')
    if op == 'accounts': return read_accounts()
    if op == 'discover': return discover(req['email'])
    if op == 'save': return save(req['account'], req.get('password',''))
    if op == 'google': return google_login()
    if op == 'contacts': return read_contacts()
    if op == 'saveContact': return save_contact(req.get('contact'))
    if op == 'deleteContact': return delete_contact(req.get('contactId'))
    a = account_by_id(req.get('id'))
    if op == 'list': return list_messages(a, req)
    if op == 'check': return check_account(a)
    if op == 'read': return read_message(a, req['message'], req.get('folder') or 'INBOX')
    if op == 'act': return act(a, req)
    if op == 'send': return send(a, req['draft'])
    if op == 'calendarReply': return send_calendar_reply(a, req)
    if op == 'rules': return load_rules(a['id'])
    if op == 'saveRules': return save_rules(a['id'], req.get('rules'))
    if op == 'applyRules': return apply_rules_now(a)
    if op == 'remove':
        secret(a['id'], remove=True)
        accounts = update_accounts(lambda items: [x for x in items if x['id'] != a['id']])
        for path in (rules_path(), state_path()):
            if path.exists():
                update_json(path, {}, lambda data: {k: v for k, v in data.items() if k != a['id']})
        return accounts
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
