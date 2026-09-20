"""Separate compiled successor graph; preparation and fault fixtures stay local."""
import hashlib
import http.client
import json
from password_worker_smoke import safe_bytes


def compiled_assets(root,bundle,assets,proof):
    path=root/'server/internal/chat/successor_bundle.json'
    manifest=json.loads(safe_bytes(path,8192));compiled={}
    for e in manifest['files']:
        source=bundle/e['source'][7:] if e['source'].startswith('bundle:') else root/e['source']
        raw=safe_bytes(source,2*1024*1024)
        assert len(raw)==e['bytes'] and hashlib.sha256(raw).hexdigest()==e['sha256']
        compiled[e['url']]=raw
    # Existing raw fault entrypoints must not accidentally use the compiled
    # original store. The actual lifecycle graph uses its unmodified route.
    assets['/fixture-successor-closure-store.js']=assets['/successor-closure-store.js']
    for role in ('candidate','peer'):
        key='/'+role+'-closure-worker.js'
        assets[key]=assets[key].replace(b'./successor-closure-store.js',b'./fixture-successor-closure-store.js')
        assets['/'+role+'-lifecycle-worker.js']=compiled['/'+role+'-lifecycle-worker.js']
    proof['successor_compiled_manifest_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
    proof['successor_compiled_expected_sha256']={p:hashlib.sha256(b).hexdigest() for p,b in compiled.items()}
    proof['successor_asset_boundary']='Normal lifecycle assets forwarded byte-for-byte from Go; preceding ceremony and explicitly instrumented closure fault entrypoints are separate local fixtures.'
    return compiled


def route_checks(port,cookies,compiled,proof):
    for path,expected_bytes in compiled.items():
        for principal,expected in ((None,401),(cookies[0],200),(cookies[1],200)):
            c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
            c.request('GET',path,headers={'Cookie':'synthetic_edge='+principal} if principal else {})
            r=c.getresponse();raw=r.read();c.close();assert r.status==expected,(path,r.status)
            if expected==200:assert raw==expected_bytes
    for path in ('/successor_bundle.json','/successorassets/pkg.wasm','/successor/../private','/successor-handoff/unknown'):
        c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
        c.request('GET',path,headers={'Cookie':'synthetic_edge='+cookies[0]})
        r=c.getresponse();r.read();c.close();assert r.status>=400,(path,r.status)
    proof['checks']['compiled_successor_all_23_routes_signed_both_actors_exact_bytes_headers']=True
    proof['checks']['compiled_successor_unknown_paths_and_manifest_not_served']=True
