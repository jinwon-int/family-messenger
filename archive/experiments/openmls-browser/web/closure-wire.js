import {exact,fail,unhex} from './trust-directory.js';
import {same,jsonHash,bytes,b64} from './handshake-wire.js';
import {enrollmentStatus} from './enrollment-wire.js';
export function closureDigest(v,role){return unhex(jsonHash(['family-successor-closure',1,'persistent-target',role,jsonHash(v.enrollment)]));}
export async function closureApproval(q,e,v){
 if(!exact(q,['role','signature'])||!['candidate','peer'].includes(q.role))fail();const sig=bytes(q.signature,64);if(sig.length!==64)fail();
 const prefix=new TextEncoder().encode('family-successor-lease-v1\0'),input=new Uint8Array(prefix.length+32);input.set(prefix);input.set(closureDigest(v,q.role),prefix.length);
 const key=await crypto.subtle.importKey('raw',unhex(e.context[q.role].signing_key),{name:'Ed25519'},false,['verify']);if(!await crypto.subtle.verify('Ed25519',key,sig,input))fail();return {role:q.role,signature:b64(sig)};
}
export async function closureStatus(v,e){
 if(!exact(v,['version','enrollment','handshake','confirmation','closure'])||v.version!==1)fail();
 await enrollmentStatus({version:1,enrollment:v.enrollment,handshake:v.handshake,confirmation:v.confirmation,active:true},e);
 if(v.closure!==null)await closureApproval(v.closure,e,v);return v;
}
export function closurePrefix(older,newer){
 if(!same(older.enrollment,newer.enrollment)||!same(older.handshake,newer.handshake)||!same(older.confirmation,newer.confirmation)||(older.closure&&!same(older.closure,newer.closure)))fail();
}
export async function closureHTTP(store,e,role,body){
 const controller=new AbortController();store.controllers.add(controller);const timer=setTimeout(()=>controller.abort(),5000);
 const live=()=>{store.live();if(controller.signal.aborted)fail();};
 try{live();const raw=body===undefined?undefined:JSON.stringify(body);if(raw&&new TextEncoder().encode(raw).length>512)fail();
 const res=await fetch('/v1/mls/successors/'+e.context.intent_id+'/closure',{method:body===undefined?'GET':'POST',body:raw,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':e.context[role].device_id},signal:controller.signal});live();
 if(res.redirected||res.headers.get('X-Family-Actor')!==store.identity||!(res.status===200||(body!==undefined&&res.status===201)))fail();
 const reader=res.body.getReader(),parts=[];let size=0;for(;;){const {done,value}=await reader.read();live();if(done)break;size+=value.length;if(size>224*1024)fail();parts.push(value);}
 const rawBytes=new Uint8Array(size);let at=0;for(const part of parts){rawBytes.set(part,at);at+=part.length;}const v=await closureStatus(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(rawBytes)),e);live();
 if(body&&v.closure===null)fail();return v;
 }finally{controller.abort();clearTimeout(timer);store.controllers.delete(controller);}
}
