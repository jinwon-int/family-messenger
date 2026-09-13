"""Private configuration and replay state for the bounded Matrix pilot.

Run as a script this module is the operator tool for the permanent
``worker_cleanup_unconfirmed`` block::

    python3 scripts/fleet_matrix_state.py status  --state DIR --account @bot:example
    python3 scripts/fleet_matrix_state.py unblock --state DIR --account @bot:example \\
        --scope <64 hex> --reason "checked runtime pid 1234 exited; result reconciled"

``--config PATH`` (the private pilot config) may replace ``--state``/``--account``.
The tool takes the same process lock as the service, so it refuses while the
service still runs. Every unblock leaves a row in ``operator_audit``.
"""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
from urllib.parse import urlsplit

from fleet_core import Store, Policy, bounded_text, private_directory, MAX_REPLY_BYTES

BLOCK_KEYS = ('worker_cleanup_unconfirmed', 'worker_cleanup_in_progress')
SCOPE_PATTERN = re.compile(r'[0-9a-f]{64}')


class SafetyStop(RuntimeError):
    """Needs operator reconciliation; do not hide gaps or reset cryptographic identity."""


def load_config(path):
    path = Path(path)
    directory = private_directory(path.parent)
    fd = None
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                or st.st_nlink != 1 or stat.S_IMODE(st.st_mode) != 0o600 or st.st_size > 65_536):
            raise SafetyStop('private-config-required')
        data = os.read(fd, 65_537)
        return validate_config(json.loads(data))
    finally:
        if fd is not None: os.close(fd)
        os.close(directory)


def validate_config(c):
    if not isinstance(c, dict): raise SafetyStop('invalid-config')
    required = {'homeserver','account','device_id','access_token','pickle_key','state_directory',
                'owner','rooms','devices','worker_argv','not_before_ms'}
    if required - c.keys(): raise SafetyStop('missing-config-fields')
    if type(c.get('remote_worker',False)) is not bool:raise SafetyStop('invalid-remote-mode')
    url = urlsplit(c['homeserver'])
    if (url.username or url.password or url.query or url.fragment or url.path not in ('','/')
            or not url.hostname or not (url.scheme=='https' or
                (c.get('preview') is True and url.scheme=='http' and url.hostname in ('127.0.0.1','localhost')))):
        raise SafetyStop('invalid-homeserver')
    for key in ['account','owner']:
        if not isinstance(c[key],str) or not re.fullmatch(r'@[a-zA-Z0-9._=-]+:[a-zA-Z0-9.:-]+',c[key]):
            raise SafetyStop('invalid-account')
    if c['account']==c['owner']: raise SafetyStop('distinct-bot-required')
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}',c['device_id']): raise SafetyStop('invalid-device')
    for key in ['access_token','pickle_key']:
        bounded_text(c[key],8192)
    if len(c['pickle_key'])<24: raise SafetyStop('strong-pickle-key-required')
    directory=Path(c['state_directory'])
    if not directory.is_absolute() or '..' in directory.parts: raise SafetyStop('invalid-state-path')
    if not isinstance(c['rooms'],list) or not 1<=len(c['rooms'])<=12: raise SafetyStop('invalid-room-list')
    Policy(c['account'],frozenset([c['owner']]),frozenset([c['account']]),
           {r:'direct' for r in c['rooms']},c['not_before_ms'])
    if not isinstance(c['devices'],dict) or not 1<=len(c['devices'])<=10: raise SafetyStop('pin-owner-devices')
    for device,keys in c['devices'].items():
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}',device) or not isinstance(keys,dict): raise SafetyStop('invalid-device-pin')
        for kind in ['ed25519','curve25519']:
            if not isinstance(keys.get(kind),str) or not re.fullmatch(r'[A-Za-z0-9+/]{43}',keys[kind]):
                raise SafetyStop('invalid-key-pin')
    argv=c['worker_argv']
    if (not isinstance(argv,list) or not 1<=len(argv)<=20 or not all(isinstance(v,str) and v and '\x00' not in v for v in argv)
            or not Path(argv[0]).is_absolute()): raise SafetyStop('invalid-worker-command')
    return c


def turn_id(event_id):
    return hashlib.sha256(event_id.encode()).hexdigest()[:32]


