// Explicit protected candidate v2 / peer aggregate v3. Original stores unchanged.
import {CandidateStore} from './candidate-store.js';
import {SuccessorPeerStore} from './successor-peer-store.js';
import {validatePeer} from './successor-peer-state.js';
import {validateRecord} from './aggregate-state-v4.js';
import {exact,fail,hex,unhex} from '/trust-directory.js';
import {same,hash,b64,bytes,request,record,records,prefix,phases,transcript,handshakeHTTP} from '/handshake-wire.js';
import {staged_public_key,staged_group_id,staged_epoch,staged_check_trust,staged_trusted_apply,staged_identity_context,verify_device_package} from '/pkg/family_mls_browser_experiment.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true}),MAX=4*1024*1024;
const pub=r=>hex(staged_public_key(r.crypto,r.identity));
const checksum=r=>hash(enc.encode(JSON.stringify({...r,crypto:b64(r.crypto),checksum:''})));
function encode(a,role){const b=enc.encode(JSON.stringify(role==='candidate'?{...a,crypto:b64(a.crypto)}:{...a,rooms:a.rooms.map(r=>({...r,crypto:b64(r.crypto)}))}));if(b.length>MAX)fail();return b;}
function decode(b,role){if(!b.length||b.length>MAX)fail();const a=JSON.parse(dec.decode(b));if(role==='candidate')a.crypto=bytes(a.crypto,1048576);else{if(!Array.isArray(a.rooms)||a.rooms.length!==2)fail();for(const r of a.rooms)r.crypto=bytes(r.crypto,1048576);}return a;}
function target(a,role){return role==='candidate'?a:a.rooms[1];}
function wipe(a,role){for(const r of role==='candidate'?[a]:a?.rooms??[])r?.crypto?.fill(0);}
function state(r,e,role){
 const h=r.handshake,c=e.context,other=c[role==='candidate'?'peer':'candidate'];
 if(!exact(h,['version','role','group_id','records','pending'])||h.version!==1||h.role!==role||typeof h.group_id!=='string'||!same(records(h.records,e),h.records))fail();
 if(h.pending!==null){const index=h.records.length;if(index>2||(role==='peer'?index!==1:![0,2].includes(index)))fail();record(h.pending,e,index);if(index===2&&h.pending.group_id!==h.group_id)fail();}
 const g=hex(staged_group_id(r.crypto,r.identity));if(g!==h.group_id||pub(r)!==c[role].signing_key)fail();
 if(g){
  if(g===c.source_group||staged_epoch(r.crypto,r.identity)!=='1')fail();staged_check_trust(r.crypto,r.identity,other.actor,unhex(other.signing_key));
  const welcome=h.records[1]?.request??(role==='peer'?h.pending:null);if(!welcome||welcome.kind!=='welcome'||welcome.group_id!==g)fail();
 }else if(staged_epoch(r.crypto,r.identity)!=='none'||h.records.length>(role==='peer'?0:1)||(role==='peer'&&h.pending!==null))fail();
 return h;
}
function validate(a,e,role){
 const c=e.context;
 if(role==='candidate'){
  const keys=['version','identity','crypto','package','package_sha256','binding','checksum'];if(a.version===2)keys.push('handshake');
  if(!exact(a,keys)||![1,2].includes(a.version)||a.identity!==c.candidate.actor||!(a.crypto instanceof Uint8Array)||!a.crypto.length||a.crypto.length>1048576||typeof a.package!=='string'||!/^(?:[a-f0-9]{2}){1,65536}$/.test(a.package)||a.package_sha256!==c.package_sha256||hash(unhex(a.package))!==c.package_sha256||!same(a.binding,e)||pub(a)!==c.candidate.signing_key||a.checksum!==checksum(a))fail();
  verify_device_package(unhex(a.package),a.identity,unhex(c.candidate.signing_key));
  if(a.version===1){if(staged_group_id(a.crypto,a.identity).length)fail();}else state(a,e,role);
  return pub(a);
 }
 if(a.version===2)return validatePeer(a,c.peer.actor,e);
 if(!exact(a,['version','identity','primary_room','rooms','successor'])||a.version!==3||a.identity!==c.peer.actor||a.primary_room!==c.source_room||!Array.isArray(a.rooms)||a.rooms.length!==2||!same(a.successor,e))fail();
 const source=a.rooms[0],r=a.rooms[1];
 const key=validatePeer({version:1,identity:a.identity,primary_room:a.primary_room,rooms:[source],fork:null},a.identity,e);
 if(!exact(r,['version','identity','room','crypto','handshake'])||r.version!==1||r.identity!==a.identity||r.room!==c.target_room||!(r.crypto instanceof Uint8Array)||!r.crypto.length||r.crypto.length>1048576)fail();
 const h=state(r,e,role);if(validateRecord(source,a.identity)+r.crypto.length+enc.encode(JSON.stringify(h)).length>2*1024*1024)fail();
 if(!h.group_id){const expected=staged_identity_context(source.crypto,a.identity,unhex(c.peer.signing_key),unhex(c.source_group),c.predecessor.actor,unhex(c.predecessor.signing_key));try{if(expected.length!==r.crypto.length||expected.some((v,i)=>v!==r.crypto[i]))fail();}finally{expected.fill(0);}}
 return key;
}
function compatible(a,e,role,remote){
 const r=target(a,role),h=r.handshake;
 if(!h){if(role==='peer'&&remote.records.length>=2)fail();return;}
 prefix(h.records,remote.records);
 if(h.pending&&remote.records.length>h.records.length&&!same(h.pending,remote.records[h.records.length].request))fail();
 if(role==='peer'&&!h.group_id&&remote.records.length>=2)fail();
}
function apply(r,e,role,method,input){
 const other=e.context[role==='candidate'?'peer':'candidate'];let t;
 try{t=staged_trusted_apply(r.crypto,r.identity,method,input,other.actor,unhex(other.signing_key));const old=r.crypto;r.crypto=t.state();old.fill(0);return t.output();}finally{t?.free();}
}
function advance(a,e,role,remote){
 compatible(a,e,role,remote);
 if(role==='candidate'&&a.version===1){a.version=2;a.handshake={version:1,role,group_id:'',records:[],pending:null};}
 if(role==='peer'&&a.version===2){const r=a.rooms[1];a.version=3;a.rooms[1]={version:1,identity:r.identity,room:r.room,crypto:r.crypto,handshake:{version:1,role,group_id:'',records:[],pending:null}};}
 const r=target(a,role),h=r.handshake;
 if(h.pending&&remote.records.length>h.records.length)h.pending=null;
 if(role==='candidate'&&!h.group_id&&remote.records.length>=2){
  apply(r,e,role,'join',bytes(remote.records[1].request.payload));h.group_id=hex(staged_group_id(r.crypto,r.identity));if(h.group_id!==remote.records[1].request.group_id)fail();
 }
 h.records=structuredClone(remote.records);
 if(!h.pending){
  if(role==='candidate'&&h.records.length===0)h.pending=request(e,'key_package','',unhex(a.package));
  else if(role==='candidate'&&h.records.length===2)h.pending=request(e,'ack',h.group_id,new Uint8Array());
  else if(role==='peer'&&h.records.length===1){
   apply(r,e,role,'create',new Uint8Array());const welcome=apply(r,e,role,'invite',bytes(h.records[0].request.payload));h.group_id=hex(staged_group_id(r.crypto,r.identity));h.pending=request(e,'welcome',h.group_id,welcome);
  }
 }
 if(role==='candidate')a.checksum=checksum(a);
 return {committed:true,role,phase:h.pending?h.pending.kind+'-prepared':phases[h.records.length],group_id:h.group_id,transcript_revision:h.records.length,pending:h.pending};
}
async function transaction(store,e,role,remote){
 remote=transcript(remote,e);store.live();if(store.create||++store.operations>32)fail();
 return store.lock('family-native-vault-state:'+store.database,async live=>{
  const before=await store.read();store.outer(before);let a,original,next;
  try{
   await store.key(before,null,{});live();
   const pull=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,store.root.key),out=sodium.crypto_secretstream_xchacha20poly1305_pull(pull,before.cipher,store.aad(before.revision));if(!out)fail();
   try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=decode(out.message,role);}finally{sodium.memzero(out.message);}
   if(validate(a,e,role)!==store.root.pub)fail();original=encode(a,role);
   const result=advance(a,e,role,remote);if(validate(a,e,role)!==store.root.pub)fail();next=encode(a,role);store.maxSerialized=next.length;
   let after=null;
   if(original.length!==next.length||original.some((v,i)=>v!==next[i])){
    const revision=before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(store.root.key);
    const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,next,store.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);after={...before,revision,header,cipher};
   }
   const fresh=await handshakeHTTP(store,e,role);live();prefix(remote.records,fresh.records);compatible(a,e,role,fresh);
   await store.commit(before,after,'',live);live();store.root.seen=(after??before).revision;return result;
  }finally{if(original)sodium.memzero(original);if(next)sodium.memzero(next);wipe(a,role);}
 });
}
export class CandidateExchangeStore extends CandidateStore {advance(e,remote){return transaction(this,e,'candidate',remote);}}
export class PeerExchangeStore extends SuccessorPeerStore {advance(e,remote){return transaction(this,e,'peer',remote);}}

export {candidateReservation} from './candidate-store.js';
export {reservation} from './successor-peer-store.js';

// Shared strict decoding/validation for the explicitly selected next format.
export {validate as validateExchange,checksum as exchangeChecksum,encode,decode,target,wipe,apply};
