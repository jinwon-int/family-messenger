"""Encrypted-store fixtures only: instrument held writes, never export private state."""
import hashlib
import subprocess


def vault_assets(root,work,assets):
    assets['/vault-native-worker.js']=(root/'experiments/openmls-browser/web/vault-native-worker.js').read_bytes()
    assets['/main.js']=(root/'tests/fixtures/native-vault/main.js').read_bytes()
    path=root/'experiments/device-keystore/native-vault-store.js';source=path.read_bytes()
    original=work/'native-vault-store-original.js'
    subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=native-vault-store.js','--outfile='+str(original)],input=source,cwd=root/'experiments/device-keystore',check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    needle=b"if(after)s.put(after,'state');if(fault==='abort-after-write')"
    assert source.count(needle)==1
    source=source.replace(needle,b"if(after)s.put(after,'state');if(fault==='crash-before-complete'){self.postMessage({test_crash_boundary:true});while(true){}}if(fault==='abort-after-write')")
    needle=b'const fresh=await options.admit();live();'
    assert source.count(needle)==1
    source=source.replace(needle,b"if(after&&self.testHoldVaultCAS){self.testHoldVaultCAS=false;self.postMessage({test_vault_cas:true});await new Promise(resolve=>{self.testVaultCASRelease=resolve;});}"+needle)
    needle=b"await this.lock('family-native-vault-kdf',async live=>{"
    assert source.count(needle)==1
    source=source.replace(needle,b"self.postMessage({test_kdf_waiting:true});"+needle+b"self.postMessage({test_kdf_entered:true});if(self.testHoldVaultKDF){self.testHoldVaultKDF=false;await new Promise(resolve=>{self.testVaultKDFRelease=resolve;});}")
    output=work/'native-vault-store-instrumented.js'
    subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=native-vault-store.js','--outfile='+str(output)],input=source,cwd=root/'experiments/device-keystore',check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    assets['/native-vault-store.js']=output.read_bytes()
    return original.read_bytes()


def vault_checks(a,b,databases,rpc,reopen,prepare,proof,page,passwords):
    # Only public envelope fields/ciphertext are inspected in page context.
    fields=a.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});const value=await new Promise((r,j)=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return {keys:Object.keys(value).sort(),capsule:value.capsule.length,cipher:value.cipher.length,header:value.header.length,revision:value.revision,hasProvider:'crypto' in value,hasCache:'messages' in value}}''',databases[0])
    assert fields['keys']==sorted(['v','identity','room','vault','revision','capsule','header','cipher'])
    assert not fields['hasProvider'] and not fields['hasCache'] and fields['capsule']<8192 and fields['header']==24
    proof['encrypted_state_sizes']=fields
    proof['checks']['idb_stores_only_capsule_and_authenticated_whole_record']=True

    def saved(p):
        p.evaluate("""async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});window.savedVault=await new Promise((r,j)=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close()}""",databases[0])
    def restore(p):
        p.evaluate("""async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});await new Promise((r,j)=>{const t=d.transaction('device','readwrite');t.objectStore('device').put(window.savedVault,'state');t.oncomplete=r;t.onabort=j});d.close()}""",databases[0])
    saved(a);rpc(a,'test-vault-hold-cas')
    a.evaluate('()=>{window.pending=call("device","prepare",{id:"app-cas-rejected",bytes:[42],media_type:"file",fault:""})}')
    a.wait_for_function('()=>window.test_vault_cas===true',timeout=5000)
    a.evaluate("""async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});await new Promise((r,j)=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),q=s.get('state');q.onsuccess=()=>{const v=q.result;v.revision++;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}""",databases[0])
    a.evaluate('window.testWorkers.at(-1).postMessage({test_vault_release:"cas"})')
    assert not a.evaluate('()=>window.pending')['ok']
    assert a.evaluate("""async name=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});const v=await new Promise(r=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result)});d.close();return v.revision===window.savedVault.revision+1}""",databases[0])
    restore(a);reopen(a,0)
    proof['checks']['async_candidate_holds_no_idb_transaction_and_cas_preserves_conflict']=True
    # Corrupt this same database, so rejection is not merely a different name.
    for key in ['capsule','cipher']:
        saved(a)
        a.evaluate("""async([name,key])=>{const d=await new Promise(r=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result)});await new Promise((r,j)=>{const t=d.transaction('device','readwrite'),s=t.objectStore('device'),q=s.get('state');q.onsuccess=()=>{const v=q.result;v[key][v[key].length-1]^=1;s.put(v,'state')};t.oncomplete=r;t.onabort=j});d.close()}""",[databases[0],key])
        rpc(a,'status',reject=True);restore(a);reopen(a,0)
    proof['checks']['same_database_capsule_and_record_corruption_denied']=True
    # Two distinct DB operation locks must still share one origin-wide KDF slot.
    clone=databases[0]+'-kdf'
    saved(a)
    a.evaluate("""async name=>{await new Promise((r,j)=>{const q=indexedDB.open(name,1);q.onupgradeneeded=()=>q.result.createObjectStore('device').add(window.savedVault,'state');q.onsuccess=()=>{q.result.close();r()};q.onerror=j})}""",clone)
    a.evaluate('async()=>{stopWorker("device");await spawn("device")}')
    rpc(a,'test-vault-hold-kdf')
    first={'identity':'alice','room':'family','database':databases[0],'password':passwords[0],'create':False}
    a.evaluate('arg=>{window.test_kdf_entered=false;window.pending=call("device","init",arg)}',first)
    a.wait_for_function('()=>window.test_kdf_entered===true',timeout=5000)
    second=page(0)
    second.evaluate('arg=>{window.pending=call("device","init",arg)}',{**first,'database':clone})
    second.wait_for_function('async()=>{const q=await navigator.locks.query();return q.pending.some(x=>x.name==="family-native-vault-kdf")}',timeout=5000)
    assert not second.evaluate('Boolean(window.test_kdf_entered)')
    a.evaluate('window.testWorkers.at(-1).postMessage({test_vault_release:"kdf"})')
    assert a.evaluate('()=>window.pending')['ok']
    assert not second.evaluate('()=>window.pending')['ok'] # capsule binds original DB.
    proof['checks']['origin_wide_kdf_serialized_across_distinct_database_locks']=True
    # Clone failure must retire immediately; old timers cannot remove a new worker.
    denied=a.evaluate('()=>call("device","status",{extra:()=>{}})')
    assert not denied['ok'];reopen(a,0)
    a.evaluate('window.lockVaults()')
    rpc(a,'status',reject=True);reopen(a,0)
    proof['checks']['explicit_cross_tab_lock_and_uncloneable_send_retire']=True

    invalid=a.evaluate("""()=>new Promise(resolve=>{const w=window.testWorkers.at(-1);w.addEventListener('message',e=>{if(e.data.id===0)resolve(e.data)},{once:true});w.postMessage({id:0,method:'lock',argument:{unexpected:true},extra:true})})""")
    assert not invalid['ok'];reopen(a,0)
    assert rpc(a,'lock')['locked'];reopen(a,0)
    proof['checks']['immediate_lock_validates_envelope_and_retires_on_malformed_command']=True
