import {exact,scope,request,result,describe,operation,receivedMessages,publicExport} from './lease-ceremony-client.js';
const $=id=>document.getElementById(id),channel=new BroadcastChannel('family-vault-ui-lock-v1');
let current=null,generation=0,accepted=null,publicResult=null;
function say(state,text){$('status').dataset.state=state;$('status').textContent=text;}
function showSend(){$('send-section').hidden=$('action').value!=='send';}
function sendOk(){if($('action').value!=='send')return true;try{operation('send',$('message-id').value,$('message-text').value);return true;}catch{return false;}}
function controls(){const busy=!!current;for(const id of ['identity','role','database','action','password','consent','request-file','request-load','confirmation','message-id','message-text'])$(id).disabled=busy;
 const valid=scope($('identity').value,$('database').value,$('role').value),kind=$('action').value;
 $('run').disabled=busy||!valid||!['activate','sync','send'].includes(kind)||$('password').value.length<32||$('password').value.length>128||!$('consent').checked||(!accepted||$('confirmation').value!==accepted.sha256)||!sendOk();$('export').disabled=busy||!publicResult;
 showSend();
}
function forget(){publicResult=null;$('public-result').textContent='';$('export').disabled=true;$('received-list').replaceChildren();}
function stop(broadcast=false){const s=current;current=null;generation++;if(s){clearTimeout(s.timer);s.argument.password=null;s.controller.abort();s.worker?.terminate();$('uncertain').hidden=false;}
 $('password').value='';$('consent').checked=false;$('message-text').value='';forget();say(s?'unknown':'locked',s?'작업을 중단했습니다. 저장 여부를 같은 보관함에서 확인하세요.':'잠겼습니다. 계정과 작업을 다시 확인하세요.');controls();if(broadcast)channel.postMessage('lock');}
async function reset(){stop();accepted=null;$('confirmation').value='';$('request-file').value='';$('request-details').textContent='';$('request-status').textContent='요청 파일을 직접 읽어 대조하세요.';$('request-section').hidden=false;
 controls();}

function finish(s,state,text){if(current!==s||s.generation!==generation)return false;clearTimeout(s.timer);s.argument.password=null;s.controller.abort();s.worker?.terminate();current=null;$('password').value='';$('consent').checked=false;$('message-text').value='';say(state,text);controls();return true;}
function unknown(s){if(finish(s,'unknown','저장 여부를 확인할 수 없습니다. 같은 보관함과 요청으로 확인하세요. 결과 확인은 저장된 같은 승인 정보를 다시 보낼 수 있습니다.')){$('uncertain').hidden=false;forget();}}
function paintReceived(items){$('received-list').replaceChildren();for(const x of items){const li=document.createElement('li');li.dataset.seq=String(x.seq);li.textContent=x.text;$('received-list').append(li);}}
$('request-load').addEventListener('click',async()=>{const file=$('request-file').files?.[0];stop();accepted=null;$('confirmation').value='';$('request-details').textContent='';const g=generation,identity=$('identity').value,database=$('database').value,role=$('role').value;$('request-status').textContent='요청 파일을 읽고 있습니다.';controls();
 try{if(!file||file.size>32768)throw Error('file');const value=await request(await file.text(),identity,database,role);if(g!==generation||document.hidden)return;accepted=value;const c=value.reservation.context;
 $('request-details').textContent=JSON.stringify({reservation:value.reservation.reservation_id,intent:c.intent_id,source_room:c.source_room,source_group:c.source_group,target_room:c.target_room,predecessor:c.predecessor,candidate:c.candidate,peer:c.peer,candidate_fingerprint:c.candidate_fingerprint,package_sha256:c.package_sha256,expires_at:c.expires_at},null,2);$('request-status').textContent='요청을 읽었습니다. 별도 경로로 받은 확인값을 입력하세요. 아직 키를 열거나 연결하지 않았습니다.';controls();}
 catch{if(g===generation){$('request-status').textContent='요청 파일의 계정·보관함·형식·크기를 확인하세요.';controls();}}
});
$('preparation-form').addEventListener('submit',async event=>{event.preventDefault();if(current||$('run').disabled||document.hidden)return;
 const identity=$('identity').value,database=$('database').value,kind=$('action').value,role=$('role').value,expected=structuredClone(accepted.reservation);
 let op;try{op=operation(kind,$('message-id').value,$('message-text').value);}catch{return;}
 const argument={identity,database,password:$('password').value,intent:{accepted:true,reservation:expected},operation:op};$('password').value='';$('consent').checked=false;$('message-text').value='';forget();
 const s={worker:null,controller:new AbortController(),argument,expected,identity,database,generation:++generation,booted:false,receiving:false,timer:null};current=s;say('working','선택한 작업과 저장 상태를 확인하고 있습니다.');controls();s.timer=setTimeout(()=>unknown(s),60000);
 let worker;try{worker=new Worker('/'+role+'-lease-worker.js',{type:'module'});s.worker=worker;}catch{unknown(s);return;}
 worker.onerror=()=>unknown(s);worker.onmessage=async({data})=>{if(current!==s||s.generation!==generation)return;
 if(exact(data,'boot')&&data.boot===true&&!s.booted){s.booted=true;try{worker.postMessage({id:1,method:'lease',argument});}catch{unknown(s);}finally{argument.password=null;}return;}
 if(!s.booted||s.receiving||!exact(data,'id,ok,result,memory_bytes')||data.id!==1||data.ok!==true||!Number.isSafeInteger(data.memory_bytes)||data.memory_bytes<0||data.memory_bytes>128*1024*1024){unknown(s);return;}
 s.receiving=true;worker.terminate();try{const inbox=receivedMessages(data.result.received),value=await result(data.result,identity,database,role,kind,expected);if(current!==s||s.generation!==generation||document.hidden)return;
 if(finish(s,value.state,describe(value))){publicResult=value;$('public-result').textContent=JSON.stringify(value,null,2);paintReceived(inbox);controls();}}
 catch{unknown(s);}
 };
});
$('export').addEventListener('click',()=>{if(!publicResult||current||document.hidden)return;const url=URL.createObjectURL(new Blob([JSON.stringify(publicExport(publicResult),null,2)+'\n'],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='lease-public-receipt.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});
for(const id of ['identity','role','action'])$(id).addEventListener('change',reset);$('database').addEventListener('input',reset);
for(const id of ['password','consent','confirmation','message-id','message-text'])$(id).addEventListener('input',controls);
$('lock').addEventListener('click',()=>{stop(true);accepted=null;$('confirmation').value='';controls();});channel.onmessage=e=>{if(e.data==='lock'){stop();accepted=null;$('confirmation').value='';controls();}};
function hidden(){stop();accepted=null;$('confirmation').value='';controls();}
document.addEventListener('visibilitychange',()=>{if(document.hidden)hidden();});addEventListener('pagehide',hidden);controls();
