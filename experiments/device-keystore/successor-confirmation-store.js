// Candidate v3 / peer aggregate v4 preserve the completed Welcome transcript.
import {CandidateExchangeStore,PeerExchangeStore,validateExchange,exchangeChecksum,encode,decode,target,wipe,apply} from './successor-exchange-store.js';
import {exact,fail} from '/trust-directory.js';
import {same,bytes,request,jsonHash} from '/handshake-wire.js';
import {frame,record,records,transcript,prefix,phases,current,confirmationHTTP} from '/confirmation-wire.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
const enc=new TextEncoder();
function validate(a,e,h,role){
 const r=target(a,role),c=r.confirmation,old=role==='candidate'?2:3;
 if(!c){if(a.version!==old)fail();const key=validateExchange(a,e,role);if(!same(r.handshake.records,h.records)||r.handshake.pending!==null)fail();return key;}
 if(a.version!==old+1)fail();
 const stripped={...r};delete stripped.confirmation;
 let view;if(role==='candidate'){view={...stripped,version:old};view.checksum=exchangeChecksum(view);if(a.checksum!==exchangeChecksum(a))fail();}
 else view={...a,version:old,rooms:[a.rooms[0],stripped]};
 const key=validateExchange(view,e,role);
 if(!same(r.handshake.records,h.records)||r.handshake.pending!==null||!exact(c,['version','role','records','pending','peer_verified'])||c.version!==1||c.role!==role||typeof c.peer_verified!=='boolean'||!same(records(c.records,e,h),c.records))fail();
 const i=c.records.length;
 if(c.pending!==null){if(i!==(role==='candidate'?0:1))fail();record(c.pending,e,h,i);}
 if(role==='candidate'){
  if(c.peer_verified!==(i===2)||(i===0&&c.pending===null))fail();
 }else if(c.peer_verified!==(i>=1)|| (i===1&&c.pending===null))fail();
 if(enc.encode(JSON.stringify(c)).length>16384)fail();return key;
}
function compatible(a,e,h,role,remote){
 const c=target(a,role).confirmation;
 if(!c){if(remote.records.length>(role==='candidate'?0:1))fail();return;}
 prefix(c.records,remote.records);
 if(c.pending&&remote.records.length>c.records.length&&!same(c.pending,remote.records[c.records.length].request))fail();
 // Never reconstruct a missing locally committed sender transition from public data.
 const own=role==='candidate'?0:1;
 if(remote.records.length>own&&c.records.length<=own&&c.pending===null)fail();
}
function equalBytes(a,b){if(a.length!==b.length||a.some((v,i)=>v!==b[i]))fail();}
function advance(a,e,h,role,remote){
 compatible(a,e,h,role,remote);const r=target(a,role);
 if(!r.confirmation){a.version++;r.confirmation={version:1,role,records:[],pending:null,peer_verified:false};}
 const c=r.confirmation;
 if(c.pending&&remote.records.length>c.records.length)c.pending=null;
 if(role==='peer'&&!c.peer_verified&&remote.records.length>=1){
  equalBytes(apply(r,e,role,'decrypt_peer',bytes(remote.records[0].request.payload,4096)),frame(e,h,'candidate'));
  c.peer_verified=true;
  const cipher=apply(r,e,role,'encrypt',frame(e,h,'peer',remote.records[0].sha256));
  c.pending=request(e,'peer_proof',r.handshake.group_id,cipher);
 }
 if(role==='candidate'&&!c.peer_verified&&remote.records.length===2){
  equalBytes(apply(r,e,role,'decrypt_peer',bytes(remote.records[1].request.payload,4096)),frame(e,h,'peer',remote.records[0].sha256));c.peer_verified=true;
 }
 c.records=structuredClone(remote.records);
 if(role==='candidate'&&c.records.length===0&&!c.pending)c.pending=request(e,'candidate_proof',r.handshake.group_id,apply(r,e,role,'encrypt',frame(e,h,'candidate')));
 if(role==='candidate')a.checksum=exchangeChecksum(a);
 return {committed:true,role,peer_verified:c.peer_verified,phase:c.peer_verified?'peer-verified-inactive':phases[c.records.length],transcript_revision:c.records.length,group_id:r.handshake.group_id,pending:c.pending};
}
async function transaction(store,e,h,role,remote){
 remote=transcript(remote,e,h);store.live();if(store.create||++store.operations>32)fail();
 return store.lock('family-native-vault-state:'+store.database,async live=>{
  const before=await store.read();store.outer(before);let a,original,next;
  try{
   await store.key(before,null,{});live();
   const pull=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,store.root.key),out=sodium.crypto_secretstream_xchacha20poly1305_pull(pull,before.cipher,store.aad(before.revision));if(!out)fail();
   try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=decode(out.message,role);}finally{sodium.memzero(out.message);}
   if(validate(a,e,h,role)!==store.root.pub)fail();original=encode(a,role);
   const result=advance(a,e,h,role,remote);if(validate(a,e,h,role)!==store.root.pub)fail();next=encode(a,role);store.maxSerialized=next.length;let after=null;
   if(original.length!==next.length||original.some((v,i)=>v!==next[i])){
    const revision=before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(store.root.key);
    const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,next,store.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);after={...before,revision,header,cipher};
   }
   await current(store,e,role,h);live();const fresh=await confirmationHTTP(store,e,h,role);live();prefix(remote.records,fresh.records);compatible(a,e,h,role,fresh);
   await store.commit(before,after,'',live);live();store.root.seen=(after??before).revision;return result;
  }finally{if(original)sodium.memzero(original);if(next)sodium.memzero(next);wipe(a,role);}
 });
}
export class CandidateConfirmationStore extends CandidateExchangeStore {confirm(e,h,r){return transaction(this,e,h,'candidate',r);}}
export class PeerConfirmationStore extends PeerExchangeStore {confirm(e,h,r){return transaction(this,e,h,'peer',r);}}
export {candidateReservation,reservation} from './successor-exchange-store.js';
