#!/usr/bin/env python3
"""Generate a new installation; never overwrite existing identity or secrets."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def validated_urls(server, web, matrix, preview):
    if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', server):
        raise ValueError('server-name must be a DNS name without scheme, port or path')
    parsed = [urlsplit(x) for x in (web, matrix)]
    for u in parsed:
        if not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('', '/'):
            raise ValueError('URLs must be origin URLs without credentials or paths')
        if preview:
            if u.scheme != 'http' or u.hostname not in ('localhost', '127.0.0.1'):
                raise ValueError('preview URLs must be HTTP loopback origins')
        elif u.scheme != 'https' or u.hostname in ('localhost', '127.0.0.1'):
            raise ValueError('production requires HTTPS public hostnames')
    if not preview and parsed[0].hostname == parsed[1].hostname:
        raise ValueError('Element and Matrix API require separate hostnames')
    if preview and server != 'preview.invalid':
        raise ValueError('preview server-name must be preview.invalid')
    ports=[u.port or (80 if u.scheme=='http' else 443) for u in parsed]
    if preview and ports[0]==ports[1]:
        raise ValueError('preview web and Matrix need different ports')
    return web.rstrip('/'), matrix.rstrip('/')


def configs(server, web, matrix, password, registration_secret):
    homeserver = {
        'server_name': server, 'public_baseurl': matrix+'/', 'pid_file': '/data/homeserver.pid',
        'report_stats': False,
        'listeners': [{'port': 8008, 'type': 'http', 'tls': False, 'bind_addresses': ['0.0.0.0'],
                       'x_forwarded': True, 'resources': [{'names': ['client'], 'compress': False}]}],
        'database': {'name': 'psycopg2', 'args': {'user': 'synapse', 'password': password,
                    'database': 'synapse', 'host': 'postgres', 'cp_min': 2, 'cp_max': 5}},
        'log_config': '/data/log.config', 'media_store_path': '/data/media_store',
        'signing_key_path': '/data/server.signing.key', 'registration_shared_secret': registration_secret,
        'macaroon_secret_key': secrets.token_hex(32), 'form_secret': secrets.token_hex(32),
        'enable_registration': False, 'allow_guest_access': False,
        'federation_domain_whitelist': [], 'trusted_key_servers': [],
        'allow_public_rooms_without_auth': False, 'allow_public_rooms_over_federation': False,
        'encryption_enabled_by_default_for_room_type': 'all',
        'enable_search': False, 'url_preview_enabled': False, 'max_upload_size': '50M',
        'suppress_key_server_warning': True,
    }
    element = {
        'brand': '서윤 가족 메신저',
        'default_server_config': {'m.homeserver': {'base_url': matrix, 'server_name': server}},
        'disable_custom_urls': True, 'disable_guests': True, 'disable_3pid_login': True,
        'default_country_code': 'KR', 'default_language': 'ko', 'default_theme': 'light',
        'default_federate': False, 'room_directory': {'servers': [server]},
        'integrations_ui_url': '', 'integrations_rest_url': '', 'integrations_widgets_urls': [],
        'element_call': {'disable': True}, 'map_style_url': '', 'mobile_guide_toast': False,
        'permalink_prefix': web, 'show_labs_settings': False,
        'branding': {'auth_header_logo_url': web+'/family/logo.svg', 'logo_link_url': web,
                     'auth_footer_links': [{'text': '가족 이용 안내', 'url': web+'/family/help.html'}]},
        'embedded_pages': {'welcome_url': web+'/family/welcome.html'},
    }
    return homeserver, element


def write_new(path, content, mode=0o600):
    with os.fdopen(os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, mode), 'w') as f:
        os.fchmod(f.fileno(),mode)
        f.write(content)
        f.flush()
        os.fsync(f.fileno())


def initialize(root, server, web, matrix, preview):
    if root.is_symlink():
        raise ValueError('symlinked installation directory')
    fd=os.open(root/'.init.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        return _initialize(root,server,web,matrix,preview)


def _initialize(root, server, web, matrix, preview):
    web, matrix = validated_urls(server, web, matrix, preview)
    if root.is_symlink() or any((root/n).exists() or (root/n).is_symlink() for n in ('.runtime', '.env')):
        raise ValueError('existing runtime/env: refusing to overwrite identity or secrets')
    uid = os.getuid() or 991
    gid = os.getgid() if os.getuid() else 991
    # A private staging directory remains available for diagnosis if generation fails.
    staging = Path(tempfile.mkdtemp(prefix='.runtime-stage-', dir=root))
    syn = staging/'synapse'; syn.mkdir(mode=0o700)
    password = secrets.token_hex(32)
    web_port=(urlsplit(web).port or 80) if preview else 18808
    matrix_port=(urlsplit(matrix).port or 80) if preview else 18809
    homeserver, element = configs(server, web, matrix, password, secrets.token_hex(32))
    write_new(syn/'homeserver.yaml', json.dumps(homeserver, ensure_ascii=False, indent=2))
    write_new(syn/'log.config', json.dumps({'version':1, 'formatters':{'brief':{'format':'%(asctime)s %(name)s %(levelname)s %(message)s'}},
              'handlers':{'console':{'class':'logging.StreamHandler','formatter':'brief'}},
              'root':{'level':'WARNING','handlers':['console']},
              'loggers':{'synapse.access':{'level':'WARNING'}}}, indent=2))
    write_new(staging/'postgres.env', 'POSTGRES_PASSWORD='+password+'\n')
    write_new(staging/'element.json', json.dumps(element, ensure_ascii=False, indent=2), 0o644)
    write_new(staging/'installation.json', json.dumps({'mode':'preview' if preview else 'production',
              'server_name':server,'web_url':web,'matrix_url':matrix,
              'web_port':web_port,'matrix_port':matrix_port}, indent=2))
    if os.getuid() == 0:
        for path in [*syn.iterdir(), syn]: os.chown(path, uid, gid)
    os.rename(staging, root/'.runtime')
    write_new(root/'.env', f'COMPOSE_PROJECT_NAME=family-messenger{"-preview" if preview else ""}\nSYNAPSE_UID={uid}\nSYNAPSE_GID={gid}\nWEB_PORT={web_port}\nMATRIX_PORT={matrix_port}\n')
    print('Initialized a new '+('loopback preview' if preview else 'production configuration')+'. No credentials printed.')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--preview', action='store_true')
    p.add_argument('--server-name')
    p.add_argument('--web-url')
    p.add_argument('--matrix-url')
    a=p.parse_args()
    if a.preview:
        server=a.server_name or 'preview.invalid';web=a.web_url or 'http://127.0.0.1:18808';matrix=a.matrix_url or 'http://127.0.0.1:18809'
    else:
        if not all((a.server_name,a.web_url,a.matrix_url)):p.error('production needs --server-name, --web-url and --matrix-url')
        server,web,matrix=a.server_name,a.web_url,a.matrix_url
    try: initialize(ROOT,server,web,matrix,a.preview)
    except ValueError as e:p.exit(2,str(e)+'\n')
