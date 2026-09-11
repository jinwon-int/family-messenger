// Candidate v5 / peer v6 are terminal: older workers reject these formats.
import {CandidateLeaseStore,PeerLeaseStore,validateLease} from './successor-lease-store.js';
import {encode,decode,target,wipe,exchangeChecksum} from './successor-exchange-store.js';
import {exact,fail,unhex} from '/trust-directory.js';
import {same,b64} from '/handshake-wire.js';
import {retirementApproval,retirementDigest,retirementHTTP,retirementPrefix} from '/retirement-wire.js';
import {staged_lease_signature} from '/pkg/family_mls_browser_experiment.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
async function validate(a,e,v,role){
 const r=target(a,role),t=r.retirement;let view=a;
 if(t){
  if(!exact(t,['version','request','receipt'])||t.version!==1||(t.request===null&&t.receipt===null))fail();
  if(t.request!==null){await retirementApproval(t.request,e,v);if(t.request.role!==role)fail();}
  if(t.receipt!==null){await retirementApproval(t.receipt,e,v);if(!same(t.receipt,v.retirement))fail();}
  const stripped={...r};delete stripped.retirement;view=role==='candidate'?{...stripped,version:a.version-1}:{...a,version:a.version-1,rooms:[a.rooms[0],stripped]};
  if(role==='candidate'){if(a.checksum!==exchangeChecksum(a))fail();view.checksum=exchangeChecksum(view);}
 }
 if(!target(view,role).lease)fail();return validateLease(view,e,v.handshake,v.confirmation,role);
}
async function transaction(store,e,role,kind){
 store.live();if(store.create||++store.operations>8)fail();
 return store.lock('family-native-vault-state:'+store.database,async lockLive=>{
  const before=await store.read();store.outer(before);let a,original,next;
  try{
   await store.key(before,null,{});lockLive();const pull=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,store.root.key),out=sodium.crypto_secretstream_xchacha20poly1305_pull(pull,before.cipher,store.aad(before.revision));if(!out)fail();
   try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=decode(out.message,role);}finally{sodium.memzero(out.message);}
   const remote=await retirementHTTP(store,e,role);lockLive();if(await validate(a,e,remote,role)!==store.root.pub)fail();original=encode(a,role);const r=target(a,role);let authoring=false;
   if(!r.retirement){
    if(remote.retirement===null&&kind!=='retire')fail();
    const t={version:1,request:null,receipt:remote.retirement};
    if(remote.retirement===null){
     if(Date.now()>=e.context.expires_at*1000)fail();authoring=true;const other=e.context[role==='candidate'?'peer':'candidate'];
     t.request={role,signature:b64(staged_lease_signature(r.crypto,r.identity,other.actor,unhex(other.signing_key),retirementDigest(remote,role)))};
    }
    a.version++;r.retirement=t;
   }else if(remote.retirement!==null)r.retirement.receipt=remote.retirement;
   if(role==='candidate')a.checksum=exchangeChecksum(a);if(await validate(a,e,remote,role)!==store.root.pub)fail();next=encode(a,role);store.maxSerialized=next.length;let after=null;
   if(original.length!==next.length||original.some((x,i)=>x!==next[i])){const revision=before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(store.root.key);after={...before,revision,header,cipher:sodium.crypto_secretstream_xchacha20poly1305_push(state,next,store.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)};}
   const live=()=>{lockLive();if(authoring&&Date.now()>=e.context.expires_at*1000)fail();};
   const fresh=await retirementHTTP(store,e,role);retirementPrefix(remote,fresh);live();
   // Commit before any signed retirement request can leave this worker. Keep
   // full original sender state/outbox and data, including blocked pending sends.
   await store.commit(before,after,'',live);live();store.root.seen=(after??before).revision;
   return {committed:true,local_retired:true,server_retired:r.retirement.receipt!==null,request:r.retirement.request,receipt:r.retirement.receipt};
  }finally{if(original)sodium.memzero(original);if(next)sodium.memzero(next);wipe(a,role);}
 });
}
export class CandidateRetirementStore extends CandidateLeaseStore {retire(e,kind){return transaction(this,e,'candidate',kind);}}
export class PeerRetirementStore extends PeerLeaseStore {retire(e,kind){return transaction(this,e,'peer',kind);}}
export {candidateReservation,reservation} from './successor-lease-store.js';
