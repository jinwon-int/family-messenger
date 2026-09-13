// Read-only validator for the frozen native-v4 archive format. No network or IDB.
// Keep this versioned parser separate from a live transport/worker dispatcher.
import {staged_checksum,staged_public_key,staged_group_id,staged_check_trust,staged_pending_commit} from '/pkg/family_mls_browser_experiment.js';
const exact=(o,keys)=>o&&Object.getPrototypeOf(o)===Object.prototype&&Object.keys(o).sort().join(',')===keys.sort().join(',');
const fail=()=>{throw new Error('rejected');};
const hex=b=>Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
const unhex=s=>new Uint8Array(s.match(/../g).map(x=>parseInt(x,16)));
const name=s=>typeof s==='string'&&/^[a-zA-Z0-9_-]{1,64}$/.test(s);
function validPin(p){
 if(!exact(p,['device_id','actor','signing_key','fingerprint','device_revision'])||!name(p.device_id)||!['alice','bob'].includes(p.actor)||typeof p.signing_key!=='string'||!/^[a-f0-9]{64}$/.test(p.signing_key)||p.device_revision!==1||p.fingerprint!==hex(staged_checksum(unhex(p.signing_key))))fail();
}
export function normalizePins(p){
 if(!Array.isArray(p)||p.length!==2)fail();for(const x of p)validPin(x);
 for(const field of ['device_id','actor','signing_key'])if(new Set(p.map(x=>x[field])).size!==2)fail();
 return p.map(x=>({device_id:x.device_id,actor:x.actor,signing_key:x.signing_key,fingerprint:x.fingerprint,device_revision:x.device_revision})).sort((a,b)=>a.actor.localeCompare(b.actor));
}