def parts(text, limit=12_000):
    result=[]; current=[]; size=0
    for char in text:
        n=len(char.encode())
        if size+n>limit:
            result.append(''.join(current));current=[];size=0
        current.append(char);size+=n
    if current:result.append(''.join(current))
    return result


class MatrixStore(Store):
    def __init__(self, directory, account):
        super().__init__(directory,account)
        try:
            self.db.executescript('''
                CREATE TABLE IF NOT EXISTS deliveries(event_id TEXT PRIMARY KEY, part INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS controls(event_id TEXT PRIMARY KEY, digest TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS operator_audit(seq INTEGER PRIMARY KEY, at REAL NOT NULL,
                    actor TEXT NOT NULL, action TEXT NOT NULL, scope TEXT NOT NULL,
                    reason TEXT NOT NULL, before TEXT NOT NULL);
            ''')
        except BaseException:
            self.close()
            raise

    def block(self):
        """Describe the permanent SafetyStop block without message bodies, or return None."""
        flags={key:self.get_meta(key) for key in BLOCK_KEYS}
        if not any(flags.values()):return None
        unconfirmed=flags['worker_cleanup_unconfirmed']
        recorded=unconfirmed.get('scope') if isinstance(unconfirmed,dict) else None
        uncertain=sorted({row['scope'] for row in self.uncertain()})
        # Before the scope was recorded, the block could only be attributed through uncertain jobs.
        scopes=[recorded] if isinstance(recorded,str) else uncertain
        return {**flags,'blocked_scopes':scopes,'uncertain_scopes':uncertain}

    def unblock(self,scope,reason,actor):
        """Operator decision: clear the block attributed to one scope and audit who/when/why."""
        if not isinstance(scope,str) or not SCOPE_PATTERN.fullmatch(scope):raise ValueError('invalid-scope')
        bounded_text(reason,1024);bounded_text(actor,255)
        before=self.block()
        if before is None:raise ValueError('no-block')
        if scope not in before['blocked_scopes']:raise ValueError('scope-not-blocked')
        at=time.time()
        with self.db:
            self.db.execute("UPDATE meta SET value='null' WHERE key='worker_cleanup_unconfirmed'")
            self.db.execute("UPDATE meta SET value='false' WHERE key='worker_cleanup_in_progress'")
            seq=self.db.execute('INSERT INTO operator_audit(at,actor,action,scope,reason,before) VALUES (?,?,?,?,?,?)',
                (at,actor,'unblock',scope,reason,json.dumps(before))).lastrowid
        return {'cleared':[key for key in BLOCK_KEYS if before[key]],'scope':scope,'actor':actor,'at':at,
                'audit_seq':seq,'before':before}

    def audit(self):
        return [dict(row) for row in self.db.execute('SELECT * FROM operator_audit ORDER BY seq')]

    def get_meta(self,key):
        row=self.db.execute('SELECT value FROM meta WHERE key=?',(key,)).fetchone()
        return json.loads(row[0]) if row else None

    def storage_gate(self):
        fs=os.fstatvfs(self.directory_fd)
        size=os.stat('inbox.sqlite3',dir_fd=self.directory_fd,follow_symlinks=False).st_size
        if fs.f_bavail*fs.f_frsize < 268_435_456 or size > 134_217_728:
            raise SafetyStop('pilot-storage-limit')

    def set_meta(self,key,value):
        with self.db:self.db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)',(key,json.dumps(value)))

    def stage_sync(self,raw):
        if self.get_meta('pending_sync') is not None: raise SafetyStop('pending-sync-not-finished')
        if not isinstance(raw,dict):raise SafetyStop('invalid-sync')
        bounded_text(raw.get('next_batch'),4096)
        if len(json.dumps(raw).encode())>4_194_304:raise SafetyStop('sync-too-large')
        self.set_meta('pending_sync',raw)

    def commit_sync(self,token):
        pending=self.get_meta('pending_sync')
        if not pending or pending.get('next_batch')!=token:raise SafetyStop('sync-identity-mismatch')
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES ('sync_token',?)",(token,))
            self.db.execute("UPDATE meta SET value='null' WHERE key='pending_sync'")

    def seen_control(self,req, *, record=True):
        digest=hashlib.sha256(json.dumps([req.room_id,req.sender,req.body]).encode()).hexdigest()
        with self.db:
            row=self.db.execute('SELECT digest FROM controls WHERE event_id=?',(req.event_id,)).fetchone()
            if row:
                if row[0]!=digest:raise SafetyStop('control-identity-conflict')
                return True
            if record:self.db.execute('INSERT INTO controls VALUES (?,?)',(req.event_id,digest))
        return False

    def notice(self,req,key,text):
        bounded_text(text,MAX_REPLY_BYTES)
        event='$notice-'+hashlib.sha256(json.dumps([req.event_id,key]).encode()).hexdigest()
        txn=hashlib.sha256(json.dumps([self.account,event,'reply-v1']).encode()).hexdigest()
        digest=hashlib.sha256(text.encode()).hexdigest()
        with self.db:
            old=self.db.execute('SELECT digest FROM jobs WHERE event_id=?',(event,)).fetchone()
            if old:
                if old[0]!=digest:raise SafetyStop('notice-identity-conflict')
                return
            self.db.execute("INSERT INTO jobs(event_id,room_id,sender,scope,body,digest,state,reply,txn_id) "
                "VALUES (?,?,?,?,?,?,'ready',?,?)",(event,req.room_id,req.sender,req.scope,'notice',digest,text,txn))

    def delivered_parts(self,event):
        row=self.db.execute('SELECT part FROM deliveries WHERE event_id=?',(event,)).fetchone()
        return row[0] if row else 0

    def mark_part(self,event,part):
        with self.db:self.db.execute('INSERT OR REPLACE INTO deliveries VALUES (?,?)',(event,part))

    def uncertain_job(self,event):
        with self.db:self.db.execute("UPDATE jobs SET state='uncertain' WHERE event_id=? AND state='running'",(event,))


