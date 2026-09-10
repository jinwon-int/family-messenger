"""Disposable two-context archive proof; no deployment or human state."""
import base64
import copy
import hashlib
import json
import os
import secrets
import subprocess
import time
from password_worker_smoke import safe_bytes


def history_assets(root, work, assets, proof):
    cwd = root / 'experiments/device-keystore'
    inventory=json.loads(safe_bytes(cwd/'aggregate-history-inventory.json',65536))
    hashes = {}
    for name in ('aggregate-history-worker.js', 'aggregate-history-export-worker.js'):
        result = subprocess.run(['node', 'node_modules/esbuild/bin/esbuild', name,
            '--bundle', '--format=esm', '--platform=browser', '--target=es2023', '--minify',
            '--external:/pkg/*', '--external:/trust-directory.js'], cwd=cwd,
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert len(result.stdout) < 1024 * 1024
        assert len(result.stdout)==inventory['bundles'][name]['bytes']
        assert hashlib.sha256(result.stdout).hexdigest()==inventory['bundles'][name]['sha256']
        fd = os.open(work/name, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(result.stdout); f.flush(); os.fsync(f.fileno())
        assets['/'+name] = result.stdout
        hashes[name] = hashlib.sha256(result.stdout).hexdigest()
    assets['/aggregate-history-client.js'] = safe_bytes(cwd/'aggregate-history-client.js',65536)
    proof['aggregate_history_original_workers'] = hashes
    source = safe_bytes(root/'tests/fixtures/native-history/aggregate-forge-worker.js',65536)
    forged = subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm',
        '--platform=browser','--target=es2023','--minify','--sourcefile=aggregate-forge-worker.js',
        '--external:/pkg/*'],input=source,cwd=cwd,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE).stdout
    assets['/aggregate-history-forge-worker.js']=forged
    proof['aggregate_history_test_only_forger_sha256']=hashlib.sha256(forged).hexdigest()



