// Public-data validation only. Accepted pins must come from an independent ceremony.
import {staged_checksum} from './pkg/family_mls_browser_experiment.js';
export const exact=(o,keys)=>o&&Object.getPrototypeOf(o)===Object.prototype&&Object.keys(o).sort().join(',')===keys.sort().join(',');
export const fail=()=>{throw new Error('rejected');};
export const hex=b=>Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
export const unhex=s=>new Uint8Array(s.match(/../g).map(x=>parseInt(x,16)));
export const name=s=>typeof s==='string'&&/^[a-zA-Z0-9_-]{1,64}$/.test(s);
export function validPin(p){
 if(!exact(p,['device_id','actor','signing_key','fingerprint','device_revision'])||!name(p.device_id)||!['alice','bob'].includes(p.actor)||typeof p.signing_key!=='string'||!/^[a-f0-9]{64}$/.test(p.signing_key)||p.device_revision!==1||p.fingerprint!==hex(staged_checksum(unhex(p.signing_key))))fail();
}
export function normalizePins(p){
 if(!Array.isArray(p)||p.length!==2)fail();for(const x of p)validPin(x);
 for(const field of ['device_id','actor','signing_key'])if(new Set(p.map(x=>x[field])).size!==2)fail();
 return p.map(x=>({device_id:x.device_id,actor:x.actor,signing_key:x.signing_key,fingerprint:x.fingerprint,device_revision:x.device_revision})).sort((a,b)=>a.actor.localeCompare(b.actor));
}
export async function readDirectory(actor,room){
 if(!['alice','bob'].includes(actor)||!name(room))fail();
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
 try{
  const response=await fetch('/v1/rooms/'+room+'/devices',{credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'X-Family-Actor':actor},signal:controller.signal});
  if(!response.ok||response.headers.get('X-Family-Actor')!==actor)fail();
  const reader=response.body.getReader();let size=0,parts=[];
  for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>16384)fail();parts.push(value);}
  const raw=new Uint8Array(size);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
  const d=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw));
  if(!exact(d,['version','room','devices'])||d.version!==1||d.room!==room||!Array.isArray(d.devices)||d.devices.length>2)fail();
  const actors=new Set(),ids=new Set(),keys=new Set();
  for(const v of d.devices){
   if(!exact(v,['device_id','actor','signing_key','fingerprint','device_revision','status']))fail();
   if(!((v.status==='active'&&v.device_revision===1)||(v.status==='revoked'&&v.device_revision===2)))fail();
   const {status,...p}=v;validPin({...p,device_revision:1});
   if(actors.has(v.actor)||ids.has(v.device_id)||keys.has(v.signing_key))fail();
   actors.add(v.actor);ids.add(v.device_id);keys.add(v.signing_key);
  }
  return d;
 }finally{controller.abort();clearTimeout(timer);}
}
export function matchDirectory(pins,d){
 const p=normalizePins(pins);if(d.devices.length!==2)fail();
 for(const v of d.devices){const expected=p.find(x=>x.actor===v.actor);if(v.status!=='active'||!expected||Object.keys(expected).some(k=>expected[k]!==v[k]))fail();}
}
