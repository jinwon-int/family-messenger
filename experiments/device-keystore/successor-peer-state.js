// Restricted inactive custody metadata. This never makes a candidate active.
import {validateAggregate,validateRecord,publicKey} from './aggregate-state-v4.js';
import {exact,fail,name,hex,unhex,normalizePins} from '/trust-directory.js';
import {staged_checksum} from '/pkg/family_mls_browser_experiment.js';
const enc=new TextEncoder();
export const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const hash=s=>typeof s==='string'&&/^[a-f0-9]{64}$/.test(s);
function pin(p,revision){
 if(!exact(p,['device_id','actor','signing_key','device_revision'])||!name(p.device_id)||!['alice','bob'].includes(p.actor)||!hash(p.signing_key)||p.device_revision!==revision)fail();
 return {device_id:p.device_id,actor:p.actor,signing_key:p.signing_key,device_revision:revision};
}
export function reservation(value,identity){
 if(!exact(value,['version','reservation_id','context','phase'])||value.version!==1||!name(value.reservation_id)||value.phase!=='reserved-inactive')fail();
 const c=value.context;
 if(!exact(c,['version','intent_id','decision_revision','expires_at','source_room','source_group','target_room','predecessor','candidate','peer','candidate_fingerprint','package_sha256','admission'])||c.version!==1||!name(c.intent_id)||!Number.isSafeInteger(c.decision_revision)||c.decision_revision<1||!Number.isSafeInteger(c.expires_at)||c.expires_at<1||!name(c.source_room)||!name(c.target_room)||c.source_room===c.target_room||typeof c.source_group!=='string'||!/^(?:[a-f0-9]{2}){16,128}$/.test(c.source_group)||!hash(c.package_sha256)||c.admission!=='preflight-only')fail();
 // Descriptor carries the immutable historical room pin (revision 1).
 // The signed reservation authority separately requires its current tombstone 2.
 const predecessor=pin(c.predecessor,1),candidate=pin(c.candidate,1),peer=pin(c.peer,1);
 if(peer.actor!==identity||candidate.actor!==predecessor.actor||peer.actor===candidate.actor||new Set([predecessor.device_id,candidate.device_id,peer.device_id]).size!==3||new Set([predecessor.signing_key,candidate.signing_key,peer.signing_key]).size!==3||c.candidate_fingerprint!==hex(staged_checksum(unhex(candidate.signing_key))))fail();
 const result={version:1,reservation_id:value.reservation_id,context:{version:1,intent_id:c.intent_id,decision_revision:c.decision_revision,expires_at:c.expires_at,source_room:c.source_room,source_group:c.source_group,target_room:c.target_room,predecessor,candidate,peer,candidate_fingerprint:c.candidate_fingerprint,package_sha256:c.package_sha256,admission:'preflight-only'},phase:'reserved-inactive'};
 if(enc.encode(JSON.stringify(result)).length>4096)fail();return result;
}
export function pair(c,target=false){
 return normalizePins([target?c.candidate:c.predecessor,c.peer].map(p=>({...p,device_revision:1,fingerprint:hex(staged_checksum(unhex(p.signing_key)))})));
}
export function validatePeer(a,identity,expected){
 const c=expected.context;
 if(a?.version===1){
  validateAggregate(a,identity);if(a.rooms.length!==1||a.fork!==null)fail();
 }else{
  if(!exact(a,['version','identity','primary_room','rooms','successor'])||a.version!==2||a.identity!==identity||a.primary_room!==c.source_room||!Array.isArray(a.rooms)||a.rooms.length!==2||!same(reservation(a.successor,identity),expected))fail();
  const source=a.rooms[0],target=a.rooms[1];
  if(validateRecord(source,identity)+validateRecord(target,identity)>2*1024*1024||publicKey(source)!==publicKey(target)||target.room!==c.target_room||target.group!==''||target.binding!==null||!same(target.pins,pair(c,true)))fail();
 }
 const source=a.rooms[0];
 if(a.primary_room!==c.source_room||source.room!==c.source_room||!source.binding||source.group!==c.source_group||source.phase!=='ready'||source.pending?.retired||!same(source.pins,pair(c))||publicKey(source)!==c.peer.signing_key)fail();
 return publicKey(source);
}