def history_checks(a,b,sa,sb,databases,rpc,init,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,intent):
    check = proof['checks']
    groups = [rpc(p,'status')['group_id'] for p in (a,sa)]
    expected = {'database':databases[0], 'identity':'alice', 'primary_room':'family',
        'rooms':[{'room':room,'group_id':group,'pins':pins} for room,group in zip(('family','second'),groups)],
        'fork':intent}
    # Exact unaccepted outboxes stay encrypted, but must never appear in history.
    prepare(a,'app-history-pending',b'not delivered from source')
    prepare(sa,'app-history-pending-target',b'not delivered from target')
    before = digest(a,0)
    def install(p):
        p.evaluate("async()=>{const {AggregateHistoryReader}=await import('/aggregate-history-client.js');window.archiveReader=new AggregateHistoryReader(()=>{window.recovered=null});}")
    install(a)
    t=time.monotonic()
    exported=a.evaluate('''async arg=>{const r=await archiveReader.read(arg,true);return {ok:r.ok,archive:r.ok?Array.from(r.result.archive):null,memory:r.memory_bytes}}''',{'expected':expected,'password':passwords[0]})
    assert exported['ok'],exported
    assert digest(a,0)==before
    archive=exported['archive']
    proof['aggregate_history_export_ms']=round((time.monotonic()-t)*1000,2)
    proof['aggregate_history_archive_bytes']=len(archive)
    proof['aggregate_history_max_linear_bytes']=exported['memory']
    assert exported['memory']<=128*1024*1024 and len(archive)<6*1024*1024
    check['aggregate_export_is_coherent_readonly_and_preserves_both_pending_outboxes']=True
    install(b)
    other=copy.deepcopy(expected);other['database']=databases[1];other['identity']='bob'
    other_export=b.evaluate('''async arg=>{const r=await archiveReader.read(arg,true);return r.ok?Array.from(r.result.archive):null}''',{'expected':other,'password':passwords[1]})
    assert other_export

    crash(0);a=page(0)
    assert digest(a,0)==before
    # Fresh browser context, no inherited database/cookie or native worker.
    context=b.context.browser.new_context()
    reader=context.new_page();reader.goto(a.url);install(reader)
    requests=[];context.on('request',lambda r:requests.append(r.url))
    assert reader.evaluate('indexedDB.databases()')==[]
    def read(raw=archive, exp=expected, password=passwords[0], accept=True):
        r=reader.evaluate('''async arg=>{arg.archive=new Uint8Array(arg.archive);const r=await archiveReader.read(arg);window.recovered=r.ok?r.result:null;return r}''',{'archive':raw,'expected':exp,'password':password})
        assert r['ok'] is accept,r
        if accept:
            assert r['memory_bytes']<=128*1024*1024
            proof['aggregate_history_max_linear_bytes']=max(proof['aggregate_history_max_linear_bytes'],r['memory_bytes'])
            return r['result']
        assert 'result' not in r
    try:
        recovered=read()
        assert set(recovered)=={'identity','primary_room','rooms'}
        assert [r['room'] for r in recovered['rooms']]==['family','second']
        for r in recovered['rooms']:
            assert set(r)=={'identity','room','group_id','pins','cursor','epoch','messages'}
            assert all('history-pending' not in m['client_id'] for m in r['messages'])
        assert recovered['rooms'][0]['epoch']==2 and recovered['rooms'][1]['epoch']==1
        assert any(base64.b64decode(m['payload'])==bytes(range(256))*32 for m in recovered['rooms'][1]['messages'])
        assert any(base64.b64decode(m['payload'])=='synthetic second room 한글'.encode() for m in recovered['rooms'][1]['messages'])
        check['source_sigkill_independent_reader_recovers_two_groups_text_8192_file_and_control_epochs']=True
        check['pending_frames_from_either_room_never_recovered_as_delivery']=True
        assert digest(a,0)==before and reader.evaluate('indexedDB.databases()')==[]
        assert not any('/v1/' in u for u in requests)
        check['aggregate_reader_has_zero_native_requests_imports_or_live_writes']=True

        forged=reader.evaluate('''arg=>new Promise(resolve=>{const w=new Worker('/aggregate-history-forge-worker.js',{type:'module'});w.onmessage=({data})=>{if(data.ready)w.postMessage(arg);else{w.terminate();resolve(data)}}})''',{'archive':archive,'password':passwords[0]})
        assert forged['ok']
        for kind,raw in forged['fixtures'].items():
            if kind=='reordered-intent':assert read(raw=raw)==recovered
            else:read(raw=raw,accept=False)
        check['valid_mac_wrong_sender_pending_provider_epoch_fork_room_and_nonfinal_denied']=True
        check['valid_authenticated_intent_property_order_preserves_recovery']=True
        read(password=secrets.token_urlsafe(32),accept=False)
        for field,value in [('identity','bob'),('database',databases[0]+'-other'),('primary_room','second')]:
            e=copy.deepcopy(expected);e[field]=value;read(exp=e,accept=False)
        for room in (0,1):
            for field,value in [('room','substituted'),('group_id','aa'*32)]:
                e=copy.deepcopy(expected);e['rooms'][room][field]=value;read(exp=e,accept=False)
        e=copy.deepcopy(expected);e['fork']['id']='context-changed';read(exp=e,accept=False)
        e=copy.deepcopy(expected)
        for ps in (e['rooms'][0]['pins'],e['rooms'][1]['pins'],e['fork']['pins']):
            ps[1]['signing_key']='11'*32;ps[1]['fingerprint']=hashlib.sha256(bytes.fromhex('11'*32)).hexdigest()
        read(exp=e,accept=False)
        check['independent_actor_database_rooms_groups_fork_and_peer_pins_required']=True
        for field in ('capsule','header','cipher','revision','vault','room'):
            wire=json.loads(bytes(archive));state=wire['state']
            if field in ('capsule','header','cipher'):
                buf=bytearray(base64.b64decode(state[field]));buf[-1]^=1;state[field]=base64.b64encode(buf).decode()
            elif field=='revision':state[field]+=1
            elif field=='vault':state[field]='ab'*16
            else:state[field]='family'
            read(raw=list(json.dumps(wire,separators=(',',':')).encode()),accept=False)
        read(raw=archive[:-1],accept=False)
        read(raw=list(bytes(archive).replace(b'"format":',b'"format":"wrong","format":',1)),accept=False)
        check['aggregate_capsule_header_cipher_metadata_truncation_duplicate_fields_denied']=True
        other_wire=json.loads(bytes(other_export))
        for field in ('capsule','header','cipher'):
            wire=json.loads(bytes(archive));wire['state'][field]=other_wire['state'][field]
            read(raw=list(json.dumps(wire,separators=(',',':')).encode()),accept=False)
        check['cross_actor_capsule_header_and_cipher_swaps_denied']=True
        for code in ("new Uint8Array(6*1024*1024+1)","new Uint8Array(new ArrayBuffer(6*1024*1024+1),0,1)"):
            assert not reader.evaluate('async arg=>{arg.archive='+code+';return (await archiveReader.read(arg)).ok}',{'expected':expected,'password':passwords[0]})
        check['aggregate_archive_and_backing_bounds_enforced_before_clone']=True
        missing={**expected,'database':databases[0]+'-missing'}
        assert not reader.evaluate('arg=>archiveReader.read(arg,true)',{'expected':missing,'password':passwords[0]})['ok']
        assert reader.evaluate('indexedDB.databases()')==[]
        check['missing_aggregate_export_does_not_create_database']=True

        reader.evaluate("()=>{window.kdfHeld=false;navigator.locks.request('family-native-vault-kdf',()=>new Promise(r=>{window.releaseKdf=r;window.kdfHeld=true}))}")
        reader.wait_for_function('()=>kdfHeld')
        reader.evaluate('arg=>{arg.archive=new Uint8Array(arg.archive);window.late=archiveReader.read(arg)}',{'archive':archive,'expected':expected,'password':passwords[0]})
        reader.wait_for_function("async()=>{const q=await navigator.locks.query();return q.pending.some(x=>x.name==='family-native-vault-kdf')}")
        reader.evaluate('()=>{archiveReader.lock();releaseKdf()}')
        assert not reader.evaluate('late')['ok'] and reader.evaluate('recovered') is None
        check['aggregate_reader_lock_retires_queued_kdf_and_late_output']=True
        reader.evaluate('archiveReader.close()')
        read(accept=False)
        install(reader)
        assert not reader.evaluate('''arg=>{arg.archive=new Uint8Array(arg.archive);arg.bad=()=>{};return archiveReader.read(arg)}''',{'archive':archive,'expected':expected,'password':passwords[0]})['ok']
        reader.reload();install(reader);assert read()==recovered
        check['aggregate_reader_close_clone_failure_reload_requires_fresh_unlock']=True

        config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2
        commit(2,config['people'])
        end=time.monotonic()+5
        while time.monotonic()<end:
            code,value=direct('owner','GET','/v1/rooms/family/devices')
            if code==200 and any(x['status']=='revoked' for x in value['devices']):break
            time.sleep(.05)
        else:raise AssertionError('revocation reload')
        assert read()==recovered
        assert not any('/v1/' in u for u in requests) and reader.evaluate('indexedDB.databases()')==[]
        assert reader.evaluate('localStorage.length+sessionStorage.length')==0 and digest(a,0)==before
        check['revocation_does_not_erase_possessed_past_archive_and_reader_never_resumes_sender']=True
        for method in ('send','import','fork'):
            r=reader.evaluate('''method=>new Promise(resolve=>{const w=new Worker('/aggregate-history-worker.js',{type:'module'});w.onmessage=({data})=>{if(data.ready)w.postMessage({id:1,method,argument:null});else{w.terminate();resolve(data)}}})''',method)
            assert not r['ok']
        check['aggregate_reader_rejects_send_import_and_device_fork_methods']=True
    finally:context.close()
    proof['native_aggregate_readonly_history']=True
