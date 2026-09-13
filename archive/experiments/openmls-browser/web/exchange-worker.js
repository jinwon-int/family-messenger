// One public slot per invocation, only after protected local state commits.
import {exact,fail} from './trust-directory.js';
import {immutable} from './custody-declaration.js';
import {handshakeHTTP,prefix} from './handshake-wire.js';
export function exchangeWorker(wasm,store,normalize,role){
 let started=false,dead=false;
 const close=()=>{dead=true;store.close();};
 self.onmessage=async({data})=>{
  let id=null;
  try{
   if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
   if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true},memory_bytes:0});self.close();return;}
   if(dead||started||data.method!=='exchange')fail();started=true;const a=data.argument;
   if(!exact(a,['identity','database','password','intent'])||!['alice','bob'].includes(a.identity)||!exact(a.intent,['accepted','reservation'])||a.intent.accepted!==true)fail();
   const expected=immutable(normalize(a.intent.reservation,a.identity));
   const selected=store.argument({identity:a.identity,database:a.database,password:a.password,room:role==='candidate'?'candidate-proposal-v1':expected.context.source_room,create:false});a.password=null;
   store.identity=selected.identity;
   const observed=await handshakeHTTP(store,expected,role);
   await store.open(selected.database,selected.identity,selected.room);
   let local=await store.advance(expected,observed);if(dead||local.committed!==true)fail();
   if(local.pending){
    const accepted=await handshakeHTTP(store,expected,role,local.pending);prefix(observed.records,accepted.records);
    local=await store.advance(expected,accepted);
   }
   const memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();
   const {pending,...result}=local;
   self.postMessage({id,ok:true,result,memory_bytes:memory});close();self.close();
  }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}
 };
 self.postMessage({boot:true});
}
