// Public hints and receipts only. Private custody and network operations stay in workers.
import {request as candidateRequest,result as candidateResult} from './candidate-preparation-client.js';
import {request as peerRequest,result as peerResult,exact,digest,freeze} from './peer-preparation-client.js';
export {exact};
const hash=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v),label=v=>typeof v==='string'&&/^[a-zA-Z0-9_-]{1,64}$/.test(v);
export const scope=(identity,database,role)=>['alice','bob'].includes(identity)&&['candidate','peer'].includes(role)&&typeof database==='string'&&(role==='candidate'?/^family-mls-candidate-synthetic-[a-z0-9-]{1,64}$/:/^family-mls-device-vault-synthetic-[a-z0-9-]{1,64}$/).test(database);
export async function request(raw,identity,database,role){if(!scope(identity,database,role))throw Error('scope');return (role==='candidate'?candidateRequest:peerRequest)(raw,identity,database);}
// Match the original protected reservation normalizer's public wire order. The
// independent human comparison digest still uses canonical sorted-key JSON.
function context(c){
 const pin=p=>({device_id:p.device_id,actor:p.actor,signing_key:p.signing_key,device_revision:p.device_revision});
 return {version:c.version,intent_id:c.intent_id,decision_revision:c.decision_revision,expires_at:c.expires_at,source_room:c.source_room,source_group:c.source_group,target_room:c.target_room,predecessor:pin(c.predecessor),candidate:pin(c.candidate),peer:pin(c.peer),candidate_fingerprint:c.candidate_fingerprint,package_sha256:c.package_sha256,admission:c.admission};
}
const sum=v=>digest(new TextEncoder().encode(JSON.stringify(v)));
export async function result(value,identity,database,role,action,expected){
 if(!scope(identity,database,role)||!expected||!['prepare','declare'].includes(action))throw Error('scope');
 if(action==='prepare'){
  const v=await (role==='candidate'?candidateResult:peerResult)(value,identity,database,expected);
  return freeze({version:1,identity,database,role,state:'prepared',committed:true,reservation_id:v.reservation_id});
 }
 if(!exact(value,'committed,own_declared,role,declaration_id,readiness')||value.committed!==true||value.own_declared!==true||value.role!==role||!hash(value.declaration_id))throw Error('declaration');
 // Own immutable receipt before asynchronous public hashing.
 const v=structuredClone(value),r=v.readiness,c=context(expected.context),contextHash=await sum(c);
 const id=await sum(['family-successor-custody-declaration',1,role,expected.reservation_id,contextHash,c[role].device_id]);
 if(v.declaration_id!==id||!exact(r,'version,reservation_id,context_sha256,revision,phase,declarations')||r.version!==1||r.reservation_id!==expected.reservation_id||r.context_sha256!==contextHash||![1,2].includes(r.revision)||!Array.isArray(r.declarations)||r.declarations.length!==r.revision||r.phase!==(r.revision===2?'pair-declared-inactive':'custody-pending'))throw Error('receipt');
 let previous='',own=false;for(const d of r.declarations){
  if(!exact(d,'role,declaration_id,device_id,reservation_id,context_sha256')||!['candidate','peer'].includes(d.role)||d.role<=previous||!label(d.declaration_id)||d.device_id!==c[d.role].device_id||d.reservation_id!==r.reservation_id||d.context_sha256!==contextHash)throw Error('slot');
  previous=d.role;if(d.role===role){if(d.declaration_id!==id)throw Error('id');own=true;}
 }
 if(!own)throw Error('own');return freeze({version:1,identity,database,role,state:r.revision===2?'pair-declared':'own-declared',...v});
}
