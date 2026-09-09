// Test harness only: no human secrets, native profile, or unlocked MLS session.
let generation = 0, active = null;
const dbName = 'family-password-container-synthetic-v1';
const channel = new BroadcastChannel(dbName);
function retire() {
  generation++;
  if (active) {
    const old = active; active = null;
    clearTimeout(old.timer); old.worker.terminate(); old.resolve({denied:true,locked:true,kdf:old.kdf});
  }
}
channel.onmessage = () => retire();
function lock() { retire(); channel.postMessage('lock'); }
addEventListener('pagehide',lock);
addEventListener('visibilitychange',() => { if (document.hidden) lock(); });
async function command(op,password,ciphertext=null) {
  if (active) throw Error('busy');
  const g = ++generation;
  return new Promise(resolve => {
    const worker = new Worker('/password-worker.js',{type:'module'});
    const current = {worker,resolve,kdf:false,timer:null}; active = current;
    current.timer = setTimeout(lock,20000);
    worker.onerror = () => lock();
    worker.onmessage = ({data}) => {
      if (generation !== g || active !== current) return;
      if (data.type === 'kdf-start') { current.kdf = true; return; }
      clearTimeout(current.timer); worker.terminate(); active = null;
      resolve(data.type === 'done' ? {...data,kdf:current.kdf} : {denied:true,kdf:current.kdf});
    };
    worker.postMessage({op,password,ciphertext});
  });
}
async function db() {
  return new Promise((resolve,reject) => {
    const r = indexedDB.open(dbName,1);
    r.onupgradeneeded = () => r.result.createObjectStore('archive');
    r.onerror = () => reject(Error('storage'));
    r.onsuccess = () => resolve(r.result);
  });
}
async function archive(ciphertext) {
  if (!Array.isArray(ciphertext) || ciphertext.length > 8192 || ciphertext.length < 1 ||
      !ciphertext.every(x => Number.isInteger(x) && x>=0 && x<=255)) throw Error('fixture');
  const connection = await db();
  try {
    await new Promise((resolve,reject) => {
      const tx = connection.transaction('archive','readwrite',{durability:'strict'});
      const store = tx.objectStore('archive'); const r = store.get('only');
      r.onsuccess = () => { if (r.result !== undefined) tx.abort(); else store.add({version:1,ciphertext},'only'); };
      tx.oncomplete = resolve; tx.onabort = () => reject(Error('archive exists or aborted'));
    });
  } finally { connection.close(); }
}
async function load() {
  const connection = await db();
  try {
    return await new Promise((resolve,reject) => {
      const tx = connection.transaction('archive'); const r = tx.objectStore('archive').get('only');
      tx.oncomplete = () => {
        const value = r.result;
        if (!value || value.version !== 1 || Object.keys(value).sort().join(',') !== 'ciphertext,version') reject(Error('missing or unknown archive'));
        else resolve(value.ciphertext);
      };
      tx.onabort = () => reject(Error('storage'));
    });
  } finally { connection.close(); }
}
window.passwordProbe = {command,lock,archive,load,active:() => active ? {kdf:active.kdf} : null};
