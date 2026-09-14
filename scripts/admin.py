#!/usr/bin/env python3
"""Create a family account using the loopback-only shared-secret API.

Stage-1 Tuwunel homeserver management (decision D) rides on the Synapse-compatible
admin API: subcommands create/deactivate/list-users/list-rooms. The legacy positional
form (``admin.py <username> --admin``) still uses the Synapse shared-secret flow.
"""
import argparse
import getpass
import hashlib
import hmac
import json
import re
import sys
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit, urlencode

from tuwunel_config import (  # noqa: F401  (setting/load_admin_token re-exported for callers and tests)
    ROOT, TUWUNEL_CONFIG, TUWUNEL_TOKEN, load_admin_token, setting,
)
import tuwunel_config

LOCALPART=re.compile(r'[a-z0-9][a-z0-9._=-]{0,63}')


def local_base(root=None):
    root=ROOT if root is None else root
    meta=json.loads((root/'.runtime/installation.json').read_text())
    port=meta['matrix_port']
    if not isinstance(port,int) or not 1<=port<=65535:raise ValueError('Invalid local Matrix port')
    env=dict(line.split('=',1) for line in (root/'.env').read_text().splitlines() if '=' in line and not line.startswith('#'))
    if env.get('MATRIX_PORT')!=str(port):raise ValueError('Matrix port drift; refusing to send credentials')
    if meta['mode']=='preview':
        u=urlsplit(meta['matrix_url'])
        if u.scheme!='http' or u.hostname not in ('127.0.0.1','localhost') or (u.port or 80)!=port:
            raise ValueError('Preview URL/port drift; refusing to send credentials')
    return 'http://127.0.0.1:'+str(port)


def request(path, data=None, token=None, method=None):
    base=local_base()
    headers={}
    if data is not None:headers['Content-Type']='application/json'
    if token:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path, data=json.dumps(data).encode() if data is not None else None,
                               headers=headers, method=method)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req,timeout=20) as response:
        return json.load(response)


def create_user(username,password,admin=False):
    if not re.fullmatch(r'[a-z0-9][a-z0-9._=-]{0,63}',username):raise ValueError('invalid username')
    if len(password)<12:raise ValueError('use a password of at least 12 characters')
    config=json.loads((ROOT/'.runtime/synapse/homeserver.yaml').read_text())
    nonce=request('/_synapse/admin/v1/register')['nonce']
    fields=[nonce,username,password,'admin' if admin else 'notadmin']
    digest=hmac.new(config['registration_shared_secret'].encode(),'\0'.join(fields).encode(),hashlib.sha1).hexdigest()
    return request('/_synapse/admin/v1/register',{'nonce':nonce,'username':username,'password':password,'admin':admin,'mac':digest})


def load_tuwunel_config(path=None):
    """Load the stage-1 homeserver config (tuwunel.toml.example shape) via the shared loader."""
    return tuwunel_config.load_tuwunel_config(path or TUWUNEL_CONFIG)


class AdminClient:
    """Synapse-compatible admin API client as implemented by the Tuwunel homeserver.

    ``send(method, path, body, headers) -> dict`` is injectable for tests; the
    default performs a loopback HTTP JSON request. Errors carry the HTTP code
    and Matrix errcode only; tokens and response bodies never reach messages.
    """

    def __init__(self,base,server_name,token,send=None):
        parts=urlsplit(base)
        if parts.scheme!='http' or parts.hostname not in ('127.0.0.1','localhost','::1'):
            raise ValueError('admin client refuses a non-loopback base URL')
        self.base=base;self.server_name=server_name;self.token=token
        self._send=send or self._http_send

    def _http_send(self,method,path,body,headers):
        req=urllib.request.Request(self.base+path,data=body,headers=headers,method=method)
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req,timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            try:errcode=json.load(e).get('errcode')
            except Exception:errcode=None
            raise RuntimeError('admin API HTTP '+str(e.code)+': '+(errcode or e.reason)) from None

    def _request(self,method,path,data=None):
        body=json.dumps(data).encode() if data is not None else None
        headers={'Authorization':'Bearer '+self.token}
        if body is not None:headers['Content-Type']='application/json'
        return self._send(method,path,body,headers)

    def user_id(self,username):
        if not LOCALPART.fullmatch(username):raise ValueError('invalid username')
        return '@'+username+':'+self.server_name

    def create_user(self,username,password,admin=False,display_name=None):
        """Create an account via PUT /_synapse/admin/v2/users.

        Upstream quirk (measured 2026-09-13): including ``admin: false`` makes
        Tuwunel answer HTTP 500 (M_UNKNOWN, "was never an admin") while still
        creating the user, so the field is only sent when explicitly true.
        """
        if len(password)<12:raise ValueError('use a password of at least 12 characters')
        user=self.user_id(username)
        body={'password':password}
        if display_name:body['displayname']=display_name
        if admin:body['admin']=True
        return self._request('PUT','/_synapse/admin/v2/users/'+quote(user,safe=''),body)

    def deactivate_user(self,user_id):
        return self._request('POST','/_synapse/admin/v1/deactivate/'+quote(user_id,safe=''),{})

    def list_users(self,deactivated=False):
        return self._request('GET','/_synapse/admin/v2/users?'+urlencode({'deactivated':'true' if deactivated else 'false'}))

    def list_rooms(self):
        return self._request('GET','/_synapse/admin/v1/rooms')


