// Public retry receipts only. A declaration is neither key possession nor activation.
import {exact,fail,hex} from './trust-directory.js';
import {staged_checksum} from './pkg/family_mls_browser_experiment.js';
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const hash=value=>hex(staged_checksum(enc.encode(JSON.stringify(value))));
export function immutable(value){
 for(const v of Object.values(value))if(v&&typeof v==='object')immutable(v);
 return Object.freeze(value);
}
export function declaration(expected,role){
 if(!['candidate','peer'].includes(role))fail();
 const context_sha256=hash(expected.context),device_id=expected.context[role].device_id;
 return {reservation_id:expected.reservation_id,context_sha256,role,
  declaration_id:hash(['family-successor-custody-declaration',1,role,expected.reservation_id,context_sha256,device_id])};
}
function receipt(value,expected,own){
 if(!exact(value,['version','reservation_id','context_sha256','revision','phase','declarations'])||value.version!==1||value.reservation_id!==own.reservation_id||value.context_sha256!==own.context_sha256||!Array.isArray(value.declarations)||!Number.isInteger(value.revision)||value.revision<1||value.revision>2||value.revision!==value.declarations.length||value.phase!==(value.revision===2?'pair-declared-inactive':'custody-pending'))fail();
 let previous='',found=false;
 for(const d of value.declarations){
  if(!exact(d,['role','declaration_id','device_id','reservation_id','context_sha256'])||!['candidate','peer'].includes(d.role)||d.role<=previous||typeof d.declaration_id!=='string'||!/^[a-zA-Z0-9_-]{1,64}$/.test(d.declaration_id)||d.device_id!==expected.context[d.role].device_id||d.reservation_id!==own.reservation_id||d.context_sha256!==own.context_sha256)fail();
  previous=d.role;
  if(d.role===own.role){if(d.declaration_id!==own.declaration_id)fail();found=true;}
 }
 if(!found)fail();return value;
}
export async function declareCustody(store,expected,role){
 // Caller reaches here only after protected storage authenticated this exact
 // binding and its strict IndexedDB transaction completed. No generated ID.
 const own=declaration(expected,role),c=expected.context;
 const live=()=>{store.live();if(c.expires_at*1000<=Date.now())fail();};
 const request=async method=>{
  live();const controller=new AbortController();store.controllers.add(controller);
  const timer=setTimeout(()=>controller.abort(),5000);
  try{
   const body=method==='POST'?JSON.stringify(own):undefined;if(body&&enc.encode(body).length>1024)fail();
   const response=await fetch('/v1/mls/successors/'+c.intent_id+'/custody',{method,body,credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-Family-Actor':store.identity,'X-Family-Device':c[role].device_id},signal:controller.signal});
   live();if(controller.signal.aborted||response.redirected||!([200,...(method==='POST'?[201]:[])].includes(response.status))||response.headers.get('X-Family-Actor')!==store.identity)fail();
   const reader=response.body.getReader(),parts=[];let n=0;
   for(;;){const {done,value}=await reader.read();live();if(controller.signal.aborted)fail();if(done)break;n+=value.length;if(n>4096)fail();parts.push(value);}
   const raw=new Uint8Array(n);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
   return receipt(JSON.parse(dec.decode(raw)),expected,own);
  }finally{controller.abort();clearTimeout(timer);store.controllers.delete(controller);}
 };
 const posted=await request('POST'),current=await request('GET');live();
 // A later observation may gain a slot, never lose or substitute an existing one.
 for(const d of posted.declarations)if(!current.declarations.some(v=>JSON.stringify(v)===JSON.stringify(d)))fail();
 return {committed:true,own_declared:true,role,declaration_id:own.declaration_id,readiness:current};
}
