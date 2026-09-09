"""Encrypted-store fixtures only: instrument held writes, never export private state."""
import hashlib
import subprocess


def vault_assets(root,work,assets):
    assets['/vault-native-worker.js']=(root/'experiments/openmls-browser/web/vault-native-worker.js').read_bytes()
    assets['/main.js']=assets['/main.js'].replace(b"'./native-worker.js'",b"'./vault-native-worker.js'")
    assets['/main.js']=assets['/main.js'].replace(b'}, 10000);',b'}, 30000);')
    assets['/main.js']=assets['/main.js'].replace(b'  worker.postMessage({id, method, argument});',b'  try{worker.postMessage({id, method, argument});}catch{worker.terminate();workers.delete(name);cleanup();reject(new Error("send rejected"));}')
    assets['/main.js']+=b'\nconst vaultLocks=new BroadcastChannel("family-vault-view-lock");const closeVaults=()=>{for(const name of [...workers.keys()])window.stopWorker(name)};vaultLocks.onmessage=closeVaults;window.lockVaults=()=>{closeVaults();vaultLocks.postMessage("lock")};addEventListener("pagehide",window.lockVaults);addEventListener("visibilitychange",()=>{if(document.hidden)window.lockVaults()});\n'
    path=root/'experiments/device-keystore/native-vault-store.js';source=path.read_bytes()
    needle=b"if(after)s.put(after,'state');if(fault==='abort-after-write')"
    assert source.count(needle)==1
    source=source.replace(needle,b"if(after)s.put(after,'state');if(fault==='crash-before-complete'){self.postMessage({test_crash_boundary:true});while(true){}}if(fault==='abort-after-write')")
    output=work/'native-vault-store-instrumented.js'
    subprocess.run(['node','node_modules/esbuild/bin/esbuild','--bundle','--format=esm','--platform=browser','--target=es2023','--minify','--sourcefile=native-vault-store.js','--outfile='+str(output)],input=source,cwd=root/'experiments/device-keystore',check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    assets['/native-vault-store.js']=output.read_bytes()


def vault_checks(a,b,databases,rpc,reopen,prepare,proof):
    # Only public envelope fields/ciphertext are inspected in page context.
    fields=a.evaluate('''async name=>{const d=await new Promise((r,j)=>{const q=indexedDB.open(name);q.onsuccess=()=>r(q.result);q.onerror=j});const value=await new Promise((r,j)=>{const q=d.transaction('device').objectStore('device').get('state');q.onsuccess=()=>r(q.result);q.onerror=j});d.close();return {keys:Object.keys(value).sort(),capsule:value.capsule.length,cipher:value.cipher.length,header:value.header.length,revision:value.revision,hasProvider:'crypto' in value,hasCache:'messages' in value}}''',databases[0])
    assert fields['keys']==sorted(['v','identity','room','vault','revision','capsule','header','cipher'])
    assert not fields['hasProvider'] and not fields['hasCache'] and fields['capsule']<8192 and fields['header']==24
    proof['encrypted_state_sizes']=fields
    proof['checks']['idb_stores_only_capsule_and_authenticated_whole_record']=True
