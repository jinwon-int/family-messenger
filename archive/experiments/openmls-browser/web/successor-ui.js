// Isolated UI integration point: a preceding ceremony supplies public scopes.
// Selection does not confer trust; each worker revalidates real private custody.
const $=id=>document.getElementById(id),enc=new TextEncoder();
const exact=(v,keys)=>v&&Object.getPrototypeOf(v)===Object.prototype&&Object.keys(v).sort().join(',')===[...keys].sort().join(',');
const freeze=v=>{for(const x of Object.values(v))if(x&&typeof x==='object')freeze(x);return Object.freeze(v);};
const actions=['enroll','enrollment-observe','closure-close','closure-observe'];
const states={active:'관리자 승인이 확인되어 이 대화에 참여할 수 있습니다.','awaiting-admin':'양쪽 참여 동의가 확인됐습니다. 관리자 승인을 기다립니다.','awaiting-peer':'내 참여 동의가 확인됐습니다. 상대방의 동의를 기다립니다.','local-saved':'이 기기에 참여 동의가 저장됐습니다. 서버에서는 아직 확인되지 않았습니다.',closed:'서버에서 대화 종료를 확인했습니다. 양쪽 모두 이 대화에 더 이상 전송할 수 없습니다.','local-closed':'이 기기에서 대화 종료를 저장했습니다. 서버 종료는 아직 확인되지 않았습니다.'};
let scopes=[],current=null,generation=0;const channel=new BroadcastChannel('family-vault-ui-lock-v1');
const mutation=()=>['enroll','closure-close'].includes($('action').value);
function renderState(state,text){$('status').dataset.state=state;$('status').textContent=text;}
function controls(){const busy=!!current;for(const id of ['scope','action','password','consent'])$(id).disabled=busy;$('run').disabled=busy||!$('scope').value||!actions.includes($('action').value)||!$('password').value||(mutation()&&!$('consent').checked);}
function stop(text='잠겼습니다. 작업을 다시 선택해 주세요.',broadcast=false){const s=current;current=null;generation++;if(s){clearTimeout(s.timer);s.argument.password=null;s.worker.terminate();} $('password').value='';$('consent').checked=false;renderState(s?'unknown':'locked',s?'작업을 중단했습니다. 저장·서버 결과는 확인되지 않았습니다. 상태 확인을 선택해 확인하세요.':text);controls();if(broadcast)channel.postMessage('lock');}
function selected(){stop('대화와 작업을 확인하세요.');const s=scopes[Number($('scope').value)-1];$('selection').textContent=s?s.reservation.context.target_room+' · '+s.reservation.context[s.role].device_id:'준비된 요청이 없습니다.';$('consent-row').hidden=!mutation();$('effect').textContent=$('action').value==='closure-close'?'종료하면 상대방도 이 대화에 더 이상 전송할 수 없으며 되돌릴 수 없습니다. 보관된 대화는 삭제하지 않습니다.':$('action').value==='enroll'?'이 대화의 지속적인 참여에 동의합니다. 상대방의 동의와 관리자 승인 전에는 사용할 수 없습니다.':'상태 확인은 보관된 요청을 다시 전송하지 않습니다.';controls();}
export function installScopes(input){
 stop('대화와 작업을 선택하세요.');scopes=[];$('scope').replaceChildren(new Option('준비된 요청을 선택하세요',''));$('scope').value='';$('selection').textContent='준비된 요청이 없습니다.';
 if(!Array.isArray(input)||input.length>8||enc.encode(JSON.stringify(input)).length>256*1024)throw Error('scopes');
 const copy=structuredClone(input),seen=new Set();for(const s of copy){
  if(!exact(s,['identity','role','database','reservation'])||!['alice','bob'].includes(s.identity)||!['candidate','peer'].includes(s.role)||typeof s.database!=='string'||!/^[a-zA-Z0-9_-]{1,128}$/.test(s.database)||!s.reservation?.context||typeof s.reservation.context.target_room!=='string'||s.reservation.context.target_room.length>64||!s.reservation.context[s.role]||typeof s.reservation.context[s.role].device_id!=='string')throw Error('scope');
  const key=s.identity+'|'+s.role+'|'+s.database;if(seen.has(key))throw Error('duplicate');seen.add(key);
 }
 scopes=freeze(copy);for(const [i,s] of scopes.entries())$('scope').add(new Option(s.reservation.context.target_room+' · '+(s.role==='candidate'?'새 기기':'기존 참여 기기'),String(i+1)));selected();
}
function finish(s,state,text){if(current!==s||generation!==s.generation)return;clearTimeout(s.timer);s.argument.password=null;s.worker.terminate();current=null;$('password').value='';$('consent').checked=false;renderState(state,text+' · '+new Date().toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})+' KST 확인');controls();}
function unknown(s,committed=false){finish(s,'unknown',committed?'이 기기에 저장한 상태는 보존했습니다. 서버 결과는 확인되지 않았습니다. 상태 확인으로 확인하세요.':'저장·서버 상태를 확인할 수 없습니다. 비밀번호 또는 권한이 변경됐을 수 있습니다. 상태 확인으로 확인하세요.');}
$('lifecycle-form').addEventListener('submit',event=>{event.preventDefault();if(current||$('run').disabled||document.hidden)return;
 const scope=scopes[Number($('scope').value)-1],kind=$('action').value;let password=$('password').value;$('password').value='';$('consent').checked=false;
 if(!scope||!actions.includes(kind))return;const argument={identity:scope.identity,database:scope.database,password,intent:{accepted:true,reservation:structuredClone(scope.reservation)},kind};password=null;
 let worker;try{worker=new Worker('/'+scope.role+'-lifecycle-worker.js',{type:'module'});}catch{argument.password=null;renderState('unknown','작업을 시작할 수 없습니다. 상태를 다시 확인해 주세요.');controls();return;}const s={worker,argument,generation:++generation,timer:null,booted:false,committed:false};current=s;controls();
 renderState('working','선택한 작업을 확인하고 있습니다.');s.timer=setTimeout(()=>unknown(s,s.committed),60000);
 worker.onerror=()=>unknown(s,s.committed);worker.onmessage=({data})=>{if(current!==s||generation!==s.generation)return;
  if(exact(data,['boot'])&&data.boot===true&&!s.booted){s.booted=true;try{worker.postMessage({id:1,method:'lifecycle',argument:s.argument});}catch{unknown(s);return;}finally{s.argument.password=null;}return;}
  if(exact(data,['id','progress'])&&data.id===1&&data.progress==='local-committed'&&s.booted){s.committed=true;renderState('local-committed','이 기기의 저장을 확인했습니다. 서버 결과를 확인하고 있습니다.');return;}
  if(exact(data,['id','ok','state'])&&data.id===1&&data.ok===true&&s.committed&&Object.hasOwn(states,data.state)){if((kind.startsWith('closure'))!==['closed','local-closed'].includes(data.state)){unknown(s,s.committed);return;}finish(s,data.state,states[data.state]);return;}
  if(exact(data,['id','ok','committed'])&&data.id===1&&data.ok===false&&typeof data.committed==='boolean'){unknown(s,s.committed||data.committed);return;}unknown(s,s.committed);
 };
});
for(const id of ['scope','action'])$(id).addEventListener('change',selected);for(const id of ['password','consent'])$(id).addEventListener('input',controls);
$('lock').addEventListener('click',()=>stop(undefined,true));channel.onmessage=e=>{if(e.data==='lock')stop();};document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();});addEventListener('pagehide',()=>stop());controls();
