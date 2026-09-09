// Synthetic device-level custody; old single-room driver/format remain unchanged.
import {NativeVaultStore} from './native-vault-store.js';
import {validateAggregate,fresh,publicKey} from './aggregate-state-v4.js';
import {staged_identity_context} from '/pkg/family_mls_browser_experiment.js';
import {exact,fail,unhex,name,normalizePins,readDirectory,matchDirectory} from '/trust-directory.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
const MAX=4*1024*1024,SCOPE='device-context-v1',enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const b64=b=>{let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);};
const unb64=s=>{if(typeof s!=='string'||s.length>1398104)fail();const b=Uint8Array.from(atob(s),c=>c.charCodeAt(0));if(b.length<1||b.length>1048576||b64(b)!==s)fail();return b;};
function encode(a){const b=enc.encode(JSON.stringify({...a,rooms:a.rooms.map(r=>({...r,crypto:b64(r.crypto)}))}));if(b.length>MAX)fail();return b;}
function decode(bytes){if(bytes.length<1||bytes.length>MAX)fail();const a=JSON.parse(dec.decode(bytes));if(!a||!Array.isArray(a.rooms)||a.rooms.length<1||a.rooms.length>2)fail();for(const r of a.rooms){if(!r)fail();r.crypto=unb64(r.crypto);}return a;}
function wipe(a){if(a?.rooms)for(const r of a.rooms)if(r.crypto instanceof Uint8Array)sodium.memzero(r.crypto);}
export class AggregateStore extends NativeVaultStore {
 outer(record){
  super.outer(record);
  for(const [field,limit] of [['capsule',8192],['header',24],['cipher',MAX+17]])if(record[field].buffer.byteLength>limit)fail();
 }
 async open(database,identity,room){
  this.live();if(typeof database!=='string'||!/^family-mls-device-vault-synthetic-[a-z0-9-]{1,64}$/.test(database)||!['alice','bob'].includes(identity)||!name(room))fail();
  this.database=database;this.identity=identity;this.room=SCOPE;this.selectedRoom=room;
  this.db=await new Promise((resolve,reject)=>{
   const q=indexedDB.open(database,1);q.onupgradeneeded=e=>{if(!this.create||e.oldVersion!==0){q.transaction.abort();return;}q.result.createObjectStore('device').add({v:0,identity,room:SCOPE},'state');};
   q.onerror=()=>reject(Error('device vault unavailable'));q.onblocked=()=>reject(Error('device vault blocked'));
   q.onsuccess=()=>{const d=q.result;if(this.dead||d.objectStoreNames.length!==1||!d.objectStoreNames.contains('device')){d.close();reject(Error('schema'));return;}d.onversionchange=()=>this.close();resolve(d);};
  });return this.db;
 }
 async transaction(initialize,admit,operation,fault=''){
  this.live();if(++this.operations>256)fail();
  return this.lock('family-native-vault-state:'+this.database,async live=>{
   const before=await this.read();live();let a,original,candidate;
   try{
    if(exact(before,['v','identity','room'])&&before.v===0&&before.identity===this.identity&&before.room===SCOPE){
     if(!this.create||!initialize)fail();a=initialize();validateAggregate(a,this.identity);
     await this.key(null,a.rooms[0],{publicKey});
    }else{
     if(this.create)fail();this.outer(before);await this.key(before,null,{publicKey});live();
     const state=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,this.root.key);
     const out=sodium.crypto_secretstream_xchacha20poly1305_pull(state,before.cipher,this.aad(before.revision));if(!out)fail();
     try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=decode(out.message);}finally{sodium.memzero(out.message);}
     if(validateAggregate(a,this.identity)!==this.root.pub)fail();original=encode(a);
    }
    live();await admit(a);live();const result=operation(a);
    if(validateAggregate(a,this.identity)!==this.root.pub)fail();candidate=encode(a);this.maxSerialized=Math.max(this.maxSerialized,candidate.length);
    let after=null;
    if(!original||!candidate.every((v,i)=>v===original[i])||candidate.length!==original.length){
     const revision=before.v===0?1:before.revision+1;if(revision>512)fail();
     const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(this.root.key);
     const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,candidate,this.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
     after={v:1,identity:this.identity,room:SCOPE,vault:this.root.id,revision,capsule:this.root.capsule.slice(),header,cipher};
    }
    await admit(a);live();await this.commit(before,after,fault,live);live();this.create=false;this.root.seen=(after??before).revision;return result;
   }finally{if(candidate)sodium.memzero(candidate);if(original)sodium.memzero(original);wipe(a);}
  });
 }
 async tx(directory,operation,fault,options){
  const selected=a=>{const r=a.rooms.find(r=>r.room===this.selectedRoom);if(!r)fail();return r;};
  const initialize=()=>{
   if(operation.kind!=='init'||directory.devices.some(x=>x.actor===this.identity))fail();
   return {version:1,identity:this.identity,primary_room:this.selectedRoom,rooms:[options.initialize()],fork:null};
  };
  return this.transaction(initialize,async a=>{const r=selected(a);options.validate(r);options.current(r,directory);options.current(r,await options.admit());},a=>{
   const r=selected(a),result=operation(r);options.validate(r,false);r.checksum=options.checksum(r);options.validate(r);return result;
  },fault);
 }
 async fork(arg){
  if(!exact(arg,['id','source','target','source_group','pins'])||!name(arg.id)||!arg.id.startsWith('context-')||!name(arg.source)||!name(arg.target)||arg.source===arg.target||arg.source!==this.selectedRoom||typeof arg.source_group!=='string'||!/^(?:[a-f0-9]{2}){16,128}$/.test(arg.source_group))fail();
  const intent={...arg,pins:normalizePins(arg.pins)};
  return this.transaction(null,async a=>{
   const source=a.rooms[0];if(source.room!==intent.source||!source.binding||source.group!==intent.source_group||!same(source.pins,intent.pins)||(!a.fork&&(source.phase!=='ready'||source.pending?.retired)))fail();
   // No revoked-peer exception: both original and target room admissions apply.
   matchDirectory(intent.pins,await readDirectory(this.identity,intent.source));
   matchDirectory(intent.pins,await readDirectory(this.identity,intent.target));
  },a=>{
   if(a.fork){if(!same(a.fork,intent))fail();}
   else {
    if(a.rooms.length!==1)fail();const source=a.rooms[0],own=source.pins.find(p=>p.actor===this.identity),peer=source.pins.find(p=>p.actor!==this.identity);
    const crypto=staged_identity_context(source.crypto,this.identity,unhex(own.signing_key),unhex(source.group),peer.actor,unhex(peer.signing_key));
    a.rooms.push(fresh(this.identity,intent.target,crypto,normalizePins(intent.pins)));a.fork=intent;
   }
   return {committed:true,room:intent.target,public_key:Array.from(unhex(this.root.pub)),intent_id:intent.id};
  });
 }
}
