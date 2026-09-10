// Synthetic aggregate-custody fixture worker (#49). Never embedded or
// delivered by the Go server and never a product entry: it holds at most one
// namespace store in worker memory, accepts one explicit test intent per call
// and returns only public status fields or the synthetic application result.
// Admissions arrive as page-signed documents; the worker only ever sees the
// policy public key, never the policy secret.
import {AggregateVaultStore} from '/native-aggregate-vault.js';
self.postMessage({boot:true});
let store=null,retired=false;
const holds={};
const live=()=>{if(retired||!store||store.dead)throw Error('retired');};
const retire=()=>{retired=true;store?.close();store=null;};
self.onmessage=({data})=>{
 if(data?.test_aggregate_release){const release=holds[data.test_aggregate_release];holds[data.test_aggregate_release]=null;release?.();return;}
 const {id,method,argument}=data??{};
 (async()=>{
  if(retired)throw Error('retired');
  let result;
  if(method==='open'){
   if(store)throw Error('already open');
   store=new AggregateVaultStore();
   const scope=store.argument(argument??{});await store.open(scope.database,scope.actor);result={opened:true};
  }else if(method==='put-room'){
   console.log('WORKER_PUTARG admission='+(argument&&argument.admission!==undefined?typeof argument.admission+':'+JSON.stringify(Object.keys(argument.admission||{})):'MISSING')+' argkeys='+(argument?Object.keys(argument).join('|'):'null'));
   live();
   result=await store.tx(argument.admission,{kind:'put',room:argument.room,bytes:Uint8Array.from(argument.bytes??[])},
    argument.fault??'',live,async()=>argument.freshAdmission??argument.admission);
  }else if(method==='test-aggregate-hold-cas'){live();self.testHoldAggregateCAS=true;result=null;}
  else if(method==='test-aggregate-hold-kdf'){live();self.testHoldAggregateKDF=true;result=null;}
  else throw Error('unknown method');
  return result;
 })().then(result=>self.postMessage({id,ok:true,result,memory_bytes:store?store.memoryBytes():0}))
    .catch(()=>{retire();self.postMessage({id,ok:false,error:'refused',memory_bytes:0});});
};
