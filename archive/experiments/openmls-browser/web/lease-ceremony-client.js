// Only public results from the selected original protected lease worker.
export {exact,scope,request} from './confirmation-ceremony-client.js';
import {exact,scope} from './confirmation-ceremony-client.js';
import {freeze} from './peer-preparation-client.js';
const KINDS=['activate','sync','send'],STATUSES=['empty','pending','blocked-capacity'];
const id=v=>typeof v==='string'&&/^[a-zA-Z0-9_-]{1,64}$/.test(v);
function messages(v){
 if(!Array.isArray(v)||v.length>64)throw Error('received');
 let last=0;const out=[];
 for(const x of v){
  if(!exact(x,'seq,text')||!Number.isInteger(x.seq)||x.seq<=last||x.seq>64||typeof x.text!=='string'||new TextEncoder().encode(x.text).length>256)throw Error('message');
  last=x.seq;out.push({seq:x.seq,text:x.text});
 }
 return out;
}
export function operation(kind,messageId,text){
 if(!KINDS.includes(kind))throw Error('kind');
 if(kind!=='send')return {kind};
 if(!id(messageId)||typeof text!=='string'||!text.length||new TextEncoder().encode(text).length>256)throw Error('send');
 return {kind:'send',id:messageId,text};
}
export async function result(value,identity,database,role,action,expected){
 if(!scope(identity,database,role)||!KINDS.includes(action)||!expected||!exact(value,'committed,role,received,phase,channel_full,outbox_status')||value.committed!==true||value.role!==role)throw Error('result');
 const received=messages(value.received),phase=value.phase,full=value.channel_full,box=value.outbox_status;
 if(action==='activate'){
  if(!['awaiting-pair','leased'].includes(phase)||full!==null||received.length||box!=='empty')throw Error('activate');
 }else{
  if(phase!=='leased'||typeof full!=='boolean'||!STATUSES.includes(box)||(box==='blocked-capacity'&&full!==true))throw Error('channel');
 }
 const state=action==='activate'?phase:box==='blocked-capacity'?'channel-full':box==='pending'?'outbox-pending':'synchronized';
 return freeze({version:1,identity,database,reservation_id:expected.reservation_id,state,action,committed:true,role,phase,channel_full:full,outbox_status:box,received_count:received.length,last_seq:received.length?received[received.length-1].seq:0});
}
export function describe(v){return {
 'awaiting-pair':'이 기기의 시험 채널 승인을 저장했습니다. 상대 기기의 승인은 아직입니다.',
 'leased':'양쪽 기기가 시험 채널을 승인했습니다. 영구 등록과 기기 활성화는 별도입니다.',
 'synchronized':'시험 채널 상태를 확인했습니다. 대기 중인 보냄은 없습니다.',
 'outbox-pending':'시험 메시지를 이 기기에 저장했습니다. 서버 전송은 아직 확인되지 않았습니다.',
 'channel-full':'시험 채널이 가득 찼습니다. 저장한 보냄은 유지하고 받은 문장은 읽을 수 있습니다.'
}[v.state];}
export function publicExport(v){
 const {received,...rest}=v&&typeof v==='object'?v:{};
 void received;
 return rest;
}
export {messages as receivedMessages};
