// Page adapter: no provider, signature, outbox or message plaintext leaves it.
import {exact,fail} from './trust-directory.js';
import {immutable} from './custody-declaration.js';
import {enrollmentHTTP} from './enrollment-wire.js';
import {closureHTTP} from './closure-wire.js';
export function lifecycleWorker(wasm,store,normalize,role){
 let started=false,dead=false,committed=false;const stop=()=>{dead=true;store.close();};
 const send=v=>{if(!dead)self.postMessage(v);};
 const state=(v,kind)=>kind.startsWith('closure')?(v.server_closed?'closed':'local-closed'):(v.active?'active':v.pair_declared?'awaiting-admin':v.own_declared?'awaiting-peer':'local-saved');
 self.onmessage=async({data})=>{let id=null;try{
  if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
  if(data.method==='lock'){if(data.argument!==null)fail();stop();self.close();return;}
  if(dead||started||data.method!=='lifecycle')fail();started=true;const a=data.argument;
  if(!exact(a,['identity','database','password','intent','kind'])||!['alice','bob'].includes(a.identity)||!exact(a.intent,['accepted','reservation'])||a.intent.accepted!==true||!['enroll','enrollment-observe','closure-close','closure-observe'].includes(a.kind))fail();
  const kind=a.kind,e=immutable(normalize(a.intent.reservation,a.identity));const selected=store.argument({identity:a.identity,database:a.database,password:a.password,room:role==='candidate'?'candidate-proposal-v1':e.context.source_room,create:false});a.password=null;store.identity=selected.identity;
  await store.open(selected.database,selected.identity,selected.room);let v;
  if(kind.startsWith('closure'))v=await store.closeTarget(e,kind==='closure-close'?'close':'observe');
  else v=await store.enroll(e,{kind:kind==='enroll'?'enroll':'observe'});
  if(!v.committed||dead)fail();committed=true;send({id,progress:'local-committed'});
  if(kind==='enroll'&&!v.own_declared){await enrollmentHTTP(store,e,role,'enrollment',v.approval);v=await store.enroll(e,{kind:'observe'});}
  if(kind==='closure-close'&&!v.server_closed&&v.request){await closureHTTP(store,e,role,v.request);v=await store.closeTarget(e,'observe');}
  const memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();send({id,ok:true,state:state(v,kind)});
 }catch{send({id,ok:false,committed});}finally{stop();self.close();}};
 self.postMessage({boot:true});
}
