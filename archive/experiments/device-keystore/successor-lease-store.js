import {CandidateConfirmationStore,PeerConfirmationStore,validateConfirmation} from './successor-confirmation-store.js';
import {encode,decode,target,wipe,apply,exchangeChecksum} from './successor-exchange-store.js';
import {exact,fail,unhex} from '/trust-directory.js';
import {same,jsonHash,bytes,b64} from '/handshake-wire.js';
import {current,confirmationHTTP} from '/confirmation-wire.js';
import {approval,leaseDigest,leaseHTTP} from '/lease-wire.js';
import {staged_lease_signature} from '/pkg/family_mls_browser_experiment.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
const enc=new TextEncoder();
async function validated(a,e,h,c,role){
 const r=target(a,role),l=r.lease;let view=a;
 if(l){const stripped={...r};delete stripped.lease;view=role==='candidate'?{...stripped,version:a.version-1}:{...a,version:a.version-1,rooms:[a.rooms[0],stripped]};if(role==='candidate'){if(a.checksum!==exchangeChecksum(a))fail();view.checksum=exchangeChecksum(view);}
 if(!exact(l,['version','approval','seen','sent','pending','received'])||l.version!==1||!Array.isArray(l.seen)||!Array.isArray(l.sent)||!Array.isArray(l.received)||l.seen.length>64||l.sent.length>64||l.received.length>64)fail();
 await approval(l.approval,e,h,c);if(l.pending!==null&&(typeof l.pending!=='object'||!l.pending))fail();if(l.approval.role!==role||l.seen.some(x=>typeof x!=='string'||!/^[a-f0-9]{64}$/.test(x)))fail();
 const ids=new Set();for(const x of [...l.sent,...(l.pending?[l.pending]:[])]){if(!exact(x,['id','text_sha256','message'])||ids.has(x.id)||typeof x.id!=='string'||!/^[a-zA-Z0-9_-]{1,64}$/.test(x.id)||!/^[a-f0-9]{64}$/.test(x.text_sha256)||!exact(x.message,['client_id','device_id','payload'])||x.message.client_id!==x.id||x.message.device_id!==e.context[role].device_id||!bytes(x.message.payload,4096).length)fail();ids.add(x.id);}
 let lastSeq=0;for(const x of l.received){if(!exact(x,['seq','text'])||!Number.isInteger(x.seq)||x.seq<1||x.seq>l.seen.length||typeof x.text!=='string'||enc.encode(x.text).length>256||x.seq<=lastSeq)fail();lastSeq=x.seq;}
 }
 const key=validateConfirmation(view,e,h,role),cr=target(view,role).confirmation;if(!cr||!cr.peer_verified||cr.pending!==null||!same(cr.records,c.records))fail();return key;
}
async function transaction(store,e,h,c,role,operation){
 store.live();if(store.create||++store.operations>32)fail();
 return store.lock('family-native-vault-state:'+store.database,async lockLive=>{
 const live=()=>{lockLive();if(Date.now()>=e.context.expires_at*1000)fail();};live();
 const before=await store.read();store.outer(before);let a,original,next;
 try{await store.key(before,null,{});live();const pull=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,store.root.key),out=sodium.crypto_secretstream_xchacha20poly1305_pull(pull,before.cipher,store.aad(before.revision));if(!out)fail();try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=decode(out.message,role);}finally{sodium.memzero(out.message);}
 if(await validated(a,e,h,c,role)!==store.root.pub)fail();original=encode(a,role);const r=target(a,role);
 const remote=await leaseHTTP(store,e,h,c,role,'lease');live();
 if(!r.lease){if(remote.approvals.some(x=>x.role===role))fail();const other=e.context[role==='candidate'?'peer':'candidate'];a.version++;r.lease={version:1,approval:{role,signature:b64(staged_lease_signature(r.crypto,r.identity,other.actor,unhex(other.signing_key),leaseDigest(e,h,c,role)))},seen:[],sent:[],pending:null,received:[]};}
 const l=r.lease;let channelFull=null;for(const x of remote.approvals)if(x.role===role&&!same(x,l.approval))fail();
 if(operation.kind!=='activate'){
 if(remote.phase!=='leased')fail();const history=await leaseHTTP(store,e,h,c,role,'channel');live();channelFull=history.length===64;if(history.length<l.seen.length||l.seen.some((x,i)=>x!==history[i].sha256))fail();
 for(const ev of history.slice(l.seen.length)){
  const q=ev.message;
  if(q.device_id===e.context[role].device_id){const own=l.sent.find(x=>x.id===q.client_id)??l.pending;if(!own||!same(own.message,q))fail();if(l.pending?.id===q.client_id){l.sent.push(l.pending);l.pending=null;}}
  else{const plain=apply(r,e,role,'decrypt_peer',bytes(q.payload,4096));try{const frame=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(plain));if(!Array.isArray(frame)||frame.length!==5||frame[0]!=='family-successor-channel'||frame[1]!==e.reservation_id||frame[2]!==jsonHash(c)||frame[3]!==q.client_id||typeof frame[4]!=='string'||enc.encode(frame[4]).length>256)fail();l.received.push({seq:ev.seq,text:frame[4]});}finally{plain.fill(0);}}
  l.seen.push(ev.sha256);
 }
 if(operation.kind==='send'){
 const {id,text}=operation;const sha=jsonHash(text);const prior=l.sent.find(x=>x.id===id)??(l.pending?.id===id?l.pending:null);
 if(prior){if(prior.text_sha256!==sha)fail();}else{if(l.pending||l.sent.length>=64||channelFull)fail();const plain=enc.encode(JSON.stringify(['family-successor-channel',e.reservation_id,jsonHash(c),id,text]));try{l.pending={id,text_sha256:sha,message:{client_id:id,device_id:e.context[role].device_id,payload:b64(apply(r,e,role,'encrypt',plain))}};}finally{plain.fill(0);}}
 }
 }
 if(role==='candidate')a.checksum=exchangeChecksum(a);if(await validated(a,e,h,c,role)!==store.root.pub)fail();next=encode(a,role);store.maxSerialized=next.length;let after=null;
 if(original.length!==next.length||original.some((x,i)=>x!==next[i])){const revision=before.revision+1;if(revision>512)fail();const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(store.root.key);after={...before,revision,header,cipher:sodium.crypto_secretstream_xchacha20poly1305_push(state,next,store.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)};}
 await current(store,e,role,h);live();const fresh=await confirmationHTTP(store,e,h,role);if(!same(fresh,c))fail();const final=await leaseHTTP(store,e,h,c,role,'lease');live();if(remote.approvals.some(x=>!final.approvals.some(y=>same(x,y))))fail();
 await store.commit(before,after,'',live);live();store.root.seen=(after??before).revision;
 return {committed:true,role,approval:l.approval,pending:l.pending?.message??null,received:l.received,phase:final.phase,channel_full:channelFull,outbox_status:l.pending?(channelFull?'blocked-capacity':'pending'):'empty'};
 }finally{if(original)sodium.memzero(original);if(next)sodium.memzero(next);wipe(a,role);}
 });
}
export class CandidateLeaseStore extends CandidateConfirmationStore {operateLease(e,h,c,op){return transaction(this,e,h,c,'candidate',op);}}
export class PeerLeaseStore extends PeerConfirmationStore {operateLease(e,h,c,op){return transaction(this,e,h,c,'peer',op);}}
export {candidateReservation,reservation} from './successor-confirmation-store.js';
export {validated as validateLease};
