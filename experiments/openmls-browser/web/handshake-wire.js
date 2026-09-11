// Bounded public successor transcript. No ordinary delivery or possession claim.
import {exact,fail,hex,unhex} from './trust-directory.js';
import {staged_checksum,verify_device_package} from './pkg/family_mls_browser_experiment.js';
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
export const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
export const hash=b=>hex(staged_checksum(b));
export const jsonHash=v=>hash(enc.encode(JSON.stringify(v)));
export const kinds=['key_package','welcome','ack'];
export const phases=['awaiting-key-package','awaiting-welcome','awaiting-ack','exchange-recorded-inactive'];
export const b64=b=>{let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);};
export function bytes(s,max=65536){if(typeof s!=='string'||s.length>Math.ceil(max/3)*4)fail();const b=Uint8Array.from(atob(s),c=>c.charCodeAt(0));if(b.length>max||b64(b)!==s)fail();return b;}
const group=s=>typeof s==='string'&&/^(?:[a-f0-9]{2}){16,128}$/.test(s);
export function request(expected,kind,group_id,payload){return {reservation_id:expected.reservation_id,context_sha256:jsonHash(expected.context),kind,group_id,payload:b64(payload)};}
export function record(q,expected,index){
 if(!exact(q,['reservation_id','context_sha256','kind','group_id','payload'])||q.reservation_id!==expected.reservation_id||q.context_sha256!==jsonHash(expected.context)||q.kind!==kinds[index])fail();
 const b=bytes(q.payload),c=expected.context;
 if(index===0){if(q.group_id!==''||!b.length||hash(b)!==c.package_sha256)fail();verify_device_package(b,c.candidate.actor,unhex(c.candidate.signing_key));}
 else if(!group(q.group_id)||q.group_id===c.source_group||(index===1?!b.length:b.length!==0))fail();
 const normalized=request(expected,q.kind,q.group_id,b);
 return {request:normalized,device_id:c[index===1?'peer':'candidate'].device_id,sha256:jsonHash(normalized)};
}
export function records(values,expected){
 if(!Array.isArray(values)||values.length>3)fail();
 return values.map((v,i)=>{if(!exact(v,['request','device_id','sha256']))fail();const r=record(v.request,expected,i);if(v.device_id!==r.device_id||v.sha256!==r.sha256||(i===2&&v.request.group_id!==values[1].request.group_id))fail();return r;});
}
export function transcript(value,expected){
 if(!exact(value,['version','reservation_id','context_sha256','revision','phase','records'])||value.version!==1||value.reservation_id!==expected.reservation_id||value.context_sha256!==jsonHash(expected.context)||!Number.isInteger(value.revision)||value.revision<0||value.revision>3||value.phase!==phases[value.revision])fail();
 const found=records(value.records,expected);if(found.length!==value.revision)fail();return {...value,records:found};
}
export function prefix(older,newer){if(older.length>newer.length||older.some((r,i)=>!same(r,newer[i])))fail();}
export async function handshakeHTTP(store,expected,role,body){
 const live=()=>{store.live();if(expected.context.expires_at*1000<=Date.now())fail();};live();
 const c=new AbortController();store.controllers.add(c);const timer=setTimeout(()=>c.abort(),5000);
 try{
  const rawBody=body===undefined?undefined:JSON.stringify(body);if(rawBody&&enc.encode(rawBody).length>96*1024)fail();
  const response=await fetch('/v1/mls/successors/'+expected.context.intent_id+'/handshake',{method:body===undefined?'GET':'POST',body:rawBody,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':expected.context[role].device_id},signal:c.signal});
  live();if(c.signal.aborted||response.redirected||response.headers.get('X-Family-Actor')!==store.identity||!(response.status===200||(body!==undefined&&response.status===201)))fail();
  const reader=response.body.getReader(),parts=[];let n=0;
  for(;;){const {done,value}=await reader.read();live();if(c.signal.aborted)fail();if(done)break;n+=value.length;if(n>192*1024)fail();parts.push(value);}
  const raw=new Uint8Array(n);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
  const result=transcript(JSON.parse(dec.decode(raw)),expected);
  if(body){const index=kinds.indexOf(body.kind);if(index<0||!same(result.records[index]?.request,body))fail();}
  return result;
 }finally{c.abort();clearTimeout(timer);store.controllers.delete(c);}
}
