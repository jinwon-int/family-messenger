// Isolated read-only archive codec. Existing vault crypto format; no native I/O.
import {Decrypter} from 'age-encryption';
import sodium from 'libsodium-wrappers';
import init,{staged_public_key} from '/pkg/family_mls_browser_experiment.js';
import {validateHistoryState,normalizePins} from './history-state-v4.js';
const wasm=await init();await sodium.ready;
export const LIMIT=6*1024*1024;
const MAX=4*1024*1024,enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const fail=()=>{throw Error('history rejected')};
export const exact=(x,keys)=>x&&Object.getPrototypeOf(x)===Object.prototype&&Object.keys(x).sort().join(',')===keys.split(',').sort().join(',');
const byte=(x,max,min=1)=>{if(!(x instanceof Uint8Array)||!(x.buffer instanceof ArrayBuffer)||x.length<min||x.length>max)fail();return x;};
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
const b64=b=>{let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s)};
const unb64=(s,max,min=1)=>{if(typeof s!=='string'||s.length>Math.ceil(max/3)*4)fail();const b=Uint8Array.from(atob(s),c=>c.charCodeAt(0));byte(b,max,min);if(b64(b)!==s)fail();return b;};
export const memory=()=>{const n=wasm.memory.buffer.byteLength+sodium.libsodium.HEAPU8.byteLength;if(n>128*1024*1024)fail();return n;};
export function expectation(e){
 if(!exact(e,'database,identity,room,group_id,pins')||typeof e.database!=='string'||!/^family-mls-vault-synthetic-[a-z0-9-]{1,64}$/.test(e.database)||!['alice','bob'].includes(e.identity)||typeof e.room!=='string'||!/^[a-zA-Z0-9_-]{1,32}$/.test(e.room)||typeof e.group_id!=='string'||!/^(?:[a-f0-9]{2}){16,128}$/.test(e.group_id)||!Array.isArray(e.pins)||e.pins.length!==2)fail();
 e={...e,pins:normalizePins(e.pins)};
 return structuredClone(e);
}
export function outer(r,e){
 if(!exact(r,'v,identity,room,vault,revision,capsule,header,cipher')||r.v!==1||r.identity!==e.identity||r.room!==e.room||typeof r.vault!=='string'||!/^[a-f0-9]{32}$/.test(r.vault)||!Number.isSafeInteger(r.revision)||r.revision<1||r.revision>512)fail();
 byte(r.capsule,8192);byte(r.header,24,24);byte(r.cipher,MAX+17,17);
}
export function encodeArchive(r,e){
 outer(r,e);
 const value={format:'family-history-v1',database:e.database,state:{v:1,identity:r.identity,room:r.room,vault:r.vault,revision:r.revision,capsule:b64(r.capsule),header:b64(r.header),cipher:b64(r.cipher)}};
 const result=enc.encode(JSON.stringify(value));byte(result,LIMIT);return result;
}
export function decodeArchive(raw,e){
 byte(raw,LIMIT);if(raw.buffer.byteLength>LIMIT)fail();const x=JSON.parse(dec.decode(raw));
 if(!exact(x,'format,database,state')||x.format!=='family-history-v1'||x.database!==e.database||!exact(x.state,'v,identity,room,vault,revision,capsule,header,cipher'))fail();
 const r={...x.state,capsule:unb64(x.state.capsule,8192),header:unb64(x.state.header,24,24),cipher:unb64(x.state.cipher,MAX+17,17)};
 outer(r,e);const canonical=encodeArchive(r,e);if(raw.length!==canonical.length||!raw.every((v,i)=>v===canonical[i]))fail();return r;
}
async function admit(capsule){
 const accepted={},d=new Decrypter();d.addIdentity({unwrapFileKey(stanzas){if(stanzas.length!==1||stanzas[0].args.length!==3||stanzas[0].args[0]!=='scrypt'||stanzas[0].args[2]!=='18'||stanzas[0].body.length!==32)fail();throw accepted;}});
 try{await d.decrypt(capsule)}catch(e){if(e===accepted)return;}fail();
}
export async function history(r,e,password,live){
 outer(r,e);if(typeof password!=='string'||password.length<32||password.length>128)fail();
 await admit(r.capsule);live();const d=new Decrypter();d.addPassphrase(password);const capsule=await d.decrypt(r.capsule);password=null;live();let key;
 try{
  byte(capsule,2048);const p=JSON.parse(dec.decode(capsule));
  if(!Array.isArray(p)||p.length!==7||p[0]!==1||p[1]!==e.database||p[2]!==e.identity||p[3]!==e.room||p[4]!==r.vault||typeof p[5]!=='string'||!/^[a-f0-9]{64}$/.test(p[5])||!Array.isArray(p[6])||p[6].length!==32)fail();
  for(let i=0;i<32;i++)if(!Object.hasOwn(p[6],i)||!Number.isInteger(p[6][i])||p[6][i]<0||p[6][i]>255)fail();
  key=new Uint8Array(p[6]);p[6].fill(0);
  const state=sodium.crypto_secretstream_xchacha20poly1305_init_pull(r.header,key);
  const aad=enc.encode(JSON.stringify(['family-native-vault',1,e.database,e.identity,e.room,r.vault,r.revision]));
  const output=sodium.crypto_secretstream_xchacha20poly1305_pull(state,r.cipher,aad);
  if(!output)fail();
  try{
   if(output.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();byte(output.message,MAX);
   const record=JSON.parse(dec.decode(output.message));if(!record||typeof record.crypto!=='string')fail();record.crypto=unb64(record.crypto,1048576);
   try{
    if(sodium.to_hex(staged_public_key(record.crypto,e.identity))!==p[5])fail();
    const result=validateHistoryState(record,e);live();memory();return result;
   }finally{sodium.memzero(record.crypto);}
  }finally{sodium.memzero(output.message);}
 }finally{sodium.memzero(capsule);if(key)sodium.memzero(key);}
}
