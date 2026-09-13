// Complete native-v4 records inside the new device aggregate. No I/O.
import {validateHistoryState} from './history-state-v4.js';
import {staged_public_key,staged_group_id,staged_check_trust,staged_pending_commit,staged_epoch,staged_checksum} from '/pkg/family_mls_browser_experiment.js';
import {exact,fail,hex,unhex,name,normalizePins} from '/trust-directory.js';
const enc=new TextEncoder(),same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
export const publicKey=r=>hex(staged_public_key(r.crypto,r.identity));
export const checksum=r=>hex(staged_checksum(enc.encode(JSON.stringify([4,r.identity,r.room,r.pins,r.group,r.binding,r.cursor,r.revision,r.epoch,r.phase,r.pending,r.receipts,r.messages,hex(r.crypto)]))));
export function fresh(identity,room,crypto,pins=null){
 const r={version:4,identity,room,pins,group:'',binding:null,cursor:0,revision:0,epoch:0,phase:'unbound',pending:null,receipts:[],messages:[],crypto,checksum:''};
 r.checksum=checksum(r);return r;
}
export function validateRecord(r,identity){
 if(!r||!name(r.room)||r.identity!==identity||!(r.crypto instanceof Uint8Array)||r.crypto.length<1||r.crypto.length>1048576)fail();
 if(r.binding){
  // Reuses the frozen full validator, including accepted-frame/receipt binding.
  validateHistoryState(r,{identity,room:r.room,pins:r.pins,group_id:r.group});
  if(['ack','ready'].includes(r.phase)&&staged_epoch(r.crypto,identity)!==String(r.epoch))fail();
 }else{
  if(!exact(r,['version','identity','room','pins','group','binding','cursor','revision','epoch','phase','pending','receipts','messages','crypto','checksum'])||r.version!==4||r.binding!==null||r.cursor!==0||r.revision!==0||r.epoch!==0||r.phase!=='unbound'||r.pending!==null||!Array.isArray(r.receipts)||r.receipts.length||!Array.isArray(r.messages)||r.messages.length||typeof r.group!=='string'||r.checksum!==checksum(r))fail();
  const group=hex(staged_group_id(r.crypto,identity));
  if(group!==r.group||staged_pending_commit(r.crypto,identity)||(group?staged_epoch(r.crypto,identity)!=='0':staged_epoch(r.crypto,identity)!=='none'))fail();
  if(r.pins===null){if(group)fail();}
  else {
   const pins=normalizePins(r.pins);if(!same(pins,r.pins))fail();const own=pins.find(p=>p.actor===identity),peer=pins.find(p=>p.actor!==identity);
   if(own.signing_key!==publicKey(r))fail();staged_check_trust(r.crypto,identity,peer.actor,unhex(peer.signing_key));
  }
 }
 // Combined quota counts both complete records, rather than granting 2 MiB each.
 let size=r.crypto.length;
 for(const e of r.receipts)size+=atob(e.request.payload).length;
 for(const m of r.messages)size+=atob(m.payload).length;
 if(r.pending){size+=atob(r.pending.request.payload).length;if(r.pending.frame)size+=atob(r.pending.frame.payload).length;}
 return size;
}
export function validateAggregate(a,identity){
 if(!exact(a,['version','identity','primary_room','rooms','fork'])||a.version!==1||a.identity!==identity||!['alice','bob'].includes(identity)||!name(a.primary_room)||!Array.isArray(a.rooms)||a.rooms.length<1||a.rooms.length>2||a.rooms[0].room!==a.primary_room)fail();
 let total=0;const names=new Set(),groups=new Set(),key=publicKey(a.rooms[0]);
 for(const r of a.rooms){total+=validateRecord(r,identity);if(names.has(r.room)||publicKey(r)!==key)fail();names.add(r.room);if(r.group){if(groups.has(r.group))fail();groups.add(r.group);}}
 if(total>2*1024*1024)fail();
 if(a.rooms.length===1){if(a.fork!==null)fail();}
 else {
  const f=a.fork,source=a.rooms[0],target=a.rooms[1];
  if(!exact(f,['id','source','target','source_group','pins'])||!name(f.id)||!f.id.startsWith('context-')||f.source!==source.room||f.target!==target.room||f.source_group!==source.group||!source.binding||!same(normalizePins(f.pins),f.pins)||!same(f.pins,source.pins)||!same(f.pins,target.pins))fail();
 }
 return key;
}
