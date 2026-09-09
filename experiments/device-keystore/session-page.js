// Synthetic harness only. No provider/key is returned to this page.
let current=null, generation=0;
const channel=new BroadcastChannel('family-session-record-synthetic-v1');
function retire(){generation++;if(current){const old=current;current=null;clearTimeout(old.timer);old.worker.terminate();old.boot?.({denied:true});old.resolve?.({denied:true,locked:true,kdf:old.kdf});}}
function lock(){retire();channel.postMessage('lock');}
channel.onmessage=retire;addEventListener('pagehide',lock);addEventListener('visibilitychange',()=>{if(document.hidden)lock();});
async function start(){
  retire();const g=generation;
  return new Promise(resolve=>{
    const worker=new Worker('/session-worker.js',{type:'module'});
    const c={worker,boot:resolve,resolve:null,timer:null,kdf:false};current=c;
    c.timer=setTimeout(lock,20000);worker.onerror=lock;
    worker.onmessage=({data})=>{
      if(g!==generation||current!==c)return;
      if(data.type==='kdf-start'){c.kdf=true;return;}
      if(data.type==='ready'){clearTimeout(c.timer);const done=c.boot;c.boot=null;done(data);return;}
      const done=c.resolve??c.boot;c.resolve=null;c.boot=null;clearTimeout(c.timer);
      if(data.type==='denied'){retire();done?.({denied:true,kdf:c.kdf});}
      else {if(data.retired)retire();done?.({...data,kdf:c.kdf});}
    };
  });
}
function command(data){
  if(!current||current.boot||current.resolve)throw Error('unavailable or busy');
  const c=current;c.kdf=false;
  return new Promise(resolve=>{c.resolve=resolve;c.timer=setTimeout(lock,20000);try{c.worker.postMessage(data);}catch{lock();}});
}
window.sessionProbe={start,command,lock,active:()=>current?{busy:!!current.resolve,kdf:current.kdf}:null};
