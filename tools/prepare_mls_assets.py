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

def check_parent_chain(path):
    # Validate before any open, including creation of the build lock.
    for parent in reversed(Path(path).absolute().parents):
        if parent.is_symlink() or not parent.is_dir():raise ValueError('unsafe directory')

def read(path, maximum, private=False):
    path = Path(path).absolute()
    check_parent_chain(path)
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

BASE_SOURCES = {
    **{name: 'experiments/openmls-browser/web/' + name for name in ('chat.html','chat.css','chat.js','native-worker.js','trust-directory.js')},
    'pkg.js': 'bundle:family_mls_browser_experiment.js',
    'pkg.wasm': 'bundle:family_mls_browser_experiment_bg.wasm',
    'cargo-notices.txt': 'experiments/openmls-browser/THIRD-PARTY-NOTICES.txt',
    'rust-notices.txt': 'experiments/openmls-browser/RUST-STDLIB-NOTICES.html',
}
VAULT_SOURCES = {
    **BASE_SOURCES,
    **{name: 'experiments/openmls-browser/web/' + name for name in ('vault-chat.html','vault-chat.js','vault-native-worker.js')},
    'native-vault-store.js': 'experiments/device-keystore/bundle/native-vault-store.js',
    'age-notices.txt': 'experiments/device-keystore/THIRD-PARTY-NOTICES.txt',
    'sodium-notices.txt': 'experiments/device-keystore/SODIUM-NOTICES.txt',
}

HISTORY_SOURCES = {
    **VAULT_SOURCES,
    **{name: 'experiments/device-keystore/' + name for name in ('history.html','history.css','history-ui.js','history-client.js')},
    **{name: 'experiments/device-keystore/bundle/' + name for name in ('history-worker.js','history-export-worker.js')},
}

ASSET_URLS = {name: '/'+name for name in HISTORY_SOURCES}
ASSET_URLS.update({'chat.html':'/encrypted/','vault-chat.html':'/vault/','history.html':'/history/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    'cargo-notices.txt':'/encrypted/licenses/cargo.txt','rust-notices.txt':'/encrypted/licenses/rust.txt',
    'age-notices.txt':'/vault/licenses/age.txt','sodium-notices.txt':'/vault/licenses/sodium.txt'})

def parse_manifest(data, vault=False, history=False):
    if vault and history:raise ValueError('select only one asset profile')
    def pairs(items):
        out={}
        for key,value in items:
            if key in out:raise ValueError('duplicate manifest key')
            out[key]=value
        return out
    m=json.loads(data,object_pairs_hook=pairs)
    sources=HISTORY_SOURCES if history else VAULT_SOURCES if vault else BASE_SOURCES
    if set(m)!={'version','worker_state','files'} or type(m['version']) is not int or m['version']!=(3 if history else 2 if vault else 1) or type(m['worker_state']) is not int or m['worker_state']!=4 or len(m['files'])!=len(sources):raise ValueError('manifest')
    files=set()
    for entry in m['files']:
        if set(entry)!={'file','url','type','bytes','sha256','source'} or entry['file'] in files or type(entry['bytes']) is not int or not 0<entry['bytes']<=2*1024*1024:raise ValueError('entry')
        file=entry['file']
        if file not in sources or entry['source']!=sources[file]:raise ValueError('file or source')
        kind = 'application/wasm' if file=='pkg.wasm' else 'text/html; charset=utf-8' if file.endswith('.html') else 'text/css; charset=utf-8' if file.endswith('.css') else 'text/plain; charset=utf-8' if file.endswith('.txt') else 'text/javascript; charset=utf-8'
        if entry['url']!=ASSET_URLS[file] or entry['type']!=kind or not isinstance(entry['sha256'],str) or len(entry['sha256'])!=64 or any(c not in '0123456789abcdef' for c in entry['sha256']):raise ValueError('route, type or hash')
        files.add(file)
    if sum(e['bytes'] for e in m['files'])>4*1024*1024:raise ValueError('bundle size')
    # Match Go's struct field order, not the input object's insertion order.
    canonical={'version':m['version'],'worker_state':m['worker_state'],'files':[{key:e[key] for key in ('file','url','type','bytes','sha256','source')} for e in m['files']]}
    if (json.dumps(canonical,indent=2)+'\n').encode()!=data:raise ValueError('noncanonical manifest')
    return m

def prepare(bundle, check=False, vault=False, history=False):
    if vault and history:raise ValueError('select only one asset profile')
    output=ROOT/'server/internal/chat/historyassets' if history else ROOT/'server/internal/chat/vaultassets' if vault else OUTPUT
    manifest_path=ROOT/'server/internal/chat/history_bundle.json' if history else ROOT/'server/internal/chat/vault_bundle.json' if vault else MANIFEST
    lock=output.parent/'.mls-build.lock'
    check_parent_chain(lock)
    fd=os.open(lock,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_nlink!=1 or stat.S_IMODE(st.st_mode)!=0o600:raise ValueError('unsafe build lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest=parse_manifest(read(manifest_path,8192),vault,history)
        assets={}
        for e in manifest['files']:
            source=e['source']
            if source.startswith('bundle:'):
                leaf=source[7:]
                if leaf not in ('family_mls_browser_experiment.js','family_mls_browser_experiment_bg.wasm'):raise ValueError('source')
                path=bundle/leaf
            else:
                path=ROOT/source
            data=read(path,e['bytes'])
            if len(data)!=e['bytes'] or hashlib.sha256(data).hexdigest()!=e['sha256']:raise ValueError('source hash mismatch')
            assets[e['file']]=data
        if output.exists() or output.is_symlink():
            st=output.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.geteuid() or stat.S_IMODE(st.st_mode)!=0o700:raise ValueError('unsafe output directory')
            if set(os.listdir(output))!=set(assets):raise ValueError('unknown or incomplete output retained')
            for name,data in assets.items():
                if read(output/name,len(data),True)!=data:raise ValueError('output mismatch retained')
            return
        if check:raise ValueError('missing prepared bundle')
        output.mkdir(mode=0o700)
        for name,data in assets.items():
            dest=os.open(output/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            try:
                os.fchmod(dest,0o600)
                view=memoryview(data)
                while view:view=view[os.write(dest,view):]
                os.fsync(dest)
            finally:os.close(dest)
        for path in (output,output.parent):
            d=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:os.fsync(d)
            finally:os.close(d)
    finally:os.close(fd)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--bundle',type=Path,required=True);p.add_argument('--check',action='store_true');mode=p.add_mutually_exclusive_group();mode.add_argument('--vault',action='store_true');mode.add_argument('--history',action='store_true');a=p.parse_args()
    try:prepare(a.bundle,a.check,a.vault,a.history)
    except (OSError,ValueError,KeyError,TypeError) as e:raise SystemExit('asset preparation rejected; existing files retained: '+str(e))
    print('Pinned synthetic assets verified; no runtime directory dependency.')
