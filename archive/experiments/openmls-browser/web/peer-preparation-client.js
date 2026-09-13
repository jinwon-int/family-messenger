// Public input/output validation only; private custody stays in successor-peer-worker.
import {parseHandoff,LIMIT} from './successor-handoff.js';
export const exact=(v,keys)=>v&&Object.getPrototypeOf(v)===Object.prototype&&Object.keys(v).sort().join(',')===keys.split(',').sort().join(',');
const hash=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
export const scope=(identity,database)=>['alice','bob'].includes(identity)&&typeof database==='string'&&/^family-mls-device-vault-synthetic-[a-z0-9-]{1,64}$/.test(database);
export const digest=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
export const freeze=v=>{for(const x of Object.values(v))if(x&&typeof x==='object')freeze(x);return Object.freeze(v);};
const canonical=v=>v&&typeof v==='object'?(Array.isArray(v)?v.map(canonical):Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])]))):v;
export async function request(raw,identity,database){
 if(!scope(identity,database)||typeof raw!=='string'||raw.length>LIMIT)throw Error('request');
 const d=parseHandoff(raw);if(d.scopes.length!==1)throw Error('request');const s=d.scopes[0];
 if(s.role!=='peer'||s.identity!==identity||s.database!==database)throw Error('scope');
 const owned=freeze(s.reservation),fingerprint=await digest(Uint8Array.from(owned.context.candidate.signing_key.match(/../g),x=>parseInt(x,16)));
 if(fingerprint!==owned.context.candidate_fingerprint)throw Error('fingerprint');
 return {reservation:owned,sha256:await digest(new TextEncoder().encode(JSON.stringify(canonical(owned))))};
}
export async function result(value,identity,database,expected){
 if(!scope(identity,database)||!expected||!exact(value,'committed,phase,public_key,reservation_id,intent_id,room')||value.committed!==true||value.phase!=='inactive-peer-custody'||value.reservation_id!==expected.reservation_id||value.intent_id!==expected.context.intent_id||value.room!==expected.context.target_room||!Array.isArray(value.public_key)||value.public_key.length!==32||!value.public_key.every(x=>Number.isInteger(x)&&x>=0&&x<=255))throw Error('result');
 const pub=value.public_key.map(x=>x.toString(16).padStart(2,'0')).join('');if(pub!==expected.context.peer.signing_key)throw Error('binding');
 return freeze({version:1,identity,database,...structuredClone(value)});
}
