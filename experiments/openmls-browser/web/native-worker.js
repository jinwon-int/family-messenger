// Synthetic-only native transport adapter. Keys and cached plaintext are not
// protected at rest. No human accounts or production exposure.
import init,{staged_init,staged_trusted_apply,staged_epoch,staged_checksum,staged_public_key,staged_group_id,staged_check_trust,verify_device_package} from './pkg/family_mls_browser_experiment.js';
import {exact,fail,hex,unhex,name,normalizePins,readDirectory,matchDirectory} from './trust-directory.js';
const wasm=await init(),enc=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true});
let db,identity,room,retired=false;
const b64=b=>btoa(String.fromCharCode(...b));
function bytes(s,max=65536){if(typeof s!=='string'||s.length>Math.ceil(max/3)*4)fail();const b=Uint8Array.from(atob(s),x=>x.charCodeAt(0));if(b.length>max||b64(b)!==s)fail();return b;}
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const hash=x=>hex(staged_checksum(enc.encode(JSON.stringify(x))));
function input(a){if(!Array.isArray(a)||a.length>8192||a.length===0||!a.every(x=>Number.isInteger(x)&&x>=0&&x<=255))fail();return new Uint8Array(a);}
const reqKeys=['client_id','device_id','group_id','kind','expected_revision','epoch','target_device','payload'];
function requestShape(q){
 if(!exact(q,reqKeys)||!name(q.client_id)||!name(q.device_id)||typeof q.group_id!=='string'||!/^[a-f0-9]{32,256}$/.test(q.group_id)||q.group_id.length%2||!Number.isSafeInteger(q.expected_revision)||q.expected_revision<0||q.expected_revision>256||!Number.isSafeInteger(q.epoch)||q.epoch<0||q.epoch>256||!['key_package','welcome','ack','application','commit'].includes(q.kind)||(q.target_device!==''&&!name(q.target_device)))fail();bytes(q.payload);
 // Canonical Go struct field order for the transport checksum.
 return {client_id:q.client_id,device_id:q.device_id,group_id:q.group_id,kind:q.kind,expected_revision:q.expected_revision,epoch:q.epoch,target_device:q.target_device,payload:q.payload};
}
function eventShape(e){if(!exact(e,['seq','room','request','revision','epoch','sha256'])||!Number.isSafeInteger(e.seq)||e.seq<1||e.seq>256||e.room!==room||!Number.isSafeInteger(e.revision)||e.revision<1||e.revision>256||!Number.isSafeInteger(e.epoch)||e.epoch<0||e.epoch>256||e.sha256!==hash(requestShape(e.request)))fail();return e;}
function frame(id,device,actor,group,type,data){return {version:1,room,group_id:group,client_id:id,sender_actor:actor,sender_device:device,media_type:type,payload:b64(data)};}
function frameShape(f){if(!exact(f,['version','room','group_id','client_id','sender_actor','sender_device','media_type','payload'])||f.version!==1||f.room!==room||!name(f.client_id)||!f.client_id.startsWith('app-')||!['text','file'].includes(f.media_type)||!['alice','bob'].includes(f.sender_actor)||!name(f.sender_device))fail();if(bytes(f.payload,8192).length===0)fail();return f;}
function own(r){return r.pins.find(p=>p.actor===identity)}
function peer(r){return r.pins.find(p=>p.actor!==identity)}
function staticBinding(r,s){
 if(!exact(s,['room','group_id','creator_device','peer_device','pins','revision','epoch','phase','next_seq'])||s.room!==room||typeof s.group_id!=='string'||!/^[a-f0-9]{32,256}$/.test(s.group_id)||s.group_id.length%2||!Array.isArray(s.pins)||s.pins.length!==2||!Number.isSafeInteger(s.revision)||s.revision<0||s.revision>256||!Number.isSafeInteger(s.epoch)||s.epoch<0||s.epoch>256||!Number.isSafeInteger(s.next_seq)||s.next_seq<1||s.next_seq>257||!['key-package','welcome','ack','ready'].includes(s.phase))fail();
 for(const p of s.pins){if(!exact(p,['device_id','actor','signing_key','device_revision']))fail();const pin=r.pins.find(v=>v.device_id===p.device_id);if(!pin||Object.keys(p).some(k=>p[k]!==pin[k]))fail();}
 if(new Set(s.pins.map(x=>x.device_id)).size!==2||s.creator_device!==r.pins.find(p=>p.actor==='alice').device_id||s.peer_device!==r.pins.find(p=>p.actor==='bob').device_id)fail();
 const out={group_id:s.group_id,creator_device:s.creator_device,peer_device:s.peer_device};if(r.binding&&!same(r.binding,out))fail();if(r.group&&r.group!==s.group_id)fail();return out;
}
function checksum(r){return hash([3,r.identity,r.room,r.pins,r.group,r.binding,r.cursor,r.revision,r.epoch,r.phase,r.pending,r.receipts,r.messages,hex(r.crypto)]);}
function validate(r,check=true){
 if(!exact(r,['version','identity','room','pins','group','binding','cursor','revision','epoch','phase','pending','receipts','messages','crypto','checksum'])||r.version!==3||r.identity!==identity||r.room!==room||!(r.crypto instanceof Uint8Array)||!r.crypto.length||r.crypto.length>1048576||!Array.isArray(r.receipts)||r.receipts.length>32||!Array.isArray(r.messages)||r.messages.length>32||r.cursor!==r.receipts.length||!Number.isSafeInteger(r.revision)||r.revision<0||r.revision>32||!Number.isSafeInteger(r.epoch)||r.epoch<0||r.epoch>32||!['unbound','key-package','welcome','ack','ready'].includes(r.phase)||typeof r.group!=='string'||(r.group!==''&&(!/^[a-f0-9]{32,256}$/.test(r.group)||r.group.length%2))||typeof r.checksum!=='string')fail();
 let total=r.crypto.length;
 if(r.pins===null){if(r.group||r.binding||r.pending||r.cursor||r.messages.length||r.phase!=='unbound')fail();}
 else {if(!same(normalizePins(r.pins),r.pins)||own(r).signing_key!==hex(staged_public_key(r.crypto,identity)))fail();staged_check_trust(r.crypto,identity,peer(r).actor,unhex(peer(r).signing_key));}
 const localGroup=hex(staged_group_id(r.crypto,identity));if(localGroup&&localGroup!==r.group)fail();
 if(r.binding){if(!exact(r.binding,['group_id','creator_device','peer_device'])||r.binding.group_id!==r.group||r.binding.creator_device!==r.pins.find(p=>p.actor==='alice').device_id||r.binding.peer_device!==r.pins.find(p=>p.actor==='bob').device_id||r.phase==='unbound')fail();}
 else if(r.cursor||r.pending||r.phase!=='unbound')fail();
 for(let i=0;i<r.receipts.length;i++){const e=eventShape(r.receipts[i]);if(e.seq!==i+1||e.request.group_id!==r.group)fail();total+=bytes(e.request.payload).length;}
 for(const m of r.messages){frameShape(m);if(m.group_id!==r.group)fail();total+=bytes(m.payload,8192).length;}
 if(r.pending!==null){if(!exact(r.pending,['request','frame','retired']))fail();requestShape(r.pending.request);if(r.pending.request.device_id!==own(r).device_id||r.pending.request.group_id!==r.group||typeof r.pending.retired!=='boolean')fail();total+=bytes(r.pending.request.payload).length;if(r.pending.frame!==null){frameShape(r.pending.frame);total+=bytes(r.pending.frame.payload,8192).length;}}
 if(total>2*1024*1024)fail();if(check&&r.checksum!==checksum(r))fail();
}
function current(r,d){if(r.pins)matchDirectory(r.pins,d);else{const p=d.devices.find(x=>x.actor===identity);if(p&&(p.status!=='active'||p.signing_key!==hex(staged_public_key(r.crypto,identity))))fail();}}
function status(r){return {public_key:Array.from(staged_public_key(r.crypto,identity)),pins:r.pins,group_id:r.group,cursor:r.cursor,revision:r.revision,epoch:r.epoch,phase:r.phase,pending:r.pending?{client_id:r.pending.request.client_id,retired:r.pending.retired}:null,messages:r.messages};}
function open(database){
 if(typeof database!=='string'||!/^family-mls-native-synthetic-[a-z0-9-]{1,64}$/.test(database))fail();
 return new Promise((resolve,reject)=>{const q=indexedDB.open(database,1);q.onupgradeneeded=e=>{if(e.oldVersion!==0){q.transaction.abort();return;}q.result.createObjectStore('device').add({version:0,identity,room},'state');};q.onerror=()=>reject(Error('state unavailable'));q.onblocked=()=>reject(Error('state blocked'));q.onsuccess=()=>{const d=q.result;if(d.objectStoreNames.length!==1||!d.objectStoreNames.contains('device')){d.close();reject(Error('schema'));return;}d.onversionchange=()=>d.close();resolve(d);};});
}
function tx(d,operation,fault=''){
 return new Promise((resolve,reject)=>{const t=db.transaction('device','readwrite',{durability:'strict'}),s=t.objectStore('device');let result;
 const abort=()=>{try{t.abort()}catch(_){}};t.onerror=()=>{};t.onabort=()=>reject(Error('transaction rejected'));t.oncomplete=()=>resolve(result);
 const keys=s.getAllKeys(undefined,2);keys.onsuccess=()=>{if(keys.result.length!==1||keys.result[0]!=='state'){abort();return;}const q=s.get('state');q.onsuccess=()=>{try{
 let r=q.result;if(exact(r,['version','identity','room'])&&r.version===0&&r.identity===identity&&r.room===room){if(operation.kind!=='init'||d.devices.some(x=>x.actor===identity))fail();r={version:3,identity,room,pins:null,group:'',binding:null,cursor:0,revision:0,epoch:0,phase:'unbound',pending:null,receipts:[],messages:[],crypto:staged_init(identity),checksum:''};validate(r,false);r.checksum=checksum(r);}
 validate(r);current(r,d);result=operation(r);validate(r,false);r.checksum=checksum(r);validate(r);if(fault==='abort-before-write'){abort();return;}s.put(r,'state');if(fault==='abort-after-write'){abort();return;}
 }catch(_){abort();}};};});
}
function applyCrypto(r,method,data){let c;try{c=staged_trusted_apply(r.crypto,identity,method,data,peer(r).actor,unhex(peer(r).signing_key));r.crypto=c.state();return c.output();}finally{if(c)c.free();}}
async function http(method,path,body,device){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
 try{const headers={'X-Family-Actor':identity};if(device)headers['X-Family-Device']=device;if(body!==undefined)headers['Content-Type']='application/json';const res=await fetch(path,{method,credentials:'same-origin',cache:'no-store',redirect:'error',headers,body:body===undefined?undefined:JSON.stringify(body),signal:controller.signal});
 if(!res.ok||res.headers.get('X-Family-Actor')!==identity){const e=Error('admission');e.status=res.status;throw e;}
 const reader=res.body.getReader();let size=0,parts=[];for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>1024*1024)fail();parts.push(value);}const raw=new Uint8Array(size);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}return JSON.parse(decoder.decode(raw));
 }finally{controller.abort();clearTimeout(timer);}
}
async function snapshot(){const d=await readDirectory(identity,room);return tx(d,r=>structuredClone(r));}
async function nativeStatus(r){const s=await http('GET','/v1/mls/rooms/'+room+'/status',undefined,own(r).device_id);staticBinding(r,s);return s;}
function bindRecord(r,s){const binding=staticBinding(r,s);if(r.binding)return;if(r.pending||r.cursor||r.phase!=='unbound')fail();r.group=binding.group_id;r.binding=binding;r.phase='key-package';}
function wire(r,id,kind,target,payload){return {client_id:id,device_id:own(r).device_id,group_id:r.group,kind,expected_revision:r.revision,epoch:r.epoch,target_device:target,payload:b64(payload)};}
function prepareControl(r){
 if(!r.binding||r.pending||r.receipts.length>=32)fail();let q;
 if(identity==='bob'&&r.phase==='key-package')q=wire(r,'control-kp','key_package',peer(r).device_id,applyCrypto(r,'key_package',new Uint8Array()));
 else if(identity==='alice'&&r.phase==='welcome'){
 const kp=r.receipts.at(-1);if(kp.request.kind!=='key_package')fail();q=wire(r,'control-welcome','welcome',peer(r).device_id,applyCrypto(r,'invite',bytes(kp.request.payload)));
 }else if(identity==='bob'&&r.phase==='ack'){if(staged_epoch(r.crypto,identity)!=='1')fail();q=wire(r,'control-ack','ack',peer(r).device_id,new Uint8Array());}
 else fail();r.pending={request:q,frame:null,retired:false};return status(r);
}
function consume(r,e){
 eventShape(e);const q=requestShape(e.request);
 if(e.seq!==r.cursor+1||q.group_id!==r.group||q.expected_revision!==r.revision||q.epoch!==r.epoch)fail();
 const self=q.device_id===own(r).device_id;if(!self&&q.device_id!==peer(r).device_id)fail();
 let phase=r.phase,revision=r.revision,epoch=r.epoch;
 if(q.kind==='key_package'){if(phase!=='key-package'||q.client_id!=='control-kp'||q.device_id!==r.binding.peer_device||q.target_device!==r.binding.creator_device||!bytes(q.payload).length)fail();phase='welcome';revision++;}
 else if(q.kind==='welcome'){if(phase!=='welcome'||q.client_id!=='control-welcome'||q.device_id!==r.binding.creator_device||q.target_device!==r.binding.peer_device||!bytes(q.payload).length)fail();phase='ack';revision++;epoch++;}
 else if(q.kind==='ack'){if(phase!=='ack'||q.client_id!=='control-ack'||q.device_id!==r.binding.peer_device||q.target_device!==r.binding.creator_device||bytes(q.payload).length)fail();phase='ready';revision++;}
 else if(q.kind==='application'){if(phase!=='ready'||q.target_device!==''||!q.client_id.startsWith('app-')||!bytes(q.payload).length)fail();}
 else fail(); // Later membership/update controls require their reviewed adapter.
 if(e.revision!==revision||e.epoch!==epoch)fail();
 if(self){if(!r.pending||r.pending.retired||!same(r.pending.request,q))fail();if(q.kind==='application'){if(!r.pending.frame)fail();r.messages.push(r.pending.frame);}r.pending=null;}
 else if(q.kind==='key_package')verify_device_package(bytes(q.payload),peer(r).actor,unhex(peer(r).signing_key));
 else if(q.kind==='welcome'){applyCrypto(r,'join',bytes(q.payload));if(hex(staged_group_id(r.crypto,identity))!==r.group)fail();}
 else if(q.kind==='application'){
 const raw=applyCrypto(r,'decrypt_peer',bytes(q.payload)),f=frameShape(JSON.parse(decoder.decode(raw)));
 const expected=frame(q.client_id,q.device_id,peer(r).actor,r.group,f.media_type,bytes(f.payload,8192));
 if(!same(f,expected)||decoder.decode(raw)!==JSON.stringify(expected))fail();r.messages.push(expected);
 }
 r.cursor=e.seq;r.revision=revision;r.epoch=epoch;r.phase=phase;r.receipts.push(e);
 if((phase==='ack'||phase==='ready')&&staged_epoch(r.crypto,identity)!==String(epoch))fail();
}
async function sync(){
 const before=await snapshot();if(!before.binding)fail();const events=await http('GET','/v1/mls/rooms/'+room+'/log?after='+before.cursor,undefined,own(before).device_id);if(!Array.isArray(events)||events.length>8)fail();events.forEach(eventShape);
 const d=await readDirectory(identity,room);return tx(d,r=>{if(!same(r.binding,before.binding))fail();for(const e of events){if(e.seq<=r.cursor){if(!same(r.receipts[e.seq-1],e))fail();continue;}consume(r,e);}return status(r);});
}
async function dispatch(method,arg){
 if(method==='init'){
 if(db||!exact(arg,['identity','room','database'])||!['alice','bob'].includes(arg.identity)||!name(arg.room))fail();identity=arg.identity;room=arg.room;const d=await readDirectory(identity,room);db=await open(arg.database);const op=r=>status(r);op.kind='init';return tx(d,op);
 }
 if(!db)fail();
 if(['sync','status','create','bind','attach','advance','flush'].includes(method)&&arg!==null)fail();
 if(method==='sync')return sync();
 if(method==='status'){const r=await snapshot();return status(r);}
 if(method==='pin'){
 if(!exact(arg,['pins','fault'])||!['','abort-before-write','abort-after-write'].includes(arg.fault))fail();const pins=normalizePins(arg.pins),d=await readDirectory(identity,room);return tx(d,r=>{matchDirectory(pins,d);if(r.pins&&!same(r.pins,pins))fail();r.pins=pins;return status(r)},arg.fault);
 }
 if(method==='create'){
 const d=await readDirectory(identity,room);return tx(d,r=>{if(identity!=='alice'||!r.pins||r.binding)fail();if(!r.group){applyCrypto(r,'create',new Uint8Array());r.group=hex(staged_group_id(r.crypto,identity));}return status(r);});
 }
 if(method==='bind'||method==='attach'){
 const r=await snapshot();if(!r.pins)fail();let s;
 if(method==='bind'){if(identity!=='alice'||!r.group)fail();s=await http('POST','/v1/mls/rooms',{room,group_id:r.group,device_id:own(r).device_id,peer_device:peer(r).device_id},own(r).device_id);}
 else s=await nativeStatus(r);
 const d=await readDirectory(identity,room);return tx(d,current=>{bindRecord(current,s);return status(current);});
 }
 if(method==='advance'){
 const r=await snapshot(),s=await nativeStatus(r),d=await readDirectory(identity,room);return tx(d,current=>{staticBinding(current,s);if(s.revision!==current.revision||s.epoch!==current.epoch||s.phase!==current.phase)fail();return prepareControl(current);});
 }
 if(method==='prepare'){
 if(!exact(arg,['id','bytes','media_type','fault'])||!name(arg.id)||!arg.id.startsWith('app-')||!['text','file'].includes(arg.media_type)||!['','abort-before-write','abort-after-write'].includes(arg.fault))fail();const data=input(arg.bytes),r=await snapshot(),s=await nativeStatus(r),d=await readDirectory(identity,room);
 return tx(d,current=>{staticBinding(current,s);const f=frame(arg.id,own(current).device_id,identity,current.group,arg.media_type,data);
 const old=current.messages.find(m=>m.client_id===arg.id&&m.sender_device===own(current).device_id);if(old){if(!same(f,old))fail();return status(current);}
 if(current.pending){if(current.pending.retired||!same(current.pending.frame,f))fail();return status(current);}
 if(current.phase!=='ready'||s.phase!=='ready'||current.revision!==s.revision||current.epoch!==s.epoch||current.receipts.length>=32)fail();const cipher=applyCrypto(current,'encrypt',enc.encode(JSON.stringify(f)));current.pending={request:wire(current,arg.id,'application','',cipher),frame:f,retired:false};return status(current);},arg.fault);
 }
 if(method==='flush'){
 const r=await snapshot();if(!r.pending||r.pending.retired)fail();let e;
 try{e=await http('POST','/v1/mls/rooms/'+room+'/log',r.pending.request,own(r).device_id);}
 catch(err){if(err.status===409&&r.pending.request.kind==='application'){const s=await nativeStatus(r);if(s.epoch>r.pending.request.epoch||s.revision>r.pending.request.expected_revision){const d=await readDirectory(identity,room);await tx(d,current=>{if(current.pending&&same(current.pending.request,r.pending.request))current.pending.retired=true;return null;});}}throw err;}
 eventShape(e);if(!same(requestShape(e.request),r.pending.request))fail();return {accepted:true,seq:e.seq}; // pending clears only on committed self echo.
 }
 fail();
}
let queue=Promise.resolve();
self.onmessage=({data})=>{queue=queue.then(async()=>{let id;try{if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1||typeof data.method!=='string')fail();id=data.id;if(retired)fail();const result=await dispatch(data.method,data.argument);if(wasm.memory.buffer.byteLength>128*1024*1024)fail();self.postMessage({id,ok:true,result,memory_bytes:wasm.memory.buffer.byteLength});}catch(_){retired=true;if(db){db.close();db=undefined;}self.postMessage({id,ok:false,error:'native state rejected',memory_bytes:wasm.memory.buffer.byteLength});}});};
self.postMessage({boot:true});
