// Synthetic one-shot native preparation. A declaration follows complete local
// custody, never precedes it. No private state is sent to the native server.
import init from './pkg/family_mls_browser_experiment.js';
import {AggregateStore} from './aggregate-store.js';
import {exact,fail,readDirectory,normalizePins,name} from './trust-directory.js';
const wasm=await init(),store=new AggregateStore(),decoder=new TextDecoder('utf-8',{fatal:true});let started=false,dead=false;
const close=()=>{dead=true;store.close();};
async function preparation(identity,intent,method='GET'){
 const pins=normalizePins(intent.pins),own=pins.find(p=>p.actor===identity);if(!own||!name(intent.target))fail();
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);store.controllers.add(controller);
 try{
  const headers={'X-Family-Actor':identity,'X-Family-Device':own.device_id};
  const options={method,headers,credentials:'same-origin',cache:'no-store',redirect:'error',signal:controller.signal};
  if(method==='POST'){headers['Content-Type']='application/json';options.body=JSON.stringify({source_room:intent.source,source_group:intent.source_group,intent_id:intent.id});}
  const response=await fetch('/v1/mls/rooms/'+intent.target+'/preparation',options);
  if(!response.ok||response.headers.get('X-Family-Actor')!==identity)fail();
  const reader=response.body.getReader();let size=0,parts=[];
  for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>4096)fail();parts.push(value);}
  const raw=new Uint8Array(size);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
  const p=JSON.parse(decoder.decode(raw));
  if(!exact(p,['version','room','source_room','source_group','pins','prepared'])||p.version!==1||p.room!==intent.target||p.source_room!==intent.source||p.source_group!==intent.source_group||!Array.isArray(p.pins)||p.pins.length!==2||!Array.isArray(p.prepared)||p.prepared.length>2)fail();
  const seen=new Set();for(const pin of p.pins){if(!exact(pin,['device_id','actor','signing_key','device_revision'])||seen.has(pin.device_id))fail();seen.add(pin.device_id);const expected=pins.find(x=>x.device_id===pin.device_id);if(!expected||Object.keys(pin).some(k=>pin[k]!==expected[k]))fail();}
  const ready=new Set();for(const item of p.prepared){if(!exact(item,['device_id','intent_id'])||!seen.has(item.device_id)||ready.has(item.device_id)||!name(item.intent_id))fail();ready.add(item.device_id);if(item.device_id===own.device_id&&item.intent_id!==intent.id)fail();}
  if(method==='POST'&&!ready.has(own.device_id))fail();
  if(dead)fail();return p;
 }finally{controller.abort();clearTimeout(timer);store.controllers.delete(controller);}
}
self.onmessage=async({data})=>{
 let id=null;
 try{
  if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
  if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true},memory_bytes:0});self.close();return;}
  if(dead||started||data.method!=='fork')fail();started=true;const a=data.argument;
  if(!exact(a,['identity','database','password','intent'])||!exact(a.intent,['id','source','target','source_group','pins']))fail();
  const selected=store.argument({identity:a.identity,database:a.database,room:a.intent.source,password:a.password,create:false});a.password=null;
  await readDirectory(selected.identity,selected.room);if(dead)fail();
  await preparation(selected.identity,a.intent);
  await store.open(selected.database,selected.identity,selected.room);
  const local=await store.fork(a.intent);if(dead)fail();
  const accepted=await preparation(selected.identity,a.intent,'POST');
  const memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();
  self.postMessage({id,ok:true,result:{...local,preparation_accepted:true,pair_prepared:accepted.prepared.length===2},memory_bytes:memory});close();self.close();
 }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}
};
self.postMessage({boot:true});
