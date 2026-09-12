// Only public results from the selected original protected confirmation worker.
export {exact,scope,request} from './custody-ceremony-client.js';
import {exact,scope} from './custody-ceremony-client.js';
import {freeze} from './peer-preparation-client.js';
export async function result(value,identity,database,role,action,expected){
 if(!scope(identity,database,role)||action!=='confirm'||!expected||!exact(value,'committed,role,peer_verified,phase,group_id,transcript_revision')||value.committed!==true||value.role!==role)throw Error('result');
 const v=structuredClone(value),n=v.transcript_revision;
 if(!Number.isInteger(n)||n<0||n>2||typeof v.peer_verified!=='boolean'||typeof v.group_id!=='string'||!/^(?:[a-f0-9]{2}){16,128}$/.test(v.group_id)||v.group_id===expected.context.source_group)throw Error('scope');
 const verified=role==='candidate'?n===2:n>=1;
 const phase=verified?'peer-verified-inactive':n===0?'awaiting-candidate-proof':'awaiting-peer-proof';
 if(v.peer_verified!==verified||v.phase!==phase)throw Error('phase');
 // Peer local verification at revision 1 precedes acceptance of its reply.
 const state=role==='candidate'?['candidate-saved','candidate-recorded','candidate-verified'][n]:['awaiting-candidate','peer-reply-saved','peer-reply-recorded'][n];
 return freeze({version:1,identity,database,reservation_id:expected.reservation_id,state,...v});
}
export function describe(v){return {
 'candidate-saved':'이 기기에 확인 정보를 저장했습니다. 서버 전송은 아직 확인되지 않았습니다.',
 'candidate-recorded':'서버에서 이 기기의 확인 정보를 기록했습니다. 상대 기기의 응답 검증은 아직입니다.',
 'candidate-verified':'이 기기에서 상대의 암호화 응답을 검증하고 저장했습니다. 기기 등록과 대화 활성화는 별도입니다.',
 'awaiting-candidate':'이 기기의 저장 상태를 확인했습니다. 새 기기의 암호화 확인 정보를 기다립니다.',
 'peer-reply-saved':'이 기기에서 새 기기의 암호문을 검증하고 응답을 저장했습니다. 응답의 서버 기록은 아직 확인되지 않았습니다.',
 'peer-reply-recorded':'이 기기에서 새 기기의 암호문을 검증했고 서버에서 응답을 기록했습니다. 새 기기가 응답 검증까지 저장했는지는 이 화면에서 확인할 수 없습니다.'
}[v.state];}
