// Disposable encrypted-worker caller. No password or private state is persisted.
const workers=new Map();let serial=0;
function stop(name,expected=workers.get(name)){
  if(!expected)return;if(workers.get(name)===expected)workers.delete(name);
  expected.worker.terminate();clearTimeout(expected.bootTimer);expected.bootReject?.(Error('stopped'));
  for(const finish of [...expected.pending.values()])finish({ok:false,error:'stopped',memory_bytes:0});
}
window.stopWorker=name=>stop(name);
window.activeVaultWorkers=()=>workers.size;
window.spawn=name=>new Promise((resolve,reject)=>{
  if(workers.has(name))throw Error('duplicate');const worker=new Worker('./vault-native-worker.js',{type:'module'});
  const r={worker,pending:new Map(),bootReject:reject};workers.set(name,r);
  r.bootTimer=setTimeout(()=>stop(name,r),10000);
  worker.addEventListener('message',function boot({data}){if(data.boot){clearTimeout(r.bootTimer);r.bootReject=null;worker.removeEventListener('message',boot);resolve();}});
  worker.addEventListener('error',()=>stop(name,r));
});
window.call=(name,method,argument)=>new Promise(resolve=>{
  const r=workers.get(name),id=++serial;if(!r){resolve({id,ok:false,error:'missing',memory_bytes:0});return;}
  let timer;
  const finish=data=>{clearTimeout(timer);r.worker.removeEventListener('message',onmessage);r.pending.delete(id);resolve({...data,id});};
  const onmessage=({data})=>{
    if (data.id !== id) return;
    finish(data);
    if(!data.ok)stop(name,r);
  };
  r.pending.set(id,finish);r.worker.addEventListener('message',onmessage);
  timer=setTimeout(()=>stop(name,r),30000);
  try{r.worker.postMessage({id,method,argument});}catch{stop(name,r);}
});
const channel=new BroadcastChannel('family-vault-view-lock');
const closeAll=()=>{for(const [name,r] of [...workers])stop(name,r);};
channel.onmessage=closeAll;
window.lockVaults=()=>{closeAll();channel.postMessage('lock');};
addEventListener('pagehide',window.lockVaults);addEventListener('visibilitychange',()=>{if(document.hidden)window.lockVaults();});
window.ready=true;
