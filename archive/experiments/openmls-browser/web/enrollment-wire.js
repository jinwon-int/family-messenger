import {exact,fail,unhex} from './trust-directory.js';
import {same,jsonHash,bytes,b64,transcript} from './handshake-wire.js';
import {transcript as confirmation} from './confirmation-wire.js';
import {lease,events} from './lease-wire.js';
export function enrollmentDigest(v,role){const l=v.enrollment.lease;return unhex(jsonHash(['family-successor-enrollment',1,'persistent-unused-target',role,l.reservation_id,l.context_sha256,l.handshake_sha256,l.confirmation_sha256,l.group_id,l.expires_at]));}
export async function enrollmentApproval(q,e,v){
 if(!exact(q,['role','signature'])||!['candidate','peer'].includes(q.role))fail();const sig=bytes(q.signature,64);if(sig.length!==64)fail();
 const pre=new TextEncoder().encode('family-successor-lease-v1\0'),input=new Uint8Array(pre.length+32);input.set(pre);input.set(enrollmentDigest(v,q.role),pre.length);
 const key=await crypto.subtle.importKey('raw',unhex(e.context[q.role].signing_key),{name:'Ed25519'},false,['verify']);if(!await crypto.subtle.verify('Ed25519',key,sig,input))fail();return {role:q.role,signature:b64(sig)};
}
export async function enrollmentStatus(v,e){
 if(!exact(v,['version','enrollment','handshake','confirmation','active'])||v.version!==1||typeof v.active!=='boolean')fail();
 transcript(v.handshake,e);confirmation(v.confirmation,e,v.handshake);const n=v.enrollment;
 if(!exact(n,['version','lease','approvals'])||n.version!==1||!Array.isArray(n.approvals)||n.approvals.length>2)fail();
 await lease(n.lease,e,v.handshake,v.confirmation);if(n.lease.phase!=='leased')fail();let last='';for(const q of n.approvals){await enrollmentApproval(q,e,v);if(q.role<=last)fail();last=q.role;}if(v.active&&n.approvals.length!==2)fail();return v;
}
export function enrollmentPrefix(a,b){if(!same(a.enrollment.lease,b.enrollment.lease)||!same(a.handshake,b.handshake)||!same(a.confirmation,b.confirmation)||a.enrollment.approvals.some(q=>!b.enrollment.approvals.some(x=>same(x,q)))||(a.active&&!b.active))fail();}
export async function enrollmentHTTP(store,e,role,action='enrollment',body){
 const controller=new AbortController();store.controllers.add(controller);const timer=setTimeout(()=>controller.abort(),5000);const live=()=>{store.live();if(controller.signal.aborted)fail();};
 try{live();if(body&&action==='enrollment'&&Date.now()>=e.context.expires_at*1000)fail();const raw=body===undefined?undefined:JSON.stringify(body);if(raw&&new TextEncoder().encode(raw).length>8192)fail();
 const res=await fetch('/v1/mls/successors/'+e.context.intent_id+'/'+action,{method:body===undefined?'GET':'POST',body:raw,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':e.context[role].device_id},signal:controller.signal});live();
 if(res.redirected||res.headers.get('X-Family-Actor')!==store.identity||!(res.status===200||(body!==undefined&&res.status===201)))fail();
 const reader=res.body.getReader(),parts=[];let size=0;for(;;){const {done,value}=await reader.read();live();if(done)break;size+=value.length;if(size>(action==='enrollment'?224*1024:524288))fail();parts.push(value)}
 const full=new Uint8Array(size);let at=0;for(const b of parts){full.set(b,at);at+=b.length;}const v=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(full));
 if(action==='enrollment'){await enrollmentStatus(v,e);live();if(body&&!v.enrollment.approvals.some(x=>same(x,body)))fail();return v;}
 if(body){if(!exact(v,['seq','message','sha256'])||!Number.isInteger(v.seq)||v.seq<1||v.seq>64||!same(v.message,body)||v.sha256!==jsonHash(body))fail();return v;}return events(v,e);
 }finally{controller.abort();clearTimeout(timer);store.controllers.delete(controller);}
}
