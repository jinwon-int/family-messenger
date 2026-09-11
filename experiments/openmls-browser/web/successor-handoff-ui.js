import {installScopes} from './successor-ui.js';
import {LIMIT,STORAGE_KEY,parseHandoff} from './successor-handoff.js';
const $=id=>document.getElementById(id);let generation=0,documentText=null;
const say=s=>{$('handoff-status').textContent=s;};
function clear(){generation++;documentText=null;$('handoff-save').disabled=true;$('handoff-file').value='';$('action').value='';installScopes([]);}
function cancel(){clear();say('잠겼습니다. 요청을 다시 불러오세요.');}
function accept(raw,g){
 if(g!==generation||document.hidden)return;
 const doc=parseHandoff(raw);installScopes(doc.scopes);documentText=JSON.stringify(doc);$('handoff-save').disabled=false;
 say('공개 요청 목록을 불러왔습니다. 권한은 아직 확인하지 않았습니다. 대화와 작업을 직접 선택하세요.');
}
$('handoff-import').addEventListener('click',async()=>{
 const file=$('handoff-file').files?.[0];clear();const g=generation;
 try{if(!file||file.size>LIMIT)throw Error();say('요청 파일을 읽고 있습니다.');accept(await file.text(),g);}
 catch{if(g===generation)say('요청 파일을 불러올 수 없습니다. 형식과 크기를 확인하세요.');}
});
$('handoff-load').addEventListener('click',()=>{clear();try{accept(localStorage.getItem(STORAGE_KEY),generation);}catch{say('보관된 요청을 불러올 수 없습니다. 원래 요청 파일을 확인하세요.');}});
$('handoff-save').addEventListener('click',()=>{
 if(!documentText||document.hidden)return;
 try{const raw=JSON.stringify(parseHandoff(documentText));localStorage.setItem(STORAGE_KEY,raw);say('공개 요청 목록을 보관했습니다. 재시작 뒤 불러오기 버튼으로 확인하세요. 비밀번호와 개인키는 포함하지 않습니다.');}
 catch{say('요청 목록을 보관하지 못했습니다. 원래 요청 파일을 보관하세요.');}
});
// Cancellation invalidates file reads as well as lifecycle workers. Persisted
// public hints survive lock, while the active selection and credentials do not.
$('lock').addEventListener('click',cancel);
const channel=new BroadcastChannel('family-vault-ui-lock-v1');channel.onmessage=e=>{if(e.data==='lock')cancel();};
document.addEventListener('visibilitychange',()=>{if(document.hidden)cancel();});addEventListener('pagehide',cancel);
