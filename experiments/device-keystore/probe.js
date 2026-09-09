// Generated-data library feasibility only. No MLS provider or human key enters this page.
import {Encrypter, Decrypter, webauthn} from 'age-encryption';
const encode = new TextEncoder();
const data = encode.encode('synthetic opaque state bytes ' + 'x'.repeat(2048));
const dbName = 'family-key-custody-feasibility-v1';
let hint, ciphertext;
function bounded(input) {
  if (!Array.isArray(input) || input.length < 1 || input.length > 8192 || !input.every(x=>Number.isInteger(x)&&x>=0&&x<=255)) throw Error('bounded fixture bytes required');
  return new Uint8Array(input);
}
async function decrypt(bytes, identity=hint) {
  const d=new Decrypter();d.addIdentity(new webauthn.WebAuthnIdentity({identity}));
  const result=await d.decrypt(bytes);
  if(result.length!==data.length || !result.every((x,i)=>x===data[i]))throw Error('fixture mismatch');
  return true;
}
async function storage(write) {
  const db=await new Promise((resolve,reject)=>{const q=indexedDB.open(dbName,1);q.onupgradeneeded=()=>q.result.createObjectStore('fixture');q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});
  try {
    return await new Promise((resolve,reject)=>{
      const tx=db.transaction('fixture',write?'readwrite':'readonly',{durability:'strict'});let result;
      if(write)tx.objectStore('fixture').put({version:1,hint,ciphertext},'opaque');
      else {const q=tx.objectStore('fixture').get('opaque');q.onsuccess=()=>{result=q.result;};}
      tx.oncomplete=()=>resolve(result);tx.onabort=()=>reject(tx.error);
    });
  }finally{db.close();}
}
window.probe={
  async create(){hint=await webauthn.createCredential({keyName:'synthetic feasibility',rpId:'localhost'});return true;},
  async encrypt(){const e=new Encrypter();e.addRecipient(new webauthn.WebAuthnRecipient({identity:hint}));ciphertext=await e.encrypt(data);return {bytes:ciphertext.length};},
  async roundtrip(){return decrypt(ciphertext);},
  async saved(){await storage(true);return true;},
  async restored(){const r=await storage(false);if(!r||r.version!==1||typeof r.hint!=='string'||!(r.ciphertext instanceof Uint8Array))throw Error('missing fixture');hint=r.hint;ciphertext=r.ciphertext;return decrypt(ciphertext);},
  exportCipher(){return Array.from(ciphertext);},
  async supplied(input){return decrypt(bounded(input));},
  async wrongRP(){return webauthn.createCredential({keyName:'synthetic wrong RP',rpId:'example.invalid'});},
  async workerCapability(){return new Promise((resolve,reject)=>{const w=new Worker('/worker.js');const t=setTimeout(()=>{w.terminate();reject(Error('worker timeout'));},3000);w.onmessage=e=>{clearTimeout(t);w.terminate();resolve(e.data);};w.onerror=()=>{clearTimeout(t);w.terminate();reject(Error('worker error'));};});},
};
