// Inactive generated proposal custody only. No native sender or enrollment.
import {NativeVaultStore} from './native-vault-store.js';
import {reservation,same} from './successor-peer-state.js';
import {exact,fail,hex,unhex} from '/trust-directory.js';
import {staged_init,staged_apply,staged_public_key,staged_group_id,staged_checksum,verify_device_package} from '/pkg/family_mls_browser_experiment.js';
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true}),scope='candidate-proposal-v1';
const hash=b=>hex(staged_checksum(b));
const b64=b=>{let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);};
const checksum=r=>hash(enc.encode(JSON.stringify({...r,crypto:b64(r.crypto),checksum:''})));
export function candidateReservation(value,identity){
 if(!['alice','bob'].includes(identity)||value?.context?.candidate?.actor!==identity)fail();
 // Preserve the existing peer validator and its role restriction. Candidate
 // admission is a separate check, never an ordinary active-device directory.
 return reservation(value,value.context.peer?.actor);
}
function publicKey(r){return hex(staged_public_key(r.crypto,r.identity));}
function validate(r,check=true){
 if(!exact(r,['version','identity','crypto','package','package_sha256','binding','checksum'])||r.version!==1||!['alice','bob'].includes(r.identity)||!(r.crypto instanceof Uint8Array)||r.crypto.length<1||r.crypto.length>1048576||typeof r.package!=='string'||!/^(?:[a-f0-9]{2}){1,65536}$/.test(r.package)||typeof r.checksum!=='string')fail();
 const key=publicKey(r),bytes=unhex(r.package);
 if(staged_group_id(r.crypto,r.identity).length!==0||hash(bytes)!==r.package_sha256)fail();
 verify_device_package(bytes,r.identity,unhex(key));
 if(r.binding!==null){const e=candidateReservation(r.binding,r.identity);if(!same(e,r.binding)||e.context.candidate.signing_key!==key||e.context.package_sha256!==r.package_sha256)fail();}
 if(check&&checksum(r)!==r.checksum)fail();return key;
}
function initialize(identity){
 const initial=staged_init(identity);let t;
 try{
  t=staged_apply(initial,identity,'key_package',new Uint8Array());
  const r={version:1,identity,crypto:t.state(),package:hex(t.output()),package_sha256:hash(t.output()),binding:null,checksum:''};
  r.checksum=checksum(r);validate(r);return r;
 }finally{initial.fill(0);t?.free();}
}
export class CandidateStore extends NativeVaultStore {
 async open(database,identity){
  this.live();if(!['alice','bob'].includes(identity)||typeof database!=='string'||!/^family-mls-candidate-synthetic-[a-z0-9-]{1,64}$/.test(database))fail();
  this.database=database;this.identity=identity;this.room=scope;
  this.db=await new Promise((resolve,reject)=>{
   const q=indexedDB.open(database,1);
   q.onupgradeneeded=e=>{if(!this.create||e.oldVersion!==0){q.transaction.abort();return;}q.result.createObjectStore('device').add({v:0,identity,room:scope},'state');};
   q.onerror=()=>reject(Error('candidate unavailable'));q.onblocked=()=>reject(Error('candidate blocked'));
   q.onsuccess=()=>{const d=q.result;if(this.dead||d.objectStoreNames.length!==1||!d.objectStoreNames.contains('device')){d.close();reject(Error('candidate schema'));return;}d.onversionchange=()=>this.close();resolve(d);};
  });return this.db;
 }
 async admission(expected){
  this.live();if(expected&&expected.context.expires_at*1000<=Date.now())fail();
  const controller=new AbortController();this.controllers.add(controller);const timer=setTimeout(()=>controller.abort(),5000);
  try{
   const headers={'X-Family-Actor':this.identity};if(expected)headers['X-Family-Device']=expected.context.candidate.device_id;
   const path=expected?'/v1/mls/successors/'+expected.context.intent_id+'/reservation':'/v1/session';
   const response=await fetch(path,{credentials:'same-origin',cache:'no-store',redirect:'error',headers,signal:controller.signal});
   if(!response.ok||response.headers.get('X-Family-Actor')!==this.identity)fail();
   const reader=response.body.getReader();let n=0,parts=[];
   for(;;){const {done,value}=await reader.read();if(done)break;n+=value.length;if(n>4096)fail();parts.push(value);}
   const raw=new Uint8Array(n);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
   const value=JSON.parse(dec.decode(raw));
   if(expected){if(!same(candidateReservation(value,this.identity),expected)||expected.context.expires_at*1000<=Date.now())fail();}
   else if(!exact(value,['mode','actor','owner'])||value.mode!=='signed'||value.actor!==this.identity||typeof value.owner!=='boolean')fail();
   this.live();return {devices:[],expected};
  }finally{controller.abort();clearTimeout(timer);this.controllers.delete(controller);}
 }
 async operate(expected){
  if(expected&&this.create)fail();
  const directory=await this.admission(expected);let privateRecord;
  const current=(r,d)=>{
   if(r.identity!==this.identity)fail();
   const e=d.expected;
   if(e){if(e.context.candidate.signing_key!==publicKey(r)||e.context.package_sha256!==r.package_sha256||(r.binding!==null&&!same(r.binding,e)))fail();}
   else if(r.binding!==null)fail();
  };
  const operation=r=>{
   privateRecord=r;
   if(expected)r.binding=expected;
   return {committed:true,phase:expected?'inactive-candidate-custody':'unassigned-proposal',public_key:publicKey(r),package:r.package,package_sha256:r.package_sha256,reservation_id:expected?.reservation_id??null};
  };
  operation.kind='init';
  try{return await this.tx(directory,operation,'',{initialize:()=>{privateRecord=initialize(this.identity);return privateRecord;},publicKey,validate,checksum,current,admit:()=>this.admission(expected)});}
  finally{privateRecord?.crypto.fill(0);}
 }
}