def parse(argv):
    """Parse arguments; an unrecognized first token keeps the legacy register form."""
    subcommands=('register','create','deactivate','list-users','list-rooms')
    argv=list(argv)
    if not argv or argv[0] not in subcommands:argv=['register']+argv
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='command',required=True)
    s=sub.add_parser('register',help='Synapse 공유 비밀 기반 계정 발급 (기존 구성)')
    s.add_argument('username');s.add_argument('--admin',action='store_true')
    s=sub.add_parser('create',help='Tuwunel 계정 생성 (Synapse 호환 admin API)')
    s.add_argument('username');s.add_argument('--admin',action='store_true')
    s.add_argument('--display-name')
    s=sub.add_parser('deactivate',help='Tuwunel 계정 비활성화')
    s.add_argument('user_id');s.add_argument('--yes',action='store_true')
    s=sub.add_parser('list-users',help='Tuwunel 계정 목록')
    s.add_argument('--deactivated',action='store_true')
    sub.add_parser('list-rooms',help='Tuwunel 방 목록')
    return p.parse_args(argv)


def run_command(args):
    if args.command=='register':
        password=getpass.getpass('새 비밀번호 (12자 이상): ')
        if password!=getpass.getpass('비밀번호 확인: '):raise ValueError('비밀번호가 일치하지 않습니다')
        result=create_user(args.username,password,args.admin)
        print('Created '+result['user_id']+'; credentials were not logged.')
    elif args.command=='create':
        password=getpass.getpass('새 비밀번호 (12자 이상): ')
        if password!=getpass.getpass('비밀번호 확인: '):raise ValueError('비밀번호가 일치하지 않습니다')
        config=load_tuwunel_config()
        client=AdminClient(config['base'],config['server_name'],load_admin_token())
        result=client.create_user(args.username,password,args.admin,args.display_name)
        # Tuwunel's PUT v2/users answers with `name`; Synapse uses `user_id`.
        created=result.get('name') or result.get('user_id') or client.user_id(args.username)
        print('Created '+created+'; credentials were not logged.')
    elif args.command=='deactivate':
        if not args.yes:raise ValueError('deactivation requires --yes')
        config=load_tuwunel_config()
        client=AdminClient(config['base'],config['server_name'],load_admin_token())
        print(json.dumps(client.deactivate_user(args.user_id)))
    elif args.command=='list-users':
        config=load_tuwunel_config()
        client=AdminClient(config['base'],config['server_name'],load_admin_token())
        print(json.dumps(client.list_users(args.deactivated)))
    elif args.command=='list-rooms':
        config=load_tuwunel_config()
        client=AdminClient(config['base'],config['server_name'],load_admin_token())
        print(json.dumps(client.list_rooms()))


if __name__=='__main__':
    try:
        run_command(parse(sys.argv[1:]))
    except (ValueError,KeyError,OSError,RuntimeError) as e:
        # Messages carry error types only; tokens, passwords and bodies stay out.
        print('failed: '+str(e),file=sys.stderr)
        raise SystemExit(2) from None
