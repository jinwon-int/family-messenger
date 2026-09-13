// One-shot authorized synthetic context creation. No provider/password output.
import init from './pkg/family_mls_browser_experiment.js';
import {AggregateStore} from './aggregate-store.js';
import {exact,fail,readDirectory} from './trust-directory.js';
const wasm=await init(),store=new AggregateStore();let started=false,dead=false;
const close=()=>{dead=true;store.close();};
self.onmessage=async({data})=>{
 let id=null;
 try{
  if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
  if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true},memory_bytes:0});self.close();return;}
  if(dead||started||data.method!=='fork')fail();started=true;const a=data.argument;
  if(!exact(a,['identity','database','password','intent']))fail();
  const selected=store.argument({identity:a.identity,database:a.database,room:a.intent?.source,password:a.password,create:false});a.password=null;
  await readDirectory(selected.identity,selected.room);if(dead)fail();
  await store.open(selected.database,selected.identity,selected.room);
  const result=await store.fork(a.intent),memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();
  self.postMessage({id,ok:true,result,memory_bytes:memory});close();self.close();
 }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}
};
self.postMessage({boot:true});