def operator_name(environ=None):
    environ=os.environ if environ is None else environ
    try:name=environ.get('SUDO_USER') or getpass.getuser()
    except (KeyError,OSError):name='uid'+str(os.getuid())
    return name+'#'+str(os.getuid())


def parse_args(argv):
    parser=argparse.ArgumentParser(description='Inspect or clear the pilot SafetyStop block (exit 78).')
    sub=parser.add_subparsers(dest='command',required=True)
    for name in ('status','unblock'):
        p=sub.add_parser(name)
        p.add_argument('--config',help='private pilot config; supplies --state and --account')
        p.add_argument('--state',help='state_directory (or its inbox.sqlite3)')
        p.add_argument('--account',help='bot account, e.g. @agent:example')
        if name=='unblock':
            p.add_argument('--scope',required=True,help='64-hex scope shown by status')
            p.add_argument('--reason',required=True,help='what was verified before clearing')
    args=parser.parse_args(argv)
    if args.config:
        c=load_config(args.config)
        args.state=args.state or c['state_directory'];args.account=args.account or c['account']
    if not args.state or not args.account:parser.error('--config or both --state and --account are required')
    state=Path(args.state)
    args.state=state.parent if state.name=='inbox.sqlite3' else state
    return args


def main(argv=None,out=None,err=None):
    out=sys.stdout if out is None else out;err=sys.stderr if err is None else err
    try:args=parse_args(argv)
    except SafetyStop as exc:
        print('refused: '+str(exc),file=err);return 2
    try:store=MatrixStore(args.state,args.account)
    except BlockingIOError:
        print('refused: state is locked by a running fleet_matrix.py process; stop the service first',file=err);return 2
    except (OSError,ValueError) as exc:
        print('refused: '+type(exc).__name__+': '+str(exc),file=err);return 2
    with store:
        if args.command=='status':
            print(json.dumps({'account':args.account,'block':store.block()},indent=1,sort_keys=True),file=out);return 0
        try:result=store.unblock(args.scope,args.reason,operator_name())
        except ValueError as exc:
            print('refused: '+str(exc)+'; run status to see blocked_scopes',file=err);return 2
        print(json.dumps({'account':args.account,'unblocked':result},indent=1,sort_keys=True),file=out)
    return 0


if __name__=='__main__':
    os.umask(0o077)
    sys.exit(main())
