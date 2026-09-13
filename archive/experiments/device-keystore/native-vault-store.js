// Synthetic encrypted persistence driver. No plaintext fallback or legacy migration.
import {Encrypter,Decrypter} from 'age-encryption';
let sodium;
const instantiate=WebAssembly.instantiate,memories=[];
WebAssembly.instantiate=async(...args)=>{const result=await instantiate(...args);for(const v of Object.values((result.instance??result).exports))if(v instanceof WebAssembly.Memory)memories.push(v);return result;};
try{({default:sodium}=await import('libsodium-wrappers'));await sodium.ready;if(!memories.some(m=>m.buffer===sodium.libsodium.HEAPU8.buffer))throw Error('WASM required');}finally{WebAssembly.instantiate=instantiate;}
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const MAX=4*1024*1024;
const fail=()=>{throw Error('vault rejected')};
const exact=(o,fields)=>o&&Object.getPrototypeOf(o)===Object.prototype&&Object.keys(o).sort().join(',')===fields.split(',').sort().join(',');
const sameBytes=(a,b)=>a instanceof Uint8Array&&b instanceof Uint8Array&&a.length===b.length&&a.every((v,i)=>v===b[i]);
const binary=(x,max,min=1)=>{if(!(x instanceof Uint8Array)||!(x.buffer instanceof ArrayBuffer)||x.length<min||x.length>max)fail();return x;};
const hex=b=>sodium.to_hex(b);
function base64(b){let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);}
function unbase64(s){if(typeof s!=='string'||s.length>Math.ceil(1048576/3)*4)fail();const b=Uint8Array.from(atob(s),x=>x.charCodeAt(0));if(base64(b)!==s||b.length>1048576)fail();return b;}
function encode(r){const b=enc.encode(JSON.stringify({...r,crypto:base64(r.crypto)}));if(b.length>MAX)fail();return b;}
function decode(b){binary(b,MAX);const r=JSON.parse(dec.decode(b));if(!r||typeof r.crypto!=='string')fail();r.crypto=unbase64(r.crypto);return r;}
async function admit(capsule){
 const yes={},d=new Decrypter();d.addIdentity({unwrapFileKey(s){if(s.length!==1||s[0].args.length!==3||s[0].args[0]!=='scrypt'||s[0].args[2]!=='18'||s[0].body.length!==32)fail();throw yes;}});
 try{await d.decrypt(capsule)}catch(e){if(e===yes)return;}fail();
}
export class NativeVaultStore {
 constructor(){this.dead=false;this.root=null;this.transactions=new Set();this.controllers=new Set();this.maxSerialized=0;this.operations=0;}
 argument(arg){
  if(this.password!==undefined||!exact(arg,'identity,room,database,password,create')||typeof arg.password!=='string'||arg.password.length<32||arg.password.length>128||typeof arg.create!=='boolean')fail();
  this.password=arg.password;this.create=arg.create;return {identity:arg.identity,room:arg.room,database:arg.database};
 }
 memoryBytes(){return sodium.libsodium.HEAPU8.length;}
 live(){if(this.dead||sodium.libsodium.HEAPU8.length>128*1024*1024)fail();}
 async open(database,identity,room){
  this.live();if(typeof database!=='string'||!/^family-mls-vault-synthetic-[a-z0-9-]{1,64}$/.test(database))fail();
  this.database=database;this.identity=identity;this.room=room;
  this.db=await new Promise((resolve,reject)=>{
   const q=indexedDB.open(database,1);q.onupgradeneeded=e=>{if(!this.create||e.oldVersion!==0){q.transaction.abort();return;}q.result.createObjectStore('device').add({v:0,identity,room},'state');};
   q.onerror=()=>reject(Error('vault unavailable'));q.onblocked=()=>reject(Error('vault blocked'));
   q.onsuccess=()=>{const d=q.result;if(this.dead||d.objectStoreNames.length!==1||!d.objectStoreNames.contains('device')){d.close();reject(Error('schema'));return;}d.onversionchange=()=>this.close();resolve(d);};
  });return this.db;
 }
 close(){this.dead=true;this.password=null;if(this.root)sodium.memzero(this.root.key);this.root=null;for(const c of this.controllers)c.abort();for(const t of this.transactions){try{t.abort()}catch{}}this.db?.close();}
 async lock(name,fn){
  this.live();if(!navigator.locks)fail();const c=new AbortController();this.controllers.add(c);const timer=setTimeout(()=>c.abort(),15000);
  try{return await navigator.locks.request(name,{mode:'exclusive',signal:c.signal},async()=>{this.live();const result=await fn(()=>{this.live();if(c.signal.aborted)fail();});this.live();if(c.signal.aborted)fail();return result;});}
  finally{clearTimeout(timer);this.controllers.delete(c);}
 }
 read(){return new Promise((resolve,reject)=>{
  this.live();const t=this.db.transaction('device','readonly'),s=t.objectStore('device');this.transactions.add(t);let value;
  t.onabort=()=>{this.transactions.delete(t);reject(Error('read aborted'));};t.oncomplete=()=>{this.transactions.delete(t);resolve(value);};
  const keys=s.getAllKeys(undefined,2);keys.onsuccess=()=>{if(keys.result.length!==1||keys.result[0]!=='state'){t.abort();return;}const q=s.get('state');q.onsuccess=()=>{value=q.result;};};
 });}
 outer(r){
  if(!exact(r,'v,identity,room,vault,revision,capsule,header,cipher')||r.v!==1||r.identity!==this.identity||r.room!==this.room||typeof r.vault!=='string'||!/^[a-f0-9]{32}$/.test(r.vault)||!Number.isSafeInteger(r.revision)||r.revision<1||r.revision>512)fail();
  binary(r.capsule,8192);binary(r.header,24,24);binary(r.cipher,MAX+17,17);
 }
 equal(a,b){
  if(exact(a,'v,identity,room')&&a.v===0)return exact(b,'v,identity,room')&&b.v===0&&a.identity===b.identity&&a.room===b.room;
  this.outer(a);this.outer(b);return ['v','identity','room','vault','revision'].every(k=>a[k]===b[k])&&['capsule','header','cipher'].every(k=>sameBytes(a[k],b[k]));
 }
 aad(revision){return enc.encode(JSON.stringify(['family-native-vault',1,this.database,this.identity,this.room,this.root.id,revision]));}
 async key(record,plain,options){
  if(this.root){if(this.create||record.vault!==this.root.id||record.revision<this.root.seen||!sameBytes(record.capsule,this.root.capsule))fail();return;}
  await this.lock('family-native-vault-kdf',async live=>{
   const password=this.password;if(typeof password!=='string')fail();
   try{
    if(plain){
     const key=sodium.crypto_secretstream_xchacha20poly1305_keygen(),id=hex(sodium.randombytes_buf(16)),pub=options.publicKey(plain);
     try{
      const e=new Encrypter();e.setPassphrase(password);const payload=enc.encode(JSON.stringify([1,this.database,this.identity,this.room,id,pub,Array.from(key)]));let capsule;
      try{capsule=await e.encrypt(payload);}finally{sodium.memzero(payload);}live();
      this.root={key:key.slice(),id,pub,capsule,seen:0};
     }finally{sodium.memzero(key);}
    }else{
     await admit(record.capsule);live();const d=new Decrypter();d.addPassphrase(password);const bytes=await d.decrypt(record.capsule);
     try{
      if(bytes.length>2048)fail();const p=JSON.parse(dec.decode(bytes));
      if(!Array.isArray(p)||p.length!==7||p[0]!==1||p[1]!==this.database||p[2]!==this.identity||p[3]!==this.room||p[4]!==record.vault||typeof p[5]!=='string'||!/^[a-f0-9]{64}$/.test(p[5])||!Array.isArray(p[6])||p[6].length!==32)fail();
      for(let i=0;i<32;i++)if(!Object.hasOwn(p[6],i)||!Number.isInteger(p[6][i])||p[6][i]<0||p[6][i]>255)fail();live();
      this.root={key:new Uint8Array(p[6]),id:p[4],pub:p[5],capsule:record.capsule.slice(),seen:record.revision};
     }finally{sodium.memzero(bytes);}
    }
   }finally{this.password=null;}
  });
 }
 commit(before,after,fault,live){return new Promise((resolve,reject)=>{
  live();const t=this.db.transaction('device','readwrite',{durability:'strict'}),s=t.objectStore('device');this.transactions.add(t);
  t.onabort=()=>{this.transactions.delete(t);reject(Error('candidate conflict or abort'));};t.oncomplete=()=>{this.transactions.delete(t);resolve();};
  const keys=s.getAllKeys(undefined,2);keys.onsuccess=()=>{if(keys.result.length!==1||keys.result[0]!=='state'){t.abort();return;}const q=s.get('state');q.onsuccess=()=>{try{
   live();if(!this.equal(before,q.result)||fault==='abort-before-write')fail();if(after)s.put(after,'state');if(fault==='abort-after-write')fail();
  }catch{t.abort();}};};
 });}
 async tx(directory,operation,fault,options){
  this.live();if(++this.operations>256)fail();
  return this.lock('family-native-vault-state:'+this.database,async live=>{
   const before=await this.read();live();let r,original;
   if(exact(before,'v,identity,room')&&before.v===0&&before.identity===this.identity&&before.room===this.room){
    if(!this.create||operation.kind!=='init'||directory.devices.some(x=>x.actor===this.identity))fail();r=options.initialize();await this.key(null,r,options);
   }else{
    if(this.create)fail();this.outer(before);await this.key(before,null,options);live();
    const state=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,this.root.key),output=sodium.crypto_secretstream_xchacha20poly1305_pull(state,before.cipher,this.aad(before.revision));
    if(!output)fail();try{if(output.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();r=decode(output.message);}finally{sodium.memzero(output.message);}
    options.validate(r);if(options.publicKey(r)!==this.root.pub)fail();original=encode(r);
   }
   options.validate(r);options.current(r,directory);const result=operation(r);options.validate(r,false);r.checksum=options.checksum(r);options.validate(r);
   if(options.publicKey(r)!==this.root.pub)fail();const candidate=encode(r);this.maxSerialized=Math.max(this.maxSerialized,candidate.length);let after=null;
   try{
    if(!original||!sameBytes(candidate,original)){
     const revision=before.v===0?1:before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(this.root.key);
     const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,candidate,this.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
     after={v:1,identity:this.identity,room:this.room,vault:this.root.id,revision,capsule:this.root.capsule.slice(),header,cipher};
    }
    const fresh=await options.admit();live();options.current(r,fresh);await this.commit(before,after,fault,live);live();this.create=false;this.root.seen=(after??before).revision;return result;
   }finally{sodium.memzero(candidate);if(original)sodium.memzero(original);}
  });
 }
}
