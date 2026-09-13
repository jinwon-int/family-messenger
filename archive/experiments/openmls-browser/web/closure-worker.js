import {exact,fail} from './trust-directory.js';
import {immutable} from './custody-declaration.js';
import {closureHTTP} from './closure-wire.js';
export function closureWorker(wasm,store,normalize,role){
 let started=false,dead=false;const close=()=>{dead=true;store.close();};
 self.onmessage=async({data})=>{let id=null;try{
  if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
  if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true}});self.close();return;}
  if(dead||started||data.method!=='closure')fail();started=true;const a=data.argument;
  if(!exact(a,['identity','database','password','intent','operation'])||!['alice','bob'].includes(a.identity)||!exact(a.intent,['accepted','reservation'])||a.intent.accepted!==true||!exact(a.operation,['kind'])||!['close','observe'].includes(a.operation.kind))fail();
  const kind=a.operation.kind,e=immutable(normalize(a.intent.reservation,a.identity));const selected=store.argument({identity:a.identity,database:a.database,password:a.password,room:role==='candidate'?'candidate-proposal-v1':e.context.source_room,create:false});a.password=null;store.identity=selected.identity;
  await store.open(selected.database,selected.identity,selected.room);let local=await store.closeTarget(e,kind);if(!local.committed||dead)fail();
  if(kind==='close'&&!local.server_closed&&local.request){await closureHTTP(store,e,role,local.request);local=await store.closeTarget(e,'observe');}
  const memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();const {request,receipt,...result}=local;self.postMessage({id,ok:true,result,memory_bytes:memory});close();self.close();
 }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}};self.postMessage({boot:true});
}
