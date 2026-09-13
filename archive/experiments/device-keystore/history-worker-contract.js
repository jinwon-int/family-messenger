import {memory} from './history-core.js';
// The owner must terminate on lock/hide/clone failure/timeout; a synchronous KDF
// cannot process an in-band cancel. Generation guards belong to the caller.
export function serveHistory(operation){
 let busy=false,dead=false,controller;
 const stop=()=>{dead=true;controller?.abort();};
 self.onmessage=({data})=>{
  const id=Number.isSafeInteger(data?.id)&&data.id>0?data.id:0;
  if(dead)return;
  if(busy){stop();self.postMessage({id,ok:false});self.close();return;}
  if(!data||Object.keys(data).sort().join(',')!=='argument,id,method'||id===0||data.method!=='read'){
   stop();self.postMessage({id,ok:false});self.close();return;
  }
  busy=true;const deadline=performance.now()+15000;controller=new AbortController();const timer=setTimeout(stop,15000);
  const live=()=>{if(dead||controller.signal.aborted||performance.now()>deadline)throw Error('retired');};
  (async()=>{
   try{
    if(!navigator.locks)throw Error('locks');
    const result=await navigator.locks.request('family-native-vault-kdf',{mode:'exclusive',signal:controller.signal},async()=>{live();return operation(data.argument,live)});
    live();self.postMessage({id,ok:true,result,memory_bytes:memory()});
   }catch{if(!dead)self.postMessage({id,ok:false});}
   finally{clearTimeout(timer);stop();self.close();}
  })();
 };
 self.postMessage({ready:true,memory_bytes:memory()});
}
