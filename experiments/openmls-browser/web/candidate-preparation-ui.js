import {exact,scope,request,result} from './candidate-preparation-client.js';
import {attempt,attempted} from './candidate-attempts.js';
const $=id=>document.getElementById(id),channel=new BroadcastChannel('family-vault-ui-lock-v1');
let current=null,generation=0,accepted=null,publicResult=null;
const key=()=> 'family-candidate-preparation-attempt-v1:'+encodeURIComponent($('identity').value)+':'+encodeURIComponent($('database').value);
function say(state,text){$('status').dataset.state=state;$('status').textContent=text;}
function controls(){const busy=!!current;for(const id of ['identity','database','action','password','consent','request-file','request-load','confirmation'])$(id).disabled=busy;
 const valid=scope($('identity').value,$('database').value),kind=$('action').value;
 $('run').disabled=busy||!valid||!['create','reopen','bind'].includes(kind)||$('password').value.length<32||$('password').value.length>128||!$('consent').checked||(kind==='bind'&&(!accepted||$('confirmation').value!==accepted.sha256));$('export').disabled=busy||!publicResult;
}
function forget(){publicResult=null;$('public-result').textContent='';$('export').disabled=true;}
function stop(broadcast=false){const s=current;current=null;generation++;if(s){clearTimeout(s.timer);s.argument.password=null;s.controller.abort();s.worker?.terminate();$('uncertain').hidden=false;}
 $('password').value='';$('consent').checked=false;forget();say(s?'unknown':'locked',s?'작업을 중단했습니다. 저장 여부를 같은 보관함에서 확인하세요.':'잠겼습니다. 계정과 작업을 다시 확인하세요.');controls();if(broadcast)channel.postMessage('lock');}
async function reset(){stop();accepted=null;$('confirmation').value='';$('request-file').value='';$('request-details').textContent='';$('request-status').textContent='요청 파일을 직접 읽어 대조하세요.';$('request-section').hidden=$('action').value!=='bind';
 const g=generation;try{const found=scope($('identity').value,$('database').value)&&await attempted(key());if(g===generation)$('attempt').hidden=!found;}catch{if(g===generation)$('attempt').hidden=false;}controls();}
function finish(s,state,text){if(current!==s||s.generation!==generation)return false;clearTimeout(s.timer);s.argument.password=null;s.controller.abort();s.worker?.terminate();current=null;$('password').value='';$('consent').checked=false;say(state,text);controls();return true;}
function unknown(s){if(finish(s,'unknown','저장 여부를 확인할 수 없습니다. 같은 보관함을 다시 열거나 같은 요청을 연결해 확인하세요.')){$('uncertain').hidden=false;forget();}}
$('request-load').addEventListener('click',async()=>{const file=$('request-file').files?.[0];stop();accepted=null;$('confirmation').value='';$('request-details').textContent='';const g=generation,identity=$('identity').value,database=$('database').value;$('request-status').textContent='요청 파일을 읽고 있습니다.';controls();
 try{if(!file||file.size>32768)throw Error('file');const value=await request(await file.text(),identity,database);if(g!==generation||document.hidden)return;accepted=value;const c=value.reservation.context;
 $('request-details').textContent=JSON.stringify({reservation:value.reservation.reservation_id,intent:c.intent_id,source_room:c.source_room,source_group:c.source_group,target_room:c.target_room,predecessor:c.predecessor,candidate:c.candidate,peer:c.peer,candidate_fingerprint:c.candidate_fingerprint,package_sha256:c.package_sha256,expires_at:c.expires_at},null,2);$('request-status').textContent='요청을 읽었습니다. 별도 경로로 받은 확인값을 입력하세요. 아직 키를 열거나 연결하지 않았습니다.';controls();}
 catch{if(g===generation){$('request-status').textContent='요청 파일의 계정·보관함·형식·크기를 확인하세요.';controls();}}
});
$('preparation-form').addEventListener('submit',async event=>{event.preventDefault();if(current||$('run').disabled||document.hidden)return;
 const identity=$('identity').value,database=$('database').value,kind=$('action').value,expected=kind==='bind'?structuredClone(accepted.reservation):null;
 const argument={identity,database,password:$('password').value,...(expected?{intent:{accepted:true,reservation:expected}}:{create:kind==='create'})};$('password').value='';$('consent').checked=false;forget();
 const s={worker:null,controller:new AbortController(),argument,expected,identity,database,generation:++generation,booted:false,receiving:false,timer:null};current=s;say('working','선택한 작업과 저장 상태를 확인하고 있습니다.');controls();s.timer=setTimeout(()=>unknown(s),60000);
 // Commit the public marker with strict IDB durability before any private worker.
 try{await attempt(key(),kind==='create',s.controller.signal);if(current!==s||s.generation!==generation||document.hidden)return;}
 catch{if(current===s){$('attempt').hidden=false;unknown(s);}return;}
 let worker;try{worker=new Worker('/candidate-worker.js',{type:'module'});s.worker=worker;}catch{unknown(s);return;}
 worker.onerror=()=>unknown(s);worker.onmessage=async({data})=>{if(current!==s||s.generation!==generation)return;
 if(exact(data,'boot')&&data.boot===true&&!s.booted){s.booted=true;try{worker.postMessage({id:1,method:expected?'bind':'proposal',argument});}catch{unknown(s);}finally{argument.password=null;}return;}
 if(!s.booted||s.receiving||!exact(data,'id,ok,result,memory_bytes')||data.id!==1||data.ok!==true||!Number.isSafeInteger(data.memory_bytes)||data.memory_bytes<0||data.memory_bytes>128*1024*1024){unknown(s);return;}
 s.receiving=true;worker.terminate();try{const value=await result(data.result,identity,database,expected);if(current!==s||s.generation!==generation||document.hidden)return;
 if(finish(s,expected?'bound':'proposal',expected?'이 기기에 정확한 인계 요청 연결을 저장했습니다. 아직 대화 참여 권한은 없습니다.':'이 기기에 암호화된 키와 공개 요청을 저장했습니다.')){publicResult=value;$('public-result').textContent=JSON.stringify(value,null,2);controls();}}
 catch{unknown(s);}
 };
});
$('export').addEventListener('click',()=>{if(!publicResult||current||document.hidden)return;const url=URL.createObjectURL(new Blob([JSON.stringify(publicResult,null,2)+'\n'],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='candidate-public-request.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);});
for(const id of ['identity','action'])$(id).addEventListener('change',reset);$('database').addEventListener('input',reset);
for(const id of ['password','consent','confirmation'])$(id).addEventListener('input',controls);
$('lock').addEventListener('click',()=>{stop(true);accepted=null;$('confirmation').value='';controls();});channel.onmessage=e=>{if(e.data==='lock'){stop();accepted=null;$('confirmation').value='';controls();}};
function hidden(){stop();accepted=null;$('confirmation').value='';controls();}
document.addEventListener('visibilitychange',()=>{if(document.hidden)hidden();});addEventListener('pagehide',hidden);controls();