export function validateHistoryState(r,expected){
const {identity,room}=expected,enc=new TextEncoder();
const b64=b=>btoa(String.fromCharCode(...b));
function bytes(s,max=65536){if(typeof s!=='string'||s.length>Math.ceil(max/3)*4)fail();const b=Uint8Array.from(atob(s),x=>x.charCodeAt(0));if(b.length>max||b64(b)!==s)fail();return b;}
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const hash=x=>hex(staged_checksum(enc.encode(JSON.stringify(x))));
function input(a){if(!Array.isArray(a)||a.length>8192||a.length===0)fail();for(let i=0;i<a.length;i++)if(!Object.hasOwn(a,i)||!Number.isInteger(a[i])||a[i]<0||a[i]>255)fail();return new Uint8Array(a);}
const reqKeys=['client_id','device_id','group_id','kind','expected_revision','epoch','target_device','payload'];
function requestShape(q){
 if(!exact(q,reqKeys)||!name(q.client_id)||!name(q.device_id)||typeof q.group_id!=='string'||!/^[a-f0-9]{32,256}$/.test(q.group_id)||q.group_id.length%2||!Number.isSafeInteger(q.expected_revision)||q.expected_revision<0||q.expected_revision>256||!Number.isSafeInteger(q.epoch)||q.epoch<0||q.epoch>256||!['key_package','welcome','ack','application','commit'].includes(q.kind)||(q.target_device!==''&&!name(q.target_device)))fail();bytes(q.payload);
 // Canonical Go struct field order for the transport checksum.
 return {client_id:q.client_id,device_id:q.device_id,group_id:q.group_id,kind:q.kind,expected_revision:q.expected_revision,epoch:q.epoch,target_device:q.target_device,payload:q.payload};
}
function eventShape(e){if(!exact(e,['seq','room','request','revision','epoch','sha256'])||!Number.isSafeInteger(e.seq)||e.seq<1||e.seq>256||e.room!==room||!Number.isSafeInteger(e.revision)||e.revision<1||e.revision>256||!Number.isSafeInteger(e.epoch)||e.epoch<0||e.epoch>256||e.sha256!==hash(requestShape(e.request)))fail();return e;}
function frame(id,device,actor,group,type,data){return {version:1,room,group_id:group,client_id:id,sender_actor:actor,sender_device:device,media_type:type,payload:b64(data)};}
function frameShape(f){if(!exact(f,['version','room','group_id','client_id','sender_actor','sender_device','media_type','payload'])||f.version!==1||f.room!==room||!name(f.client_id)||!f.client_id.startsWith('app-')||!['text','file'].includes(f.media_type)||!['alice','bob'].includes(f.sender_actor)||!name(f.sender_device))fail();if(bytes(f.payload,8192).length===0)fail();return f;}
function own(r){return r.pins.find(p=>p.actor===identity)}
function peer(r){return r.pins.find(p=>p.actor!==identity)}
function staticBinding(r,s){
 if(!exact(s,['room','group_id','creator_device','peer_device','pins','revision','epoch','phase','next_seq'])||s.room!==room||typeof s.group_id!=='string'||!/^[a-f0-9]{32,256}$/.test(s.group_id)||s.group_id.length%2||!Array.isArray(s.pins)||s.pins.length!==2||!Number.isSafeInteger(s.revision)||s.revision<0||s.revision>256||!Number.isSafeInteger(s.epoch)||s.epoch<0||s.epoch>256||!Number.isSafeInteger(s.next_seq)||s.next_seq<1||s.next_seq>257||!['key-package','welcome','ack','ready'].includes(s.phase))fail();
 for(const p of s.pins){if(!exact(p,['device_id','actor','signing_key','device_revision']))fail();const pin=r.pins.find(v=>v.device_id===p.device_id);if(!pin||Object.keys(p).some(k=>p[k]!==pin[k]))fail();}
 if(new Set(s.pins.map(x=>x.device_id)).size!==2||s.creator_device!==r.pins.find(p=>p.actor==='alice').device_id||s.peer_device!==r.pins.find(p=>p.actor==='bob').device_id)fail();
 const out={group_id:s.group_id,creator_device:s.creator_device,peer_device:s.peer_device};if(r.binding&&!same(r.binding,out))fail();if(r.group&&r.group!==s.group_id)fail();return out;
}
function checksum(r){return hash([4,r.identity,r.room,r.pins,r.group,r.binding,r.cursor,r.revision,r.epoch,r.phase,r.pending,r.receipts,r.messages,hex(r.crypto)]);}
function validate(r,check=true){
 if(!exact(r,['version','identity','room','pins','group','binding','cursor','revision','epoch','phase','pending','receipts','messages','crypto','checksum'])||r.version!==4||r.identity!==identity||r.room!==room||!(r.crypto instanceof Uint8Array)||!r.crypto.length||r.crypto.length>1048576||!Array.isArray(r.receipts)||r.receipts.length>32||!Array.isArray(r.messages)||r.messages.length>32||r.cursor!==r.receipts.length||!Number.isSafeInteger(r.revision)||r.revision<0||r.revision>32||!Number.isSafeInteger(r.epoch)||r.epoch<0||r.epoch>32||!['unbound','key-package','welcome','ack','ready'].includes(r.phase)||typeof r.group!=='string'||(r.group!==''&&(!/^[a-f0-9]{32,256}$/.test(r.group)||r.group.length%2))||typeof r.checksum!=='string')fail();
 let total=r.crypto.length;
 if(r.pins===null){if(r.group||r.binding||r.pending||r.cursor||r.messages.length||r.phase!=='unbound')fail();}
 else {if(!same(normalizePins(r.pins),r.pins)||own(r).signing_key!==hex(staged_public_key(r.crypto,identity)))fail();staged_check_trust(r.crypto,identity,peer(r).actor,unhex(peer(r).signing_key));}
 const localGroup=hex(staged_group_id(r.crypto,identity));if(localGroup&&localGroup!==r.group)fail();
 if(r.binding){if(!exact(r.binding,['group_id','creator_device','peer_device'])||r.binding.group_id!==r.group||r.binding.creator_device!==r.pins.find(p=>p.actor==='alice').device_id||r.binding.peer_device!==r.pins.find(p=>p.actor==='bob').device_id||r.phase==='unbound')fail();}
 else if(r.cursor||r.pending||r.phase!=='unbound')fail();
 for(let i=0;i<r.receipts.length;i++){const e=eventShape(r.receipts[i]);if(e.seq!==i+1||e.request.group_id!==r.group)fail();total+=bytes(e.request.payload).length;}
 for(const m of r.messages){frameShape(m);if(m.group_id!==r.group)fail();total+=bytes(m.payload,8192).length;}
 if(r.pending!==null){if(!exact(r.pending,['request','frame','retired']))fail();requestShape(r.pending.request);if(r.pending.request.device_id!==own(r).device_id||r.pending.request.group_id!==r.group||typeof r.pending.retired!=='boolean')fail();total+=bytes(r.pending.request.payload).length;if(r.pending.frame!==null){frameShape(r.pending.frame);total+=bytes(r.pending.frame.payload,8192).length;}}
 if(staged_pending_commit(r.crypto,identity)!==(r.pending?.request.kind==='commit'))fail();
 if(total>2*1024*1024)fail();if(check&&r.checksum!==checksum(r))fail();
}

 validate(r);
 const pins=normalizePins(expected.pins);
 if(!same(r.pins,pins)||r.group!==expected.group_id||!r.binding)fail();
 const applications=r.receipts.filter(e=>e.request.kind==='application');
 if(applications.length!==r.messages.length)fail();
 const seen=new Set();
 for(let i=0;i<applications.length;i++){
  const q=applications[i].request,m=r.messages[i],pin=pins.find(p=>p.device_id===q.device_id);
  if(!pin||m.client_id!==q.client_id||m.sender_device!==q.device_id||m.sender_actor!==pin.actor)fail();
  const id=q.device_id+':'+q.client_id;if(seen.has(id))fail();seen.add(id);
 }
 // Only committed frames are returned. Never provider, pending frame, root or receipts.
 return {identity,room,group_id:r.group,pins,cursor:r.cursor,epoch:r.epoch,messages:structuredClone(r.messages)};
}
