// Isolated synthetic historical viewer. No live sender, enrollment or IDB import.
import {HistoryReader} from '/history-client.js';
const $=id=>document.getElementById(id),limit=6*1024*1024;
const decoder=new TextDecoder('utf-8',{fatal:true});
const channel=new BroadcastChannel('family-vault-ui-lock-v1');
let current=null,generation=0;
const live=s=>current===s&&!s.dead&&s.generation===generation&&!document.hidden;
const check=s=>{if(!live(s))throw Error('closed');};
const exact=(o,keys)=>o&&Object.getPrototypeOf(o)===Object.prototype&&Object.keys(o).sort().join(',')===keys.split(',').sort().join(',');
function clearResults(s){
 if(s){s.archive=null;s.messages=null;for(const u of s.urls)URL.revokeObjectURL(u);s.urls.clear();}
 if(!s||current===s){$('messages').replaceChildren();$('summary').textContent='';$('result').hidden=true;$('save-archive').hidden=true;}
}
function disable(value){for(const e of $('history-form').elements)e.disabled=value;}
function lock(broadcast=true,message='잠겼습니다. 파일과 시험 비밀번호를 다시 선택해 주세요.'){
 const s=current;current=null;generation++;
 if(s){s.dead=true;s.controller.abort();clearTimeout(s.timer);clearTimeout(s.expiry);s.reader.close();clearResults(s);}
 clearResults(null);$('password').value='';$('archive').value='';$('accepted').checked=false;
 disable(false);$('identity').textContent='계정 확인 전';$('status').textContent=message;
 if(broadcast)channel.postMessage('lock');
}
function failed(s){if(current===s)lock(true,'계정·기기 정보 또는 복구 파일을 확인할 수 없습니다. 다시 선택해 주세요.');}
async function admission(s){
 check(s);let reader;
 const response=await fetch('/v1/session',{credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'X-Family-Actor':s.actor},signal:AbortSignal.any([s.controller.signal,AbortSignal.timeout(5000)])});
 try{
  if(!response.ok||response.headers.get('X-Family-Actor')!==s.actor)throw Error('account');
  reader=response.body.getReader();let size=0,parts=[];
  for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>4096)throw Error('limit');parts.push(value);}
  const bytes=new Uint8Array(size);let at=0;for(const p of parts){bytes.set(p,at);at+=p.length;}
  const body=JSON.parse(decoder.decode(bytes));
  if(!exact(body,'mode,actor,owner')||body.mode!=='signed'||body.actor!==s.actor||typeof body.owner!=='boolean')throw Error('account');
  check(s);$('identity').textContent=s.actor+' · 인증된 시험 계정';
 }finally{if(reader)await reader.cancel().catch(()=>{});else await response.body?.cancel().catch(()=>{});}
}
function schedule(s){
 if(live(s))s.timer=setTimeout(async()=>{try{await admission(s);schedule(s);}catch{failed(s);}},15000);
}
function decode(payload){
 if(typeof payload!=='string'||payload.length>10924)throw Error('file');
 const bytes=Uint8Array.from(atob(payload),c=>c.charCodeAt(0));
 if(!bytes.length||bytes.length>8192||btoa(String.fromCharCode(...bytes))!==payload)throw Error('file');return bytes;
}
async function download(s,bytes,name){
 if(!live(s)||s.downloading)return;s.downloading=true;
 try{await admission(s);check(s);const u=URL.createObjectURL(new Blob([bytes],{type:'application/octet-stream'}));s.urls.add(u);
  const a=document.createElement('a');a.href=u;a.download=name;a.click();
  setTimeout(()=>{URL.revokeObjectURL(u);s.urls.delete(u);},1000);
 }catch{failed(s);}finally{s.downloading=false;bytes=null;}
}
function render(s,result){
 check(s);
 if(!exact(result,'identity,room,group_id,pins,cursor,epoch,messages')||result.identity!==s.actor||result.room!==s.expected.room||result.group_id!==s.expected.group_id||!Array.isArray(result.messages)||result.messages.length>32)throw Error('history');
 const list=document.createDocumentFragment();
 for(const m of result.messages){
  if(!['alice','bob'].includes(m.sender_actor)||!/^app-[a-zA-Z0-9_-]{1,60}$/.test(m.client_id))throw Error('message');
  const bytes=decode(m.payload),li=document.createElement('li');li.textContent=m.sender_actor+': ';li.dataset.messageId=m.client_id;
  if(m.media_type==='text')li.append(document.createTextNode(decoder.decode(bytes)));
  else if(m.media_type==='file'){const button=document.createElement('button');button.textContent='과거 파일 내려받기 ('+bytes.length+' bytes)';button.addEventListener('click',()=>download(s,decode(m.payload),'history-'+m.client_id+'.bin'));li.append(button);}
  else throw Error('type');list.append(li);
 }
 s.messages=result.messages;$('messages').replaceChildren(list);$('summary').textContent=s.expected.room+' · 기록 '+result.cursor+'까지 · 현재 전송 권한을 뜻하지 않습니다.';$('result').hidden=false;
}
async function begin(exportSnapshot){
 if(current?.busy)return;
 // The expectation is supplied independently; never parsed from the archive.
 let password=$('password').value,file=$('archive').files[0],raw=$('expected').value;
 const accepted=$('accepted').checked;
 lock(false);let s;
 try{
  if(!accepted||password.length<32||password.length>128||raw.length>4096||(!exportSnapshot&&(!file||file.size<1||file.size>limit)))throw Error('input');
  const expected=JSON.parse(raw);raw=null;
  if(!exact(expected,'database,identity,room,group_id,pins')||!['alice','bob'].includes(expected.identity))throw Error('binding');
  s={generation,actor:expected.identity,expected,controller:new AbortController(),dead:false,busy:true,urls:new Set(),archive:null,messages:null,downloading:false};
  current=s;s.reader=new HistoryReader(()=>clearResults(s));disable(true);$('status').textContent='계정과 암호화 기록 확인 중…';
  await admission(s);check(s);
  let archive;
  if(!exportSnapshot){archive=new Uint8Array(await file.arrayBuffer());check(s);if(archive.byteLength!==file.size||archive.byteLength>limit)throw Error('size');}
  file=null;
  let argument={expected,password,...(exportSnapshot?{}:{archive})};
  const pending=s.reader.read(argument,exportSnapshot);password=null;archive=null;argument=null;
  // HistoryReader owns the transient argument until posting or retirement.
  const reply=await pending;check(s);if(reply.ok!==true)throw Error('read');
  await admission(s);check(s);
  if(exportSnapshot){const bytes=reply.result?.archive;if(!(bytes instanceof Uint8Array)||bytes.byteLength<1||bytes.byteLength>limit||bytes.buffer.byteLength>limit)throw Error('archive');s.archive=bytes;$('result').hidden=false;$('save-archive').hidden=false;$('summary').textContent='원래 보관함을 변경하지 않고 암호화 파일을 준비했습니다.';}
  else render(s,reply.result);
  s.busy=false;$('status').textContent=exportSnapshot?'암호화 파일 저장 버튼을 눌러 주세요.':'확정된 과거 기록만 표시했습니다.';
  s.expiry=setTimeout(()=>{if(current===s)lock();},300000);schedule(s);
 }catch{if(s)failed(s);else lock(false,'입력과 파일 크기를 확인해 주세요.');}
 finally{password=null;file=null;raw=null;}
}
$('history-form').addEventListener('submit',e=>{e.preventDefault();begin(false);});
$('export').addEventListener('click',()=>{if($('history-form').reportValidity())begin(true);});
$('save-archive').addEventListener('click',()=>{const s=current;if(s?.archive)download(s,s.archive,'synthetic-history.family-history');});
$('lock').addEventListener('click',()=>lock());
for(const id of ['expected','accepted','archive'])$(id).addEventListener('input',()=>{if(current)lock();});
channel.onmessage=()=>lock(false);
addEventListener('pagehide',()=>lock());
document.addEventListener('visibilitychange',()=>{if(document.hidden)lock();});
