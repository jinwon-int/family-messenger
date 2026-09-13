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

# Independent aggregate entry: deliberately does not include older UI modules.
AGGREGATE_SOURCES = {
    **{name: 'experiments/openmls-browser/web/' + name for name in ('aggregate-chat.html','aggregate-chat.js','chat.css','native-worker.js','trust-directory.js','aggregate-native-worker.js','prepared-fork-worker.js')},
    **{name: BASE_SOURCES[name] for name in ('pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt')},
    'aggregate-store.js': 'experiments/device-keystore/bundle/aggregate-store.js',
    **{name: VAULT_SOURCES[name] for name in ('age-notices.txt','sodium-notices.txt')},
}
AGGREGATE_URLS = {name:'/'+name for name in AGGREGATE_SOURCES}
AGGREGATE_URLS.update({'aggregate-chat.html':'/aggregate/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    **{name+'-notices.txt':'/aggregate/licenses/'+name+'.txt' for name in ('cargo','rust','age','sodium')}})

AGGREGATE_HISTORY_SOURCES = {
    **AGGREGATE_SOURCES,
    **{name: 'experiments/device-keystore/' + name for name in ('aggregate-history.html','aggregate-history.css','aggregate-history-ui.js','aggregate-history-client.js')},
    **{name: 'experiments/device-keystore/bundle/' + name for name in ('aggregate-history-worker.js','aggregate-history-export-worker.js')},
}
AGGREGATE_HISTORY_URLS = {**AGGREGATE_URLS, **{name:'/'+name for name in AGGREGATE_HISTORY_SOURCES if name not in AGGREGATE_SOURCES}}
AGGREGATE_HISTORY_URLS['aggregate-history.html']='/aggregate-history/'

ASSET_URLS = {name: '/'+name for name in HISTORY_SOURCES}
ASSET_URLS.update({'chat.html':'/encrypted/','vault-chat.html':'/vault/','history.html':'/history/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    'cargo-notices.txt':'/encrypted/licenses/cargo.txt','rust-notices.txt':'/encrypted/licenses/rust.txt',
    'age-notices.txt':'/vault/licenses/age.txt','sodium-notices.txt':'/vault/licenses/sodium.txt'})

# Standalone successor lifecycle, with no legacy/test worker entrypoints.
SUCCESSOR_SOURCES = {
    **{name: 'experiments/openmls-browser/web/' + name for name in (
        'successor.html','successor-ui.js','successor-ui.css','successor-handoff.html','successor-handoff.js','successor-handoff-ui.js',
        'successor-lifecycle-worker.js','candidate-lifecycle-worker.js','peer-lifecycle-worker.js',
        'trust-directory.js','custody-declaration.js','handshake-wire.js','confirmation-wire.js','lease-wire.js','enrollment-wire.js','closure-wire.js')},
    **{name: BASE_SOURCES[name] for name in ('pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt')},
    'successor-closure-store.js': 'experiments/device-keystore/bundle/successor-closure-store.js',
    **{name: VAULT_SOURCES[name] for name in ('age-notices.txt','sodium-notices.txt')},
}
SUCCESSOR_URLS = {name:'/'+name for name in SUCCESSOR_SOURCES}
SUCCESSOR_URLS.update({'successor.html':'/successor/','successor-handoff.html':'/successor-handoff/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    **{name+'-notices.txt':'/successor/licenses/'+name+'.txt' for name in ('cargo','rust','age','sodium')}})

# Candidate proposal/bind only; independent from the lifecycle bundle.
CANDIDATE_SOURCES = {
    **{name: 'experiments/openmls-browser/web/' + name for name in (
        'candidate-preparation.html','candidate-preparation.css','candidate-preparation-ui.js','candidate-preparation-client.js','candidate-attempts.js',
        'successor-handoff.js','candidate-worker.js','trust-directory.js')},
    **{name: BASE_SOURCES[name] for name in ('pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt')},
    'candidate-store.js': 'experiments/device-keystore/bundle/candidate-store.js',
    **{name: VAULT_SOURCES[name] for name in ('age-notices.txt','sodium-notices.txt')},
}
CANDIDATE_URLS = {name:'/'+name for name in CANDIDATE_SOURCES}
CANDIDATE_URLS.update({'candidate-preparation.html':'/candidate-preparation/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    **{name+'-notices.txt':'/candidate-preparation/licenses/'+name+'.txt' for name in ('cargo','rust','age','sodium')}})

# Intact-peer preparation only; independent from all prior bundles.
PEER_SOURCES = {
    **{name: 'experiments/openmls-browser/web/' + name for name in (
        'peer-preparation.html','peer-preparation.css','peer-preparation-ui.js','peer-preparation-client.js',
        'successor-handoff.js','successor-peer-worker.js','trust-directory.js')},
    **{name: BASE_SOURCES[name] for name in ('pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt')},
    'successor-peer-store.js': 'experiments/device-keystore/bundle/successor-peer-store.js',
    **{name: VAULT_SOURCES[name] for name in ('age-notices.txt','sodium-notices.txt')},
}
PEER_URLS = {name:'/'+name for name in PEER_SOURCES}
PEER_URLS.update({'peer-preparation.html':'/peer-preparation/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    **{name+'-notices.txt':'/peer-preparation/licenses/'+name+'.txt' for name in ('cargo','rust','age','sodium')}})

# Native preparation/declaration caller, preserving all previous profile pins.
CUSTODY_SOURCES = {
    **{name:'experiments/openmls-browser/web/'+name for name in (
        'custody-ceremony.html','custody-ceremony.css','custody-ceremony-ui.js','custody-ceremony-client.js',
        'candidate-preparation-client.js','peer-preparation-client.js','successor-handoff.js','trust-directory.js',
        'candidate-worker.js','successor-peer-worker.js','candidate-custody-worker.js','peer-custody-worker.js','custody-worker.js','custody-declaration.js')},
    **{name:BASE_SOURCES[name] for name in ('pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt')},
    **{name:'experiments/device-keystore/bundle/'+name for name in ('candidate-store.js','successor-peer-store.js')},
    **{name:VAULT_SOURCES[name] for name in ('age-notices.txt','sodium-notices.txt')},
}
CUSTODY_URLS={name:'/'+name for name in CUSTODY_SOURCES}
CUSTODY_URLS.update({'custody-ceremony.html':'/custody-ceremony/',
    'pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',
    **{name+'-notices.txt':'/custody-ceremony/licenses/'+name+'.txt' for name in ('cargo','rust','age','sodium')}})

WELCOME_SOURCES={**CUSTODY_SOURCES,**{n:'experiments/openmls-browser/web/'+n for n in ('welcome-ceremony.html','welcome-ceremony.css','welcome-ceremony-ui.js','welcome-ceremony-client.js','candidate-exchange-worker.js','peer-exchange-worker.js','exchange-worker.js','handshake-wire.js')},'successor-exchange-store.js':'experiments/device-keystore/bundle/successor-exchange-store.js'}
WELCOME_URLS={**CUSTODY_URLS,**{n:'/'+n for n in WELCOME_SOURCES if n not in CUSTODY_SOURCES},'welcome-ceremony.html':'/welcome-ceremony/'}

# Separate confirmation-only graph. Preceding profile11 remains byte-pinned.
CONFIRMATION_SOURCES={**{n:'experiments/openmls-browser/web/'+n for n in ('confirmation-ceremony.html','confirmation-ceremony.css','confirmation-ceremony-ui.js','confirmation-ceremony-client.js','custody-ceremony-client.js','candidate-preparation-client.js','peer-preparation-client.js','successor-handoff.js','trust-directory.js','custody-declaration.js','handshake-wire.js','confirmation-wire.js','confirmation-worker.js','candidate-confirmation-worker.js','peer-confirmation-worker.js')},**{n:WELCOME_SOURCES[n] for n in ('pkg.js','pkg.wasm','cargo-notices.txt','rust-notices.txt','age-notices.txt','sodium-notices.txt')},'successor-confirmation-store.js':'experiments/device-keystore/bundle/successor-confirmation-store.js'}
CONFIRMATION_URLS={n:'/'+n for n in CONFIRMATION_SOURCES}
CONFIRMATION_URLS.update({'confirmation-ceremony.html':'/confirmation-ceremony/','pkg.js':'/pkg/family_mls_browser_experiment.js','pkg.wasm':'/pkg/family_mls_browser_experiment_bg.wasm',**{n+'-notices.txt':'/confirmation-ceremony/licenses/'+n+'.txt' for n in ('cargo','rust','age','sodium')}})

def parse_manifest(data, vault=False, history=False, aggregate=False, aggregate_history=False, successor=False, candidate=False, peer=False, custody=False, welcome=False, confirmation=False):
    if sum((vault,history,aggregate,aggregate_history,successor,candidate,peer,custody,welcome,confirmation))>1:raise ValueError('select only one asset profile')
    if len(data)>(12288 if welcome else 8192):raise ValueError('manifest size')
    def pairs(items):
        out={}
        for key,value in items:
            if key in out:raise ValueError('duplicate manifest key')
            out[key]=value
        return out
    m=json.loads(data,object_pairs_hook=pairs)
    sources=CONFIRMATION_SOURCES if confirmation else WELCOME_SOURCES if welcome else CUSTODY_SOURCES if custody else PEER_SOURCES if peer else CANDIDATE_SOURCES if candidate else SUCCESSOR_SOURCES if successor else AGGREGATE_HISTORY_SOURCES if aggregate_history else AGGREGATE_SOURCES if aggregate else HISTORY_SOURCES if history else VAULT_SOURCES if vault else BASE_SOURCES
    if set(m)!={'version','worker_state','files'} or type(m['version']) is not int or m['version']!=(12 if confirmation else 11 if welcome else 10 if custody else 9 if peer else 8 if candidate else 7 if successor else 6 if aggregate_history else 4 if aggregate else 5 if history else 2 if vault else 1) or type(m['worker_state']) is not int or m['worker_state']!=4 or len(m['files'])!=len(sources):raise ValueError('manifest')
    files=set()
    for entry in m['files']:
        if set(entry)!={'file','url','type','bytes','sha256','source'} or entry['file'] in files or type(entry['bytes']) is not int or not 0<entry['bytes']<=2*1024*1024:raise ValueError('entry')
        file=entry['file']
        if file not in sources or entry['source']!=sources[file]:raise ValueError('file or source')
        kind = 'application/wasm' if file=='pkg.wasm' else 'text/html; charset=utf-8' if file.endswith('.html') else 'text/css; charset=utf-8' if file.endswith('.css') else 'text/plain; charset=utf-8' if file.endswith('.txt') else 'text/javascript; charset=utf-8'
        if entry['url']!=(CONFIRMATION_URLS if confirmation else WELCOME_URLS if welcome else CUSTODY_URLS if custody else PEER_URLS if peer else CANDIDATE_URLS if candidate else SUCCESSOR_URLS if successor else AGGREGATE_HISTORY_URLS if aggregate_history else AGGREGATE_URLS if aggregate else ASSET_URLS)[file] or entry['type']!=kind or not isinstance(entry['sha256'],str) or len(entry['sha256'])!=64 or any(c not in '0123456789abcdef' for c in entry['sha256']):raise ValueError('route, type or hash')
        files.add(file)
    if sum(e['bytes'] for e in m['files'])>4*1024*1024:raise ValueError('bundle size')
    # Match Go's struct field order, not the input object's insertion order.
    canonical={'version':m['version'],'worker_state':m['worker_state'],'files':[{key:e[key] for key in ('file','url','type','bytes','sha256','source')} for e in m['files']]}
    if (json.dumps(canonical,indent=2)+'\n').encode()!=data:raise ValueError('noncanonical manifest')
    return m

def prepare(bundle, check=False, vault=False, history=False, aggregate=False, aggregate_history=False, successor=False, candidate=False, peer=False, custody=False, welcome=False, confirmation=False):
    if sum((vault,history,aggregate,aggregate_history,successor,candidate,peer,custody,welcome,confirmation))>1:raise ValueError('select only one asset profile')
    output=ROOT/'server/internal/chat/confirmationassets' if confirmation else ROOT/'server/internal/chat/welcomeassets' if welcome else ROOT/'server/internal/chat/custodyassets' if custody else ROOT/'server/internal/chat/peerassets' if peer else ROOT/'server/internal/chat/candidateassets' if candidate else ROOT/'server/internal/chat/successorassets' if successor else ROOT/'server/internal/chat/aggregatehistoryassets' if aggregate_history else ROOT/'server/internal/chat/aggregateassets' if aggregate else ROOT/'server/internal/chat/historyassets_v5' if history else ROOT/'server/internal/chat/vaultassets' if vault else OUTPUT
    manifest_path=ROOT/'server/internal/chat/confirmation_bundle.json' if confirmation else ROOT/'server/internal/chat/welcome_bundle.json' if welcome else ROOT/'server/internal/chat/custody_bundle.json' if custody else ROOT/'server/internal/chat/peer_bundle.json' if peer else ROOT/'server/internal/chat/candidate_bundle.json' if candidate else ROOT/'server/internal/chat/successor_bundle.json' if successor else ROOT/'server/internal/chat/aggregate_history_bundle.json' if aggregate_history else ROOT/'server/internal/chat/aggregate_bundle.json' if aggregate else ROOT/'server/internal/chat/history_bundle.json' if history else ROOT/'server/internal/chat/vault_bundle.json' if vault else MANIFEST
    lock=output.parent/'.mls-build.lock'
    check_parent_chain(lock)
    fd=os.open(lock,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_nlink!=1 or stat.S_IMODE(st.st_mode)!=0o600:raise ValueError('unsafe build lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        manifest=parse_manifest(read(manifest_path,12288 if welcome else 8192),vault,history,aggregate,aggregate_history,successor,candidate,peer,custody,welcome,confirmation)
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
    p=argparse.ArgumentParser();p.add_argument('--bundle',type=Path,required=True);p.add_argument('--check',action='store_true');mode=p.add_mutually_exclusive_group();mode.add_argument('--vault',action='store_true');mode.add_argument('--history',action='store_true');mode.add_argument('--aggregate',action='store_true');mode.add_argument('--aggregate-history',action='store_true');mode.add_argument('--successor',action='store_true');mode.add_argument('--candidate',action='store_true');mode.add_argument('--peer',action='store_true');mode.add_argument('--custody',action='store_true');mode.add_argument('--welcome',action='store_true');mode.add_argument('--confirmation',action='store_true');a=p.parse_args()
    try:prepare(a.bundle,a.check,a.vault,a.history,a.aggregate,a.aggregate_history,a.successor,a.candidate,a.peer,a.custody,a.welcome,a.confirmation)
    except (OSError,ValueError,KeyError,TypeError) as e:raise SystemExit('asset preparation rejected; existing files retained: '+str(e))
    print('Pinned synthetic assets verified; no runtime directory dependency.')
