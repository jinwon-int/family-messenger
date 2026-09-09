// Synthetic aggregate-custody fixture worker (#49). Never embedded or
// delivered by the Go server and never a product entry: it holds at most one
// namespace store in worker memory, accepts one explicit test intent per call
// and returns only public status fields or the synthetic application result.
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
   live();
   const directory=argument.directory??{devices:[]};
   result=await store.tx(directory,{kind:'put',room:argument.room,bytes:Uint8Array.from(argument.bytes??[])},
    argument.fault??'',live,async()=>argument.freshDirectory??directory);
  }else if(method==='test-aggregate-hold-cas'){live();self.testHoldAggregateCAS=true;result=null;}
  else if(method==='test-aggregate-hold-kdf'){live();self.testHoldAggregateKDF=true;result=null;}
  else throw Error('unknown method');
  return result;
 })().then(result=>self.postMessage({id,ok:true,result,memory_bytes:store?store.memoryBytes():0}))
    .catch(()=>{retire();self.postMessage({id,ok:false,error:'refused',memory_bytes:0});});
};
