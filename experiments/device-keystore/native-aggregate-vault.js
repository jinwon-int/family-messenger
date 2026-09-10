// Synthetic multi-conversation aggregate custody container (#49 first slice).
// One device-scoped namespace holds at most two complete conversation records
// under ONE authenticated encrypted record guarded by ONE strict IndexedDB CAS.
// This is the container boundary only: no signed admission, no peer pins and no
// UI live here. The MLS identity binding (#49 second slice) seals the aggregate
// under the caller-supplied signer public key: the key rides in the capsule
// payload and is bound into the AAD (label version 2), so a record sealed under
// one identity never opens under another. The format, label, capsule payload
// and AAD are deliberately disjoint from native-vault-store.js so the two
// profiles cannot be confused; the old single-room databases are never opened,
// imported, rewritten or deleted by this store.
import {Encrypter,Decrypter} from 'age-encryption';
let sodium;
const instantiate=WebAssembly.instantiate,memories=[];
WebAssembly.instantiate=async(...args)=>{const result=await instantiate(...args);for(const v of Object.values((result.instance??result).exports))if(v instanceof WebAssembly.Memory)memories.push(v);return result;};
try{({default:sodium}=await import('libsodium-wrappers'));await sodium.ready;if(!memories.some(m=>m.buffer===sodium.libsodium.HEAPU8.buffer))throw Error('WASM required');}finally{WebAssembly.instantiate=instantiate;}
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const MAX=4*1024*1024,RECORD=65536,ROOMS=2;
const fail=()=>{throw Error('aggregate vault rejected')};
const exact=(o,fields)=>o&&Object.getPrototypeOf(o)===Object.prototype&&Object.keys(o).sort().join(',')===fields.split(',').sort().join(',');
const sameBytes=(a,b)=>a instanceof Uint8Array&&b instanceof Uint8Array&&a.length===b.length&&a.every((v,i)=>v===b[i]);
const binary=(x,max,min=1)=>{if(!(x instanceof Uint8Array)||!(x.buffer instanceof ArrayBuffer)||x.length<min||x.length>max)fail();return x;};
const hex=b=>sodium.to_hex(b);
function base64(b){let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);}
function unbase64(s){if(typeof s!=='string'||s.length>Math.ceil(RECORD/3)*4)fail();const b=Uint8Array.from(atob(s),x=>x.charCodeAt(0));if(base64(b)!==s||b.length>RECORD)fail();return b;}
function encode(r){const b=enc.encode(JSON.stringify({...r,records:r.records.map(x=>({...x,bytes:base64(x.bytes)}))}));if(b.length>MAX)fail();return b;}
function decode(b){binary(b,MAX);const r=JSON.parse(dec.decode(b));if(!r||typeof r.crypto==='string'||!Array.isArray(r.records))fail();for(const x of r.records){if(typeof x.bytes!=='string')fail();x.bytes=unbase64(x.bytes);}return r;}
function validateEnvelope(r){if(!exact(r,'v,records')||r.v!==1)fail();validateRecords(r.records);}
function validateRecords(records){
 if(!Array.isArray(records)||records.length>ROOMS)fail();
 let seen='';
 for(const x of records){
  if(!exact(x,'room,bytes,checksum')||typeof x.room!=='string'||!/^[a-z0-9-]{1,64}$/.test(x.room))fail();
  if(!(x.room>seen))fail();seen=x.room;binary(x.bytes,RECORD);
  if(x.checksum!==hex(sodium.crypto_hash(x.bytes)))fail();
 }
}
export class AggregateVaultStore {
 constructor(){this.dead=false;this.transactions=new Set();this.controllers=new Set();this.operations=0;}
 argument(arg){
  if(this.password!==undefined||!exact(arg,'actor,database,password,create,pub')||typeof arg.actor!=='string'||!/^[a-z0-9-]{1,64}$/.test(arg.actor)||typeof arg.database!=='string'||typeof arg.password!=='string'||arg.password.length<32||arg.password.length>128||typeof arg.create!=='boolean'||typeof arg.pub!=='string'||!/^[a-f0-9]{64}$/.test(arg.pub))fail();
  this.password=arg.password;this.create=arg.create;this.pub=arg.pub;return {actor:arg.actor,database:arg.database};
 }
 live(){if(this.dead||sodium.libsodium.HEAPU8.length>128*1024*1024)fail();}
 async open(database,actor){
  this.live();if(!/^family-mls-aggregate-synthetic-[a-z0-9-]{1,64}$/.test(database))fail();
  this.database=database;this.actor=actor;
  this.db=await new Promise((resolve,reject)=>{
   const q=indexedDB.open(database,1);q.onupgradeneeded=e=>{if(!this.create||e.oldVersion!==0){q.transaction.abort();return;}q.result.createObjectStore('aggregate').add({v:0,actor},'state');};
   q.onerror=()=>reject(Error('aggregate vault unavailable'));q.onblocked=()=>reject(Error('aggregate vault blocked'));
   q.onsuccess=()=>{const d=q.result;if(this.dead||d.objectStoreNames.length!==1||!d.objectStoreNames.contains('aggregate')){d.close();reject(Error('schema'));return;}d.onversionchange=()=>this.close();resolve(d);};
  });return this.db;
 }
 close(){this.dead=true;this.password=null;if(this.root)sodium.memzero(this.root.key);this.root=null;for(const c of this.controllers)c.abort();for(const t of this.transactions){try{t.abort()}catch{}}this.db?.close();}
 memoryBytes(){return sodium.libsodium.HEAPU8.length;}
 async lock(name,fn){
  this.live();if(!navigator.locks)fail();const c=new AbortController();this.controllers.add(c);const timer=setTimeout(()=>c.abort(),15000);
  try{return await navigator.locks.request(name,{mode:'exclusive',signal:c.signal},async()=>{this.live();const result=await fn(()=>{this.live();if(c.signal.aborted)fail();});this.live();if(c.signal.aborted)fail();return result;});}
  finally{clearTimeout(timer);this.controllers.delete(c);}
 }
 read(){return new Promise((resolve,reject)=>{
  this.live();const t=this.db.transaction('aggregate','readonly'),s=t.objectStore('aggregate');this.transactions.add(t);let value;
  t.onabort=()=>{this.transactions.delete(t);reject(Error('read aborted'));};t.oncomplete=()=>{this.transactions.delete(t);resolve(value);};
  const keys=s.getAllKeys(undefined,2);keys.onsuccess=()=>{if(keys.result.length!==1||keys.result[0]!=='state'){t.abort();return;}const q=s.get('state');q.onsuccess=()=>{value=q.result;};};
 });}
 outer(r){
  if(!exact(r,'v,actor,vault,revision,capsule,header,cipher')||r.v!==1||r.actor!==this.actor||typeof r.vault!=='string'||!/^[a-f0-9]{32}$/.test(r.vault)||!Number.isSafeInteger(r.revision)||r.revision<1||r.revision>512)fail();
  binary(r.capsule,8192);binary(r.header,24,24);binary(r.cipher,MAX+17,17);
 }
 equal(a,b){
  if(exact(a,'v,actor')&&a.v===0)return exact(b,'v,actor')&&b.v===0&&a.actor===b.actor;
  this.outer(a);this.outer(b);return ['v','actor','vault','revision'].every(k=>a[k]===b[k])&&['capsule','header','cipher'].every(k=>sameBytes(a[k],b[k]));
 }
 aad(revision){return enc.encode(JSON.stringify(['family-native-aggregate',2,this.database,this.actor,this.root.id,this.root.pub,revision]));}
 async key(record,plain,devicePub){
  if(this.root){if(this.create||record.vault!==this.root.id||record.revision<this.root.seen||!sameBytes(record.capsule,this.root.capsule)||this.root.pub!==devicePub)fail();return;}
  await this.lock('family-native-aggregate-kdf',async live=>{
   const password=this.password;if(typeof password!=='string')fail();
   try{
    if(plain){
     const key=sodium.crypto_secretstream_xchacha20poly1305_keygen(),id=hex(sodium.randombytes_buf(16));
     try{
      const e=new Encrypter();e.setPassphrase(password);const payload=enc.encode(JSON.stringify([1,this.database,this.actor,id,devicePub,Array.from(key)]));let capsule;
      try{capsule=await e.encrypt(payload);}finally{sodium.memzero(payload);}live();
      this.root={key:key.slice(),id,pub:devicePub,capsule,seen:0};
     }finally{sodium.memzero(key);}
    }else{
     await admit(record.capsule);live();const d=new Decrypter();d.addPassphrase(password);const bytes=await d.decrypt(record.capsule);
     try{
      if(bytes.length>2048)fail();const p=JSON.parse(dec.decode(bytes));
      if(!Array.isArray(p)||p.length!==6||p[0]!==1||p[1]!==this.database||p[2]!==this.actor||p[3]!==record.vault||typeof p[4]!=='string'||!/^[a-f0-9]{64}$/.test(p[4])||!Array.isArray(p[5])||p[5].length!==32)fail();
      for(let i=0;i<32;i++)if(!Object.hasOwn(p[5],i)||!Number.isInteger(p[5][i])||p[5][i]<0||p[5][i]>255)fail();live();
      if(p[4]!==devicePub)fail();
      this.root={key:new Uint8Array(p[5]),id:p[3],pub:p[4],capsule:record.capsule.slice(),seen:record.revision};
     }finally{sodium.memzero(bytes);}
    }
   }finally{this.password=null;}
  });
 }
 commit(before,after,fault,live){return new Promise((resolve,reject)=>{
  live();const t=this.db.transaction('aggregate','readwrite',{durability:'strict'}),s=t.objectStore('aggregate');this.transactions.add(t);
  t.onabort=()=>{this.transactions.delete(t);reject(Error('candidate conflict or abort'));};t.oncomplete=()=>{this.transactions.delete(t);resolve();};
  const keys=s.getAllKeys(undefined,2);keys.onsuccess=()=>{if(keys.result.length!==1||keys.result[0]!=='state'){t.abort();return;}const q=s.get('state');q.onsuccess=()=>{try{
   live();if(!this.equal(before,q.result)||fault==='abort-before-write')fail();if(after)s.put(after,'state');if(fault==='abort-after-write')fail();
  }catch{t.abort();}};};
 });}
 async tx(directory,operation,fault,live,admit){
  this.live();if(++this.operations>256)fail();
  if(!directory||!Array.isArray(directory.devices))fail();
  return this.lock('family-native-aggregate-state:'+this.database,async live=>{
   const before=await this.read();live();
   let r,original,devicePub;
   if(exact(before,'v,actor')&&before.v===0&&before.actor===this.actor){
    if(!this.create||directory.devices.some(x=>x.actor===this.actor))fail();
    devicePub=this.pub;r={v:1,records:[]};await this.key(null,true,devicePub);
   }else{
    if(this.create)fail();this.outer(before);devicePub=this.pub;await this.key(before,false,devicePub);live();
    const state=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,this.root.key),output=sodium.crypto_secretstream_xchacha20poly1305_pull(state,before.cipher,this.aad(before.revision));
    if(!output)fail();try{if(output.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();r=decode(output.message);}finally{sodium.memzero(output.message);}
    validateEnvelope(r);original=encode(r);
   }
   if(operation.kind!=='put')fail();
   binary(operation.bytes,RECORD);const record={room:operation.room,bytes:operation.bytes.slice(),checksum:hex(sodium.crypto_hash(operation.bytes))};
   r={v:1,records:[...r.records.filter(x=>x.room!==record.room),record].sort((a,b)=>a.room<b.room?-1:1)};
   validateEnvelope(r);const candidate=encode(r);
   let after=null;
   try{
    if(!original||!sameBytes(candidate,original)){
     const revision=before.v===0?1:before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(this.root.key);
     const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,candidate,this.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
     after={v:1,actor:this.actor,vault:this.root.id,revision,capsule:this.root.capsule.slice(),header,cipher};
    }
    const fresh=await admit();live();if(!fresh||!Array.isArray(fresh.devices))fail();
    await this.commit(before,after,fault,live);live();this.create=false;this.root.seen=(after??before).revision;
    const sealed=after??before;return {revision:sealed.revision,rooms:r.records.map(x=>({room:x.room,bytes:x.bytes.length,checksum:x.checksum}))};
   }finally{sodium.memzero(candidate);if(original)sodium.memzero(original);}
  });
 }
}
async function admit(capsule){
 const yes={},d=new Decrypter();d.addIdentity({unwrapFileKey(s){if(s.length!==1||s[0].args.length!==3||s[0].args[0]!=='scrypt'||s[0].args[2]!=='18'||s[0].body.length!==32)fail();throw yes;}});
 try{await d.decrypt(capsule)}catch(e){if(e===yes)return;}fail();
}
