// Isolated caller contract. A consumer must clear rendered history on onLock.
const clients=new Set();
function bounded(argument,exportSnapshot){
 if(typeof argument?.password!=='string'||argument.password.length<32||argument.password.length>128||new TextEncoder().encode(JSON.stringify(argument.expected)).length>4096)return false;
 return exportSnapshot||(argument?.archive instanceof Uint8Array&&argument.archive.buffer instanceof ArrayBuffer&&argument.archive.byteLength>0&&argument.archive.byteLength<=6*1024*1024&&argument.archive.buffer.byteLength<=6*1024*1024);
}
export class AggregateHistoryReader {
 constructor(onLock=()=>{}){this.onLock=onLock;this.generation=0;this.active=null;this.closed=false;clients.add(this);}
 lock(){this.generation++;const a=this.active;this.active=null;if(a){a.discard();clearTimeout(a.timer);a.worker.terminate();a.resolve({ok:false});}try{this.onLock();}catch{}}
 close(){this.closed=true;this.lock();clients.delete(this);}
 read(argument,exportSnapshot=false){
  if(this.closed)return Promise.resolve({ok:false});
  const generation=this.generation+1;
  this.lock();
  // Cleanup callbacks may close or start another operation synchronously.
  if(this.closed||this.generation!==generation||this.active)return Promise.resolve({ok:false});
  // Public expectations and transient password are bounded before worker clone.
  // Full identity/fingerprint semantics are validated inside the reader worker.
  try{
   if(!bounded(argument,exportSnapshot))throw Error('bounds');
   argument=structuredClone(argument);
  }catch{argument=null;return Promise.resolve({ok:false});}
  return new Promise(resolve=>{
   let w;try{w=new Worker(exportSnapshot?'/aggregate-history-export-worker.js':'/aggregate-history-worker.js',{type:'module'});}catch{resolve({ok:false});return;}
   const a={worker:w,resolve,timer:null,discard:()=>{argument=null;}},live=()=>this.active===a&&this.generation===generation;
   this.active=a;const fail=()=>{if(live())this.lock();};
   a.timer=setTimeout(fail,10000);w.onerror=w.onmessageerror=fail;
   w.onmessage=({data})=>{
    if(!live())return;
    if(data?.ready===true){
     if(a.sent){fail();return;}a.sent=true;clearTimeout(a.timer);a.timer=setTimeout(fail,30000);
     try{if(!bounded(argument,exportSnapshot))throw Error('bounds');w.postMessage({id:1,method:'read',argument});}catch{fail();}finally{a.discard();}
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
