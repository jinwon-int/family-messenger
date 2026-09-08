// Isolated synthetic first-device trust gate. Pins are supplied independently by
// the test ceremony; never learned/updated from the server directory. Memory only.
import init, {Device, staged_checksum} from './pkg/family_mls_browser_experiment.js';
const wasm = await init();
let device, actor, room, pins, retired = false;
const exact = (o, keys) => o && Object.getPrototypeOf(o) === Object.prototype && Object.keys(o).sort().join(',') === keys.sort().join(',');
const reject = () => {throw new Error('rejected');};
const hex = b => Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
const bytes = b => {if(!Array.isArray(b)||!b.length||b.length>65536||!b.every(x=>Number.isInteger(x)&&x>=0&&x<=255)) reject();return new Uint8Array(b);};
const unhex = s => new Uint8Array(s.match(/../g).map(x=>parseInt(x,16)));
const name = s => typeof s==='string' && /^[a-zA-Z0-9_-]{1,64}$/.test(s);
function validPin(p) {
  if(!exact(p,['device_id','actor','signing_key','fingerprint','device_revision'])||!name(p.device_id)||!['alice','bob'].includes(p.actor)||typeof p.signing_key!=='string'||!/^[a-f0-9]{64}$/.test(p.signing_key)||p.device_revision!==1||p.fingerprint!==hex(staged_checksum(unhex(p.signing_key)))) reject();
}
async function admission() {
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
  try {
    const response=await fetch('/v1/rooms/'+room+'/devices',{credentials:'same-origin',redirect:'error',headers:{'X-Family-Actor':actor},signal:controller.signal});
    if(!response.ok || response.headers.get('X-Family-Actor')!==actor) reject();
    // Bound body incrementally; Content-Length is not a trusted allocation bound.
    const reader=response.body.getReader();let size=0,parts=[];
    for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>16384){controller.abort();reject();}parts.push(value);}
    const raw=new Uint8Array(size);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
    const d=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw));
    if(!exact(d,['version','room','devices'])||d.version!==1||d.room!==room||!Array.isArray(d.devices)||d.devices.length!==2) reject();
    const seen=new Set();
    for(const v of d.devices){
      if(!exact(v,['device_id','actor','signing_key','fingerprint','device_revision','status'])||v.status!=='active') reject();
      const {status,...p}=v;validPin(p);
      const expected=pins.find(x=>x.actor===p.actor);
      if(seen.has(p.actor)||!expected||Object.keys(p).some(k=>p[k]!==expected[k])) reject();
      seen.add(p.actor);
    }
    if(seen.size!==2) reject();
  } finally {controller.abort();clearTimeout(timer);}
}
let queue=Promise.resolve();
self.onmessage=({data})=>{
 queue=queue.then(async()=>{
  let id;
  try {
   if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1||typeof data.method!=='string')reject();
   id=data.id;const {method,argument}=data;
   if(retired) reject();let result;
   if(method==='init') {if(device||!['alice','bob'].includes(argument))reject();actor=argument;device=new Device(actor);}
   else {
    if(!device)reject();
    if(method==='public_key') result=device.public_key();
    else if(method==='key_package') result=device.key_package();
    else if(method==='pin') {
      if(pins||!exact(argument,['room','pins'])||!name(argument.room)||!Array.isArray(argument.pins)||argument.pins.length!==2)reject();
      const p=argument.pins;for(const v of p)validPin(v);
      if(new Set(p.map(x=>x.actor)).size!==2||new Set(p.map(x=>x.device_id)).size!==2||new Set(p.map(x=>x.signing_key)).size!==2||p.find(x=>x.actor===actor)?.signing_key!==hex(device.public_key()))reject();
      room=argument.room;pins=structuredClone(p);await admission();result=true;
    } else {
      if(!pins)reject();await admission();const peer=pins.find(x=>x.actor!==actor),key=unhex(peer.signing_key);
      switch(method){
       case 'check':result=true;break;
       case 'create':result=device.create();break;
       case 'invite':result=device.invite_trusted(bytes(argument),peer.actor,key);break;
       case 'join':result=device.join_trusted(bytes(argument),peer.actor,key);break;
       case 'encrypt':result=device.encrypt(bytes(argument));break;
       case 'decrypt':result=device.decrypt(bytes(argument));break;
       default:reject();
      }
    }
   }
   if(wasm.memory.buffer.byteLength>128*1024*1024)reject();
   self.postMessage({id,ok:true,result:result instanceof Uint8Array?Array.from(result):result,memory_bytes:wasm.memory.buffer.byteLength});
  } catch(_) {
   retired=true;if(device){device.free();device=undefined;}
   self.postMessage({id,ok:false,error:'trust operation rejected',memory_bytes:wasm.memory.buffer.byteLength});
  }
 });
};
self.postMessage({boot:true});
