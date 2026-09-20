// Expired intents permit only observation, never retirement POST or delivery.
import {exact,fail,unhex} from './trust-directory.js';
import {transcript as handshake,same,jsonHash,bytes,b64} from './handshake-wire.js';
import {transcript as confirmation} from './confirmation-wire.js';
import {lease} from './lease-wire.js';
export function retirementDigest(v,role){const l=v.lease;return unhex(jsonHash(['family-successor-retirement',1,role,l.reservation_id,l.context_sha256,l.handshake_sha256,l.confirmation_sha256,l.group_id,l.expires_at]));}
export async function retirementApproval(q,e,v){
 if(!exact(q,['role','signature'])||!['candidate','peer'].includes(q.role))fail();const sig=bytes(q.signature,64);if(sig.length!==64)fail();
 const prefix=new TextEncoder().encode('family-successor-lease-v1\0'),input=new Uint8Array(prefix.length+32);input.set(prefix);input.set(retirementDigest(v,q.role),prefix.length);
 const key=await crypto.subtle.importKey('raw',unhex(e.context[q.role].signing_key),{name:'Ed25519'},false,['verify']);if(!await crypto.subtle.verify('Ed25519',key,sig,input))fail();return {role:q.role,signature:b64(sig)};
}
export async function retirementStatus(v,e){
 if(!exact(v,['version','lease','handshake','confirmation','retirement'])||v.version!==1)fail();
 const h=handshake(v.handshake,e),c=confirmation(v.confirmation,e,h);if(h.revision!==3||c.revision!==2)fail();await lease(v.lease,e,h,c);if(v.lease.phase!=='leased')fail();
 if(v.retirement!==null)await retirementApproval(v.retirement,e,v);return v;
}
export function retirementPrefix(older,newer){
 if(!same(older.lease,newer.lease)||!same(older.handshake,newer.handshake)||!same(older.confirmation,newer.confirmation)||(older.retirement&&!same(older.retirement,newer.retirement)))fail();
}
export async function retirementHTTP(store,e,role,body){
 const controller=new AbortController();store.controllers.add(controller);const timer=setTimeout(()=>controller.abort(),5000);
 const live=()=>{store.live();if(controller.signal.aborted||(body!==undefined&&Date.now()>=e.context.expires_at*1000))fail();};
 try{live();const raw=body===undefined?undefined:JSON.stringify(body);if(raw&&new TextEncoder().encode(raw).length>512)fail();
 const res=await fetch('/v1/mls/successors/'+e.context.intent_id+'/retirement',{method:body===undefined?'GET':'POST',body:raw,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':e.context[role].device_id},signal:controller.signal});live();
 if(res.redirected||res.headers.get('X-Family-Actor')!==store.identity||!(res.status===200||(body!==undefined&&res.status===201)))fail();
 const reader=res.body.getReader(),parts=[];let size=0;for(;;){const {done,value}=await reader.read();live();if(done)break;size+=value.length;if(size>224*1024)fail();parts.push(value);}
 const rawBytes=new Uint8Array(size);let at=0;for(const part of parts){rawBytes.set(part,at);at+=part.length;}const v=await retirementStatus(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(rawBytes)),e);live();
 if(body&&v.retirement===null)fail();return v;
 }finally{controller.abort();clearTimeout(timer);store.controllers.delete(controller);}
}
