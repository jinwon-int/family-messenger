// One-shot generated proposal/binding only. No native transport commands.
import init from './pkg/family_mls_browser_experiment.js';
import {CandidateStore,candidateReservation} from './candidate-store.js';
import {exact,fail} from './trust-directory.js';
const wasm=await init(),store=new CandidateStore();let started=false,dead=false;
const close=()=>{dead=true;store.close();};
self.onmessage=async({data})=>{
 let id=null;
 try{
  if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
  if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true},memory_bytes:0});self.close();return;}
  if(dead||started||!['proposal','bind'].includes(data.method))fail();started=true;const a=data.argument;
  if(!exact(a,data.method==='proposal'?['identity','database','password','create']:['identity','database','password','intent'])||!['alice','bob'].includes(a.identity))fail();
  let expected=null;
  if(data.method==='bind'){
   if(!exact(a.intent,['accepted','reservation'])||a.intent.accepted!==true)fail();expected=candidateReservation(a.intent.reservation,a.identity);
  }
  const selected=store.argument({identity:a.identity,database:a.database,room:'candidate-proposal-v1',password:a.password,create:data.method==='proposal'?a.create:false});a.password=null;
  // A signed account may make an unassigned proposal, never a member or sender.
  store.identity=selected.identity;await store.admission(expected);
  await store.open(selected.database,selected.identity);
  const result=await store.operate(expected),memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();
  self.postMessage({id,ok:true,result,memory_bytes:memory});close();self.close();
 }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}
};
self.postMessage({boot:true});
