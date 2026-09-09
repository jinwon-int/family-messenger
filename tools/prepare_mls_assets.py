#!/usr/bin/env python3
"""Build-only pinned public assets. Never overwrite/remove an existing bundle."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'server/internal/chat/mls_bundle.json'
OUTPUT = ROOT / 'server/internal/chat/mlsassets'

def read(path, maximum, private=False):
    path = Path(path).absolute()
    # No symlinked ancestors, even for caller-selected public bundle input.
    for parent in [*reversed(path.parents), path.parent]:
        if parent.is_symlink() or not parent.is_dir():raise ValueError('unsafe directory')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1 or st.st_size > maximum or st.st_mode & 0o022 or (private and stat.S_IMODE(st.st_mode) != 0o600):raise ValueError('unsafe asset')
        parts=[];size=0
        while size<=maximum:
            part=os.read(fd,min(65536,maximum+1-size))
            if not part:break
            parts.append(part);size+=len(part)
        data=b''.join(parts);after=os.fstat(fd)
        fields=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_mode','st_nlink','st_uid')
        if len(data)!=st.st_size or any(getattr(st,k)!=getattr(after,k) for k in fields):raise ValueError('asset changed')
        return data
    finally:os.close(fd)

def parse_manifest(data):
    def pairs(items):
        out={}
        for key,value in items:
            if key in out:raise ValueError('duplicate manifest key')
            out[key]=value
        return out
    m=json.loads(data,object_pairs_hook=pairs)
    if set(m)!={'version','worker_state','files'} or m['version']!=1 or m['worker_state']!=4 or len(m['files'])!=9:raise ValueError('manifest')
    files=set()
    for entry in m['files']:
        if set(entry)!={'file','url','type','bytes','sha256','source'} or entry['file'] in files or not 0<entry['bytes']<=2*1024*1024:raise ValueError('entry')
        file=entry['file']
        if file not in {'chat.html','chat.css','chat.js','native-worker.js','trust-directory.js','pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt'}:raise ValueError('file')
        files.add(file)
    return m

def prepare(bundle, check=False):
    lock=OUTPUT.parent/'.mls-build.lock'
    fd=os.open(lock,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_nlink!=1 or stat.S_IMODE(st.st_mode)!=0o600:raise ValueError('unsafe build lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest=parse_manifest(read(MANIFEST,8192))
        assets={}
        for e in manifest['files']:
            source=e['source']
            if source.startswith('bundle:'):
                leaf=source[7:]
                if leaf not in ('family_mls_browser_experiment.js','family_mls_browser_experiment_bg.wasm'):raise ValueError('source')
                path=bundle/leaf
            else:
                if source not in ('experiments/openmls-browser/web/'+e['file'],'experiments/openmls-browser/THIRD-PARTY-NOTICES.txt','experiments/openmls-browser/RUST-STDLIB-NOTICES.html'):raise ValueError('source')
                path=ROOT/source
            data=read(path,e['bytes'])
            if len(data)!=e['bytes'] or hashlib.sha256(data).hexdigest()!=e['sha256']:raise ValueError('source hash mismatch')
            assets[e['file']]=data
        if OUTPUT.exists() or OUTPUT.is_symlink():
            st=OUTPUT.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.geteuid() or stat.S_IMODE(st.st_mode)!=0o700:raise ValueError('unsafe output directory')
            if set(os.listdir(OUTPUT))!=set(assets):raise ValueError('unknown or incomplete output retained')
            for name,data in assets.items():
                if read(OUTPUT/name,len(data),True)!=data:raise ValueError('output mismatch retained')
            return
        if check:raise ValueError('missing prepared bundle')
        OUTPUT.mkdir(mode=0o700)
        for name,data in assets.items():
            dest=os.open(OUTPUT/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            try:
                os.fchmod(dest,0o600)
                view=memoryview(data)
                while view:view=view[os.write(dest,view):]
                os.fsync(dest)
            finally:os.close(dest)
        for path in (OUTPUT,OUTPUT.parent):
            d=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:os.fsync(d)
            finally:os.close(d)
    finally:os.close(fd)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--bundle',type=Path,required=True);p.add_argument('--check',action='store_true');a=p.parse_args()
    try:prepare(a.bundle,a.check)
    except (OSError,ValueError,KeyError,TypeError) as e:raise SystemExit('asset preparation rejected; existing files retained: '+str(e))
    print('Pinned synthetic assets verified; no runtime directory dependency.')
