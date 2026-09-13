// Public input/output validation only; private custody stays in candidate-worker.
import {parseHandoff,LIMIT} from './successor-handoff.js';
export const exact=(v,keys)=>v&&Object.getPrototypeOf(v)===Object.prototype&&Object.keys(v).sort().join(',')===keys.split(',').sort().join(',');
const hash=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
export const scope=(identity,database)=>['alice','bob'].includes(identity)&&typeof database==='string'&&/^family-mls-candidate-synthetic-[a-z0-9-]{1,64}$/.test(database);
export const digest=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
export const freeze=v=>{for(const x of Object.values(v))if(x&&typeof x==='object')freeze(x);return Object.freeze(v);};
const canonical=v=>v&&typeof v==='object'?(Array.isArray(v)?v.map(canonical):Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])]))):v;
export async function request(raw,identity,database){
 if(!scope(identity,database)||typeof raw!=='string'||raw.length>LIMIT)throw Error('request');
 const d=parseHandoff(raw);if(d.scopes.length!==1)throw Error('request');const s=d.scopes[0];
 if(s.role!=='candidate'||s.identity!==identity||s.database!==database)throw Error('scope');
 const owned=freeze(s.reservation),fingerprint=await digest(Uint8Array.from(owned.context.candidate.signing_key.match(/../g),x=>parseInt(x,16)));
 if(fingerprint!==owned.context.candidate_fingerprint)throw Error('fingerprint');
 return {reservation:owned,sha256:await digest(new TextEncoder().encode(JSON.stringify(canonical(owned))))};
}
export async function result(value,identity,database,expected){
 if(!scope(identity,database)||!exact(value,'committed,phase,public_key,package,package_sha256,reservation_id')||value.committed!==true||!hash(value.public_key)||!hash(value.package_sha256)||typeof value.package!=='string'||!/^(?:[a-f0-9]{2}){1,65536}$/.test(value.package))throw Error('result');
 if(value.phase!==(expected?'inactive-candidate-custody':'unassigned-proposal')||value.reservation_id!==(expected?.reservation_id??null))throw Error('phase');
 const copy=structuredClone(value);
 if(expected&&(copy.public_key!==expected.context.candidate.signing_key||copy.package_sha256!==expected.context.package_sha256))throw Error('binding');
 if(await digest(Uint8Array.from(copy.package.match(/../g),x=>parseInt(x,16)))!==copy.package_sha256)throw Error('package');
 return freeze({version:1,identity,database,...copy});
}
