// Candidate v7 / peer v8 close persistent targets and freeze all enrolled custody.
import {CandidateEnrollmentStore,PeerEnrollmentStore,enrollmentEncode,enrollmentDecode,validateEnrollment} from './successor-enrollment-store.js';
import {target,wipe,exchangeChecksum} from './successor-exchange-store.js';
import {exact,fail,unhex} from '/trust-directory.js';
import {same,b64} from '/handshake-wire.js';
import {closureApproval,closureDigest,closureHTTP,closurePrefix} from '/closure-wire.js';
import {staged_lease_signature} from '/pkg/family_mls_browser_experiment.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
async function validate(a,e,v,role){
 const r=target(a,role),t=r.closure;let view=a;
 if(t){
  if(!exact(t,['version','request','receipt'])||t.version!==1||(t.request===null&&t.receipt===null))fail();
  if(t.request!==null){await closureApproval(t.request,e,v);if(t.request.role!==role)fail();}
  if(t.receipt!==null){await closureApproval(t.receipt,e,v);if(!same(t.receipt,v.closure))fail();}
  if(a.version!==(role==='candidate'?7:8))fail();const stripped={...r};delete stripped.closure;view=role==='candidate'?{...stripped,version:a.version-1}:{...a,version:a.version-1,rooms:[a.rooms[0],stripped]};
  if(role==='candidate'){if(a.checksum!==exchangeChecksum(a))fail();view.checksum=exchangeChecksum(view);}
 }
 if(!target(view,role).enrollment)fail();return validateEnrollment(view,e,{version:1,enrollment:v.enrollment,handshake:v.handshake,confirmation:v.confirmation,active:true},role);
}
async function transaction(store,e,role,kind){
 store.live();if(store.create||++store.operations>8)fail();
 return store.lock('family-native-vault-state:'+store.database,async lockLive=>{
  const before=await store.read();store.outer(before);let a,original,next;
  try{
   await store.key(before,null,{});lockLive();const pull=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,store.root.key),out=sodium.crypto_secretstream_xchacha20poly1305_pull(pull,before.cipher,store.aad(before.revision));if(!out)fail();
   try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=enrollmentDecode(out.message,role);}finally{sodium.memzero(out.message);}
   const remote=await closureHTTP(store,e,role);lockLive();if(await validate(a,e,remote,role)!==store.root.pub)fail();original=enrollmentEncode(a,role);const r=target(a,role);
   if(!r.closure){
    if(remote.closure===null&&kind!=='close')fail();
    const t={version:1,request:null,receipt:remote.closure};
    if(remote.closure===null){
     const other=e.context[role==='candidate'?'peer':'candidate'];
     t.request={role,signature:b64(staged_lease_signature(r.enrollment.crypto,r.identity,other.actor,unhex(other.signing_key),closureDigest(remote,role)))};
    }
    a.version++;r.closure=t;
   }else if(remote.closure!==null)r.closure.receipt=remote.closure;
   if(role==='candidate')a.checksum=exchangeChecksum(a);if(await validate(a,e,remote,role)!==store.root.pub)fail();next=enrollmentEncode(a,role);store.maxSerialized=next.length;let after=null;
   if(original.length!==next.length||original.some((x,i)=>x!==next[i])){const revision=before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(store.root.key);after={...before,revision,header,cipher:sodium.crypto_secretstream_xchacha20poly1305_push(state,next,store.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)};}
   const live=()=>lockLive();
   const fresh=await closureHTTP(store,e,role);closurePrefix(remote,fresh);live();
   // Commit before any signed closure request can leave this worker. Keep
   // full original sender state/outbox and data, including blocked pending sends.
   await store.commit(before,after,'',live);live();store.root.seen=(after??before).revision;
   return {committed:true,local_closed:true,server_closed:r.closure.receipt!==null,request:r.closure.request,receipt:r.closure.receipt};
  }finally{if(original)sodium.memzero(original);if(next)sodium.memzero(next);a&&target(a,role)?.enrollment?.crypto?.fill(0);wipe(a,role);}
 });
}
export class CandidateClosureStore extends CandidateEnrollmentStore {closeTarget(e,kind){return transaction(this,e,'candidate',kind);}}
export class PeerClosureStore extends PeerEnrollmentStore {closeTarget(e,kind){return transaction(this,e,'peer',kind);}}
export {candidateReservation,reservation} from './successor-lease-store.js';
