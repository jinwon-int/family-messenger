// Isolated synthetic first-device trust gate. Pins are supplied independently by
// the test ceremony; never learned/updated from the server directory. Memory only.
import init, {Device, staged_checksum} from './pkg/family_mls_browser_experiment.js';
import {exact, fail as reject, hex, unhex, name, validPin, readDirectory, matchDirectory} from './trust-directory.js';
const wasm = await init();
let device, actor, room, pins, retired = false;
const bytes = b => {if(!Array.isArray(b)||!b.length||b.length>65536||!b.every(x=>Number.isInteger(x)&&x>=0&&x<=255)) reject();return new Uint8Array(b);};
async function admission(){matchDirectory(pins,await readDirectory(actor,room));}
let queue=Promise.resolve();
self.onmessage=({data})=>{
 queue=queue.then(async()=>{
  let id;
  try {
   if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1||typeof data.method!=='string')reject();
   id=data.id;const {method,argument}=data;
   if(retired) reject();let result;
   if(method==='init') {if(device||!name(argument))reject();actor=argument;device=new Device(actor);}
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
