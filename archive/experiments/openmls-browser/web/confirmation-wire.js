// Context-bound MLS confirmation messages; opaque server receipt is not proof.
import {exact,fail} from './trust-directory.js';
import {same,bytes,request,jsonHash,prefix,handshakeHTTP} from './handshake-wire.js';
export {prefix};
export const kinds=['candidate_proof','peer_proof'];
export const phases=['awaiting-candidate-proof','awaiting-peer-proof','confirmations-recorded-inactive'];
export function record(q,e,h,i){
 if(!exact(q,['reservation_id','context_sha256','kind','group_id','payload'])||q.kind!==kinds[i]||q.reservation_id!==e.reservation_id||q.context_sha256!==jsonHash(e.context)||q.group_id!==h.records[1].request.group_id)fail();
 const b=bytes(q.payload,4096);if(!b.length)fail();const normalized=request(e,q.kind,q.group_id,b);
 return {request:normalized,device_id:e.context[i===0?'candidate':'peer'].device_id,sha256:jsonHash(normalized)};
}
export function records(v,e,h){if(!Array.isArray(v)||v.length>2)fail();return v.map((r,i)=>{if(!exact(r,['request','device_id','sha256']))fail();const n=record(r.request,e,h,i);if(!same(n,r))fail();return n;});}
export function transcript(v,e,h){
 if(h.revision!==3||!exact(v,['version','reservation_id','context_sha256','revision','phase','records'])||v.version!==1||v.reservation_id!==e.reservation_id||v.context_sha256!==jsonHash(e.context)||!Number.isInteger(v.revision)||v.revision<0||v.revision>2||v.phase!==phases[v.revision])fail();
 const normalized=records(v.records,e,h);if(normalized.length!==v.revision)fail();return {...v,records:normalized};
}
export function frame(e,h,role,candidateSHA=''){
 return new TextEncoder().encode(JSON.stringify(['family-successor-possession',1,role,e.reservation_id,jsonHash(e.context),jsonHash(h),h.records[1].request.group_id,candidateSHA]));
}
export async function confirmationHTTP(store,e,h,role,body){
 store.live();if(e.context.expires_at*1000<=Date.now())fail();
 const c=new AbortController();store.controllers.add(c);const timer=setTimeout(()=>c.abort(),5000);
 const live=()=>{store.live();if(c.signal.aborted||e.context.expires_at*1000<=Date.now())fail();};
 try{
  const raw=body===undefined?undefined:JSON.stringify(body);if(raw&&new TextEncoder().encode(raw).length>8192)fail();
  const response=await fetch('/v1/mls/successors/'+e.context.intent_id+'/confirmation',{method:body===undefined?'GET':'POST',body:raw,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':e.context[role].device_id},signal:c.signal});
  live();if(response.redirected||response.headers.get('X-Family-Actor')!==store.identity||!(response.status===200||(body!==undefined&&response.status===201)))fail();
  const reader=response.body.getReader(),parts=[];let size=0;
  for(;;){const {done,value}=await reader.read();live();if(done)break;size+=value.length;if(size>16384)fail();parts.push(value);}
  const full=new Uint8Array(size);let at=0;for(const b of parts){full.set(b,at);at+=b.length;}
  const v=transcript(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(full)),e,h);
  if(body&&!same(v.records[kinds.indexOf(body.kind)]?.request,body))fail();return v;
 }finally{c.abort();clearTimeout(timer);store.controllers.delete(c);}
}
export async function current(store,e,role,h){const fresh=await handshakeHTTP(store,e,role);if(fresh.revision!==3||(h&&!same(fresh,h)))fail();return fresh;}
