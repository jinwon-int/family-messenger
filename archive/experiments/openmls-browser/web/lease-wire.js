import {exact,fail,unhex} from './trust-directory.js';
import {same,jsonHash,bytes,b64} from './handshake-wire.js';
export function leaseDigest(e,h,c,role){return unhex(jsonHash(['family-successor-lease',1,role,e.reservation_id,jsonHash(e.context),jsonHash(h),jsonHash(c),h.records[1].request.group_id,e.context.expires_at]));}
export async function approval(v,e,h,c){
 if(!exact(v,['role','signature'])||!['candidate','peer'].includes(v.role))fail();const sig=bytes(v.signature,64);if(sig.length!==64)fail();
 const prefix=new TextEncoder().encode('family-successor-lease-v1\0'),input=new Uint8Array(prefix.length+32);input.set(prefix);input.set(leaseDigest(e,h,c,v.role),prefix.length);
 const key=await crypto.subtle.importKey('raw',unhex(e.context[v.role].signing_key),{name:'Ed25519'},false,['verify']);if(!await crypto.subtle.verify('Ed25519',key,sig,input))fail();return {role:v.role,signature:b64(sig)};
}
export async function lease(v,e,h,c){
 if(h.revision!==3||c.revision!==2||!exact(v,['version','reservation_id','context_sha256','handshake_sha256','confirmation_sha256','group_id','expires_at','phase','approvals'])||v.version!==1||v.reservation_id!==e.reservation_id||v.context_sha256!==jsonHash(e.context)||v.handshake_sha256!==jsonHash(h)||v.confirmation_sha256!==jsonHash(c)||v.group_id!==h.records[1].request.group_id||v.expires_at!==e.context.expires_at||!Array.isArray(v.approvals)||v.approvals.length>2)fail();
 let last='';for(const a of v.approvals){await approval(a,e,h,c);if(a.role<=last)fail();last=a.role;}if(v.phase!==(v.approvals.length===2?'leased':'awaiting-pair'))fail();return v;
}
export function events(v,e){
 if(!Array.isArray(v)||v.length>64)fail();const ids=new Set();return v.map((ev,i)=>{if(!exact(ev,['seq','message','sha256'])||ev.seq!==i+1)fail();const q=ev.message;
 if(!exact(q,['client_id','device_id','payload'])||typeof q.client_id!=='string'||!/^[a-zA-Z0-9_-]{1,64}$/.test(q.client_id)||![e.context.candidate.device_id,e.context.peer.device_id].includes(q.device_id)||!bytes(q.payload,4096).length||jsonHash(q)!==ev.sha256)fail();const id=q.device_id+'\0'+q.client_id;if(ids.has(id))fail();ids.add(id);return ev;});
}
export async function leaseHTTP(store,e,h,c,role,action,body){
 const live=()=>{store.live();if(controller.signal.aborted||Date.now()>=e.context.expires_at*1000)fail();};
 const controller=new AbortController();store.controllers.add(controller);const timer=setTimeout(()=>controller.abort(),5000);
 try{live();const raw=body===undefined?undefined:JSON.stringify(body);if(raw&&new TextEncoder().encode(raw).length>8192)fail();
 const res=await fetch('/v1/mls/successors/'+e.context.intent_id+'/'+action,{method:body===undefined?'GET':'POST',body:raw,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':e.context[role].device_id},signal:controller.signal});live();
 if(res.redirected||res.headers.get('X-Family-Actor')!==store.identity||!(res.status===200||(body!==undefined&&res.status===201)))fail();
 const reader=res.body.getReader(),parts=[];let size=0;for(;;){const {done,value}=await reader.read();live();if(done)break;size+=value.length;if(size>(action==='lease'?2048:524288))fail();parts.push(value)}
 const full=new Uint8Array(size);let at=0;for(const b of parts){full.set(b,at);at+=b.length;}const v=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(full));
 if(action==='lease'){await lease(v,e,h,c);live();if(body&&!v.approvals.some(a=>same(a,body)))fail();return v;}
 if(body){if(!exact(v,['seq','message','sha256'])||!Number.isInteger(v.seq)||v.seq<1||v.seq>64||!same(v.message,body)||v.sha256!==jsonHash(body))fail();return v;}return events(v,e);
 }finally{controller.abort();clearTimeout(timer);store.controllers.delete(controller);}
}
