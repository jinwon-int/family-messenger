// Public hints only. The unchanged custody workers remain the authority gate.
export const LIMIT=32768, STORAGE_KEY='family-successor-public-handoff-v1';
const exact=(v,keys)=>v&&Object.getPrototypeOf(v)===Object.prototype&&Object.keys(v).sort().join(',')===keys.split(',').sort().join(',');
const label=v=>typeof v==='string'&&/^[a-zA-Z0-9_-]{1,64}$/.test(v),hash=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
const integer=v=>Number.isSafeInteger(v)&&v>0,actor=v=>['alice','bob'].includes(v);
const fail=()=>{throw Error('invalid public handoff');};
function pin(p){if(!exact(p,'actor,device_id,device_revision,signing_key')||!actor(p.actor)||!label(p.device_id)||p.device_revision!==1||!hash(p.signing_key))fail();}
export function parseHandoff(raw){
 if(typeof raw!=='string'||raw.length>LIMIT||new TextEncoder().encode(raw).length>LIMIT)fail();
 const d=JSON.parse(raw);if(!exact(d,'version,scopes')||d.version!==1||!Array.isArray(d.scopes)||!d.scopes.length||d.scopes.length>8)fail();
 const seen=new Set();for(const s of d.scopes){
  if(!exact(s,'identity,role,database,reservation')||!actor(s.identity)||!['candidate','peer'].includes(s.role)||typeof s.database!=='string'||!/^[a-zA-Z0-9_-]{1,128}$/.test(s.database))fail();
  const r=s.reservation;if(!exact(r,'version,reservation_id,context,phase')||r.version!==1||!label(r.reservation_id)||r.phase!=='reserved-inactive')fail();
  const c=r.context;if(!exact(c,'version,intent_id,decision_revision,expires_at,source_room,source_group,target_room,predecessor,candidate,peer,candidate_fingerprint,package_sha256,admission')||c.version!==1||!label(c.intent_id)||!integer(c.decision_revision)||!integer(c.expires_at)||!label(c.source_room)||!label(c.target_room)||c.source_room===c.target_room||typeof c.source_group!=='string'||!/^(?:[a-f0-9]{2}){16,128}$/.test(c.source_group)||!hash(c.package_sha256)||!hash(c.candidate_fingerprint)||c.admission!=='preflight-only')fail();
  for(const p of [c.predecessor,c.candidate,c.peer])pin(p);
  if(c[s.role].actor!==s.identity||c.candidate.actor!==c.predecessor.actor||c.peer.actor===c.candidate.actor||new Set([c.predecessor.device_id,c.candidate.device_id,c.peer.device_id]).size!==3||new Set([c.predecessor.signing_key,c.candidate.signing_key,c.peer.signing_key]).size!==3)fail();
  const key=[s.identity,s.role,s.database].join('|');if(seen.has(key))fail();seen.add(key);
 }
 // No extensions are retained: secrets, endpoints and worker URLs are rejected.
 // Historical expiry is deliberately accepted as a hint for terminal closure.
 return d;
}
