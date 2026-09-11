// Candidate v6 / peer v7 freeze the complete former lease. Only a separate
// enrolled provider copy advances; no retired v5/v6 or pending sender is promoted.
import {CandidateLeaseStore,PeerLeaseStore,validateLease} from './successor-lease-store.js';
import {encode,decode,target,wipe,apply,exchangeChecksum} from './successor-exchange-store.js';
import {exact,fail,unhex} from '/trust-directory.js';
import {same,jsonHash,bytes,b64} from '/handshake-wire.js';
import {enrollmentApproval,enrollmentDigest,enrollmentHTTP,enrollmentPrefix} from '/enrollment-wire.js';
import {staged_lease_signature} from '/pkg/family_mls_browser_experiment.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
const enc=new TextEncoder();
function view(a,role,r,version){return role==='candidate'?{...r,version}:{...a,version,rooms:[a.rooms[0],r]};}
function serialize(a,role){const r=target(a,role);return encode(r.enrollment?view(a,role,{...r,enrollment:{...r.enrollment,crypto:b64(r.enrollment.crypto)}},a.version):a,role);}
function deserialize(raw,role){const a=decode(raw,role),n=target(a,role).enrollment;if(n)n.crypto=bytes(n.crypto,1048576);return a;}
async function validate(a,e,v,role){
 const r=target(a,role),n=r.enrollment;let prior=a;
 if(n){
  if(!exact(n,['version','approval','crypto','approvals','seen','sent','pending','received'])||n.version!==1||!(n.crypto instanceof Uint8Array)||!n.crypto.length||!Array.isArray(n.approvals)||n.approvals.length>2)fail();
  if(a.version!==(role==='candidate'?6:7))fail();if(role==='candidate'&&a.checksum!==exchangeChecksum(a))fail();
  await enrollmentApproval(n.approval,e,v);if(n.approval.role!==role)fail();let last='';for(const q of n.approvals){await enrollmentApproval(q,e,v);if(q.role<=last||!v.enrollment.approvals.some(x=>same(x,q)))fail();last=q.role;}
  const stripped={...r};delete stripped.enrollment;prior=view(a,role,stripped,a.version-2);if(role==='candidate')prior.checksum=exchangeChecksum(prior);
 }
 const l=target(prior,role).lease;if(!l||l.pending!==null||l.seen.length||l.sent.length||l.received.length)fail();
 const key=await validateLease(prior,e,v.handshake,v.confirmation,role);
 if(n){const active={...target(prior,role),crypto:n.crypto,lease:{...l,seen:n.seen,sent:n.sent,pending:n.pending,received:n.received}},live=view(prior,role,active,prior.version);if(role==='candidate')live.checksum=exchangeChecksum(live);if(await validateLease(live,e,v.handshake,v.confirmation,role)!==key)fail();}
 return key;
}
function advance(r,e,role,method,input){const n=r.enrollment,tmp={identity:r.identity,crypto:n.crypto};const out=apply(tmp,e,role,method,input);n.crypto=tmp.crypto;return out;}
async function transaction(store,e,role,operation){
 store.live();if(store.create||++store.operations>32)fail();
 return store.lock('family-native-vault-state:'+store.database,async lockLive=>{
  const before=await store.read();store.outer(before);let a,original,next;
  try{
   await store.key(before,null,{});lockLive();const pull=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,store.root.key),out=sodium.crypto_secretstream_xchacha20poly1305_pull(pull,before.cipher,store.aad(before.revision));if(!out)fail();
   try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=deserialize(out.message,role);}finally{sodium.memzero(out.message);}
   const remote=await enrollmentHTTP(store,e,role);lockLive();if(await validate(a,e,remote,role)!==store.root.pub)fail();original=serialize(a,role);const r=target(a,role);let authoring=false;
   if(!r.enrollment){
    if(operation.kind!=='enroll'||Date.now()>=e.context.expires_at*1000||remote.enrollment.approvals.some(q=>q.role===role))fail();authoring=true;const other=e.context[role==='candidate'?'peer':'candidate'];
    a.version+=2;r.enrollment={version:1,approval:{role,signature:b64(staged_lease_signature(r.crypto,r.identity,other.actor,unhex(other.signing_key),enrollmentDigest(remote,role)))},crypto:r.crypto.slice(),approvals:[],seen:[],sent:[],pending:null,received:[]};
   }
   const n=r.enrollment;for(const q of remote.enrollment.approvals)if(q.role===role&&!same(q,n.approval))fail();n.approvals=structuredClone(remote.enrollment.approvals);let full=null;
   if(['send','sync'].includes(operation.kind)){
    if(!remote.active||n.approvals.length!==2)fail();const history=await enrollmentHTTP(store,e,role,'enrolled-channel');lockLive();full=history.length===64;if(history.length<n.seen.length||n.seen.some((x,i)=>x!==history[i].sha256))fail();
    for(const ev of history.slice(n.seen.length)){
     const q=ev.message;if(q.device_id===e.context[role].device_id){const own=n.sent.find(x=>x.id===q.client_id)??n.pending;if(!own||!same(own.message,q))fail();if(n.pending?.id===q.client_id){n.sent.push(n.pending);n.pending=null;}}
     else{const plain=advance(r,e,role,'decrypt_peer',bytes(q.payload,4096));try{const f=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(plain));if(!Array.isArray(f)||f.length!==5||f[0]!=='family-successor-enrolled-channel'||f[1]!==e.reservation_id||f[2]!==jsonHash(remote.enrollment)||f[3]!==q.client_id||typeof f[4]!=='string'||enc.encode(f[4]).length>256)fail();n.received.push({seq:ev.seq,text:f[4]});}finally{plain.fill(0);}}
     n.seen.push(ev.sha256);
    }
    if(operation.kind==='send'){
     const {id,text}=operation,sha=jsonHash(text),prior=n.sent.find(x=>x.id===id)??(n.pending?.id===id?n.pending:null);
     if(prior){if(prior.text_sha256!==sha)fail();}else{if(n.pending||n.sent.length>=64||full)fail();const plain=enc.encode(JSON.stringify(['family-successor-enrolled-channel',e.reservation_id,jsonHash(remote.enrollment),id,text]));try{n.pending={id,text_sha256:sha,message:{client_id:id,device_id:e.context[role].device_id,payload:b64(advance(r,e,role,'encrypt',plain))}};}finally{plain.fill(0);}}
    }
   }
   if(role==='candidate')a.checksum=exchangeChecksum(a);if(await validate(a,e,remote,role)!==store.root.pub)fail();next=serialize(a,role);store.maxSerialized=next.length;let after=null;
   if(original.length!==next.length||original.some((x,i)=>x!==next[i])){const revision=before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(store.root.key);after={...before,revision,header,cipher:sodium.crypto_secretstream_xchacha20poly1305_push(state,next,store.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)};}
   const fresh=await enrollmentHTTP(store,e,role);enrollmentPrefix(remote,fresh);const live=()=>{lockLive();if(authoring&&Date.now()>=e.context.expires_at*1000)fail();};live();
   await store.commit(before,after,'',live);live();store.root.seen=(after??before).revision;
   return {committed:true,approval:n.approval,own_declared:remote.enrollment.approvals.some(q=>same(q,n.approval)),pair_declared:n.approvals.length===2,active:remote.active,approval_sha256:n.approvals.length===2?jsonHash(remote.enrollment):null,pending:n.pending?.message??null,received:n.received,channel_full:full,outbox_status:n.pending?(full?'blocked-capacity':'pending'):'empty'};
  }finally{if(original)sodium.memzero(original);if(next)sodium.memzero(next);a&&target(a,role)?.enrollment?.crypto?.fill(0);wipe(a,role);}
 });
}
export class CandidateEnrollmentStore extends CandidateLeaseStore {enroll(e,op){return transaction(this,e,'candidate',op);}}
export class PeerEnrollmentStore extends PeerLeaseStore {enroll(e,op){return transaction(this,e,'peer',op);}}
export {candidateReservation,reservation} from './successor-lease-store.js';
