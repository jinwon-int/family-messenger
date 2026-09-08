#!/usr/bin/env python3
"""Create a family account using the loopback-only shared-secret API."""
import argparse
import getpass
import hashlib
import hmac
import json
from pathlib import Path
import re
import urllib.request

ROOT=Path(__file__).resolve().parents[1]


def request(path, data=None, token=None, method=None, base='http://127.0.0.1:18809'):
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


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('username');p.add_argument('--admin',action='store_true');a=p.parse_args()
    password=getpass.getpass('새 비밀번호 (12자 이상): ')
    if password!=getpass.getpass('비밀번호 확인: '):p.exit(2,'Passwords do not match\n')
    result=create_user(a.username,password,a.admin)
    print('Created '+result['user_id']+'; credentials were not logged.')
