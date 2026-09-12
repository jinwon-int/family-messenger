// Public status only. Original protected exchange workers own crypto and HTTP.
export {exact,scope,request} from './custody-ceremony-client.js';
import {exact,scope} from './custody-ceremony-client.js';
import {freeze} from './peer-preparation-client.js';
const group=v=>typeof v==='string'&&/^(?:[a-f0-9]{2}){16,128}$/.test(v);
export async function result(value,identity,database,role,action,expected){
 if(!scope(identity,database,role)||action!=='exchange'||!expected||!exact(value,'committed,role,phase,group_id,transcript_revision')||value.committed!==true||value.role!==role)throw Error('result');
 const v=structuredClone(value),n=v.transcript_revision;
 const allowed=role==='candidate'?{0:'key_package-prepared',1:'awaiting-welcome',2:'ack-prepared',3:'exchange-recorded-inactive'}:{0:'awaiting-key-package',1:'welcome-prepared',2:'awaiting-ack',3:'exchange-recorded-inactive'};
 if(!Number.isInteger(n)||n<0||n>3||v.phase!==allowed[n])throw Error('phase');
 const hasGroup=role==='candidate'?n>=2:n>=1;
 if(hasGroup?(!group(v.group_id)||v.group_id===expected.context.source_group):v.group_id!=='')throw Error('group');
 return freeze({version:1,identity,database,reservation_id:expected.reservation_id,state:v.phase,...v});
}
export function describe(v){
 const states={
  'awaiting-key-package':'이 기기에서 준비를 확인했습니다. 새 기기의 시작 정보 전송을 기다립니다.',
  'key_package-prepared':'이 기기에 시작 정보를 저장했습니다. 서버 전송은 아직 확인되지 않았습니다.',
  'awaiting-welcome':'서버에서 새 기기의 시작 정보를 확인했습니다. 상대 기기의 초대 전송을 기다립니다.',
  'welcome-prepared':'이 기기에 초대 정보를 저장했습니다. 서버 전송은 아직 확인되지 않았습니다.',
  'awaiting-ack':'서버에서 초대 전송을 확인했습니다. 새 기기의 수신 확인을 기다립니다.',
  'ack-prepared':'이 기기에 초대 수신과 수신 확인 정보를 저장했습니다. 서버 전송은 아직 확인되지 않았습니다.',
  'exchange-recorded-inactive':v.role==='candidate'?'이 기기에 초대 수신을 저장했고 서버에서 수신 확인을 기록했습니다. 양쪽 개인키 검증과 기기 등록은 별도입니다.':'서버의 수신 확인을 이 기기에 저장했습니다. 상대 기기의 개인키 검증과 기기 등록은 별도입니다.'
 };return states[v.phase];
}
