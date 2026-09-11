// Shared one-shot lifecycle; selected protected store is supplied by its entry.
import {exact,fail} from './trust-directory.js';
import {immutable,declareCustody} from './custody-declaration.js';
export function custodyWorker(wasm,store,normalize,role){
 let started=false,dead=false;
 const close=()=>{dead=true;store.close();};
 self.onmessage=async({data})=>{
  let id=null;
  try{
   if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
   if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true},memory_bytes:0});self.close();return;}
   if(dead||started||data.method!=='declare')fail();started=true;const a=data.argument;
   if(!exact(a,['identity','database','password','intent'])||!['alice','bob'].includes(a.identity)||!exact(a.intent,['accepted','reservation'])||a.intent.accepted!==true)fail();
   // Normalize and recursively own the complete descriptor before the first await.
   const expected=immutable(normalize(a.intent.reservation,a.identity));
   const selected=store.argument({identity:a.identity,database:a.database,password:a.password,room:role==='candidate'?'candidate-proposal-v1':expected.context.source_room,create:false});a.password=null;
   store.identity=selected.identity;
   if(role==='candidate')await store.admission(expected);
   await store.open(selected.database,selected.identity,selected.room);
   const local=role==='candidate'?await store.operate(expected):await store.prepare({accepted:true,reservation:expected});
   if(dead||local.committed!==true||local.reservation_id!==expected.reservation_id)fail();
   const result=await declareCustody(store,expected,role),memory=wasm.memory.buffer.byteLength+store.memoryBytes();
   if(dead||memory>128*1024*1024)fail();
   self.postMessage({id,ok:true,result,memory_bytes:memory});close();self.close();
  }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}
 };
 self.postMessage({boot:true});
}
