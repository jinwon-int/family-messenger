// Synthetic aggregate-custody fixture worker (#49). Never embedded or
// delivered by the Go server and never a product entry: it holds at most one
// namespace store in worker memory, accepts one explicit test intent per call
// and returns only public status fields or the synthetic application result.
// Admissions arrive as documents; with an admissionUrl the worker re-receives
// the fresh admission from the admission service over same-origin fetch
// (outside IndexedDB) — the real receive path. The worker sees only the
// policy public key, never the policy secret.
import {AggregateVaultStore} from '/native-aggregate-vault.js';
self.postMessage({boot:true});
let store=null,retired=false;
const holds={};
const live=()=>{if(retired||!store||store.dead)throw Error('retired');};
const retire=()=>{retired=true;store?.close();store=null;};
const fetchAdmission=async(url,token)=>{
 if(typeof url!=='string'||!url.startsWith('/v1/aggregate/admission'))throw Error('bad admission url: '+url);
 let r;
 try{r=await fetch(url,{credentials:'omit',cache:'no-store',redirect:'error',
  headers:typeof token==='string'&&token?{'Cf-Access-Jwt-Assertion':token}:{}});}
 catch(e){throw Error('admission fetch failed: '+String(e&&e.message||e));}
 if(!r.ok)throw Error('admission status '+r.status);
 return await r.json();
};
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
   const doc=argument.admission??await fetchAdmission(argument.admissionUrl,argument.token);
   result=await store.tx(doc,{kind:'put',room:argument.room,bytes:Uint8Array.from(argument.bytes??[])},
    argument.fault??'',live,()=>argument.freshAdmission??argument.admission??fetchAdmission(argument.admissionUrl,argument.token));
  }else if(method==='test-aggregate-hold-cas'){live();self.testHoldAggregateCAS=true;result=null;}
  else if(method==='test-aggregate-hold-kdf'){live();self.testHoldAggregateKDF=true;result=null;}
  else throw Error('unknown method');
  return result;
 })().then(result=>self.postMessage({id,ok:true,result,memory_bytes:store?store.memoryBytes():0}))
    .catch(()=>{retire();self.postMessage({id,ok:false,error:'refused',memory_bytes:0});});
};
