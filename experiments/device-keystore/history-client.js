// Isolated caller contract. A consumer must clear rendered history on onLock.
const clients=new Set();
export class HistoryReader {
 constructor(onLock=()=>{}){this.onLock=onLock;this.generation=0;this.active=null;clients.add(this);}
 lock(){this.generation++;const a=this.active;this.active=null;if(a){a.discard();clearTimeout(a.timer);a.worker.terminate();a.resolve({ok:false});}this.onLock();}
 close(){this.lock();clients.delete(this);}
 read(argument,exportSnapshot=false){
  this.lock();const generation=this.generation;
  return new Promise(resolve=>{
   let w;try{w=new Worker(exportSnapshot?'/history-export-worker.js':'/history-worker.js',{type:'module'});}catch{resolve({ok:false});return;}
   const a={worker:w,resolve,timer:null,discard:()=>{if(argument&&typeof argument==='object')argument.password=null;argument=null;}},live=()=>this.active===a&&this.generation===generation;
   this.active=a;const fail=()=>{if(live())this.lock();};
   a.timer=setTimeout(fail,10000);w.onerror=w.onmessageerror=fail;
   w.onmessage=({data})=>{
    if(!live())return;
    if(data?.ready===true){
     if(a.sent){fail();return;}a.sent=true;clearTimeout(a.timer);a.timer=setTimeout(fail,30000);
     try{w.postMessage({id:1,method:'read',argument});}catch{fail();}finally{a.discard();}
     return;
    }
    if(!a.sent||data?.id!==1||data?.ok!==true){fail();return;}
    clearTimeout(a.timer);w.terminate();this.active=null;resolve(data);
   };
  });
 }
}
function lockAll(){for(const c of clients)c.lock();}
addEventListener('pagehide',lockAll);
addEventListener('visibilitychange',()=>{if(document.hidden)lockAll();});
