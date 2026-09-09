// Generated-data qualification only: never serve as a native keystore.
import {Encrypter, Decrypter} from 'age-encryption';
let sodium, wasmCalls = 0;
const wasmMemories = [];
const originalInstantiate = WebAssembly.instantiate;
// Test-only backend observation, before dynamic library initialization. No
// cryptographic input/output is changed; the shipped library bytes stay pinned.
WebAssembly.instantiate = async (...args) => {
  const result = await originalInstantiate(...args); wasmCalls++;
  for (const value of Object.values((result.instance ?? result).exports)) {
    if (value instanceof WebAssembly.Memory) wasmMemories.push(value);
  }
  return result;
};
try {
  ({default:sodium} = await import('libsodium-wrappers'));
  await sodium.ready;
  if (wasmCalls < 1 || !wasmMemories.some(m=>m.buffer===sodium.libsodium.HEAPU8.buffer) || sodium.libsodium.HEAPU8.length > 128*1024*1024) throw Error('backend');
} catch { self.postMessage({type:'denied'}); self.close(); throw Error('library unavailable'); }
finally { WebAssembly.instantiate = originalInstantiate; }
let root = null, busy = false, retired = false, count = 0;
const encode = new TextEncoder();
const dummy = () => new Uint8Array(2048).fill(42);
function exact(object, fields) {
  if (!object || typeof object !== 'object' || Array.isArray(object) || Object.keys(object).sort().join(',') !== fields.split(',').sort().join(',')) throw Error('shape');
}
function bytes(value, min, max=min) {
  if (!Array.isArray(value) || value.length < min || value.length > max || !value.every(x=>Number.isInteger(x)&&x>=0&&x<=255)) throw Error('bytes');
  return new Uint8Array(value);
}
function vaultID(id) { if (typeof id !== 'string' || !/^[0-9a-f]{32}$/.test(id)) throw Error('vault'); return id; }
function pass(s) { if (typeof s !== 'string' || s.length<32 || s.length>128) throw Error('password'); return s; }
function metadata(id, revision) {
  if (typeof id !== 'string' || !/^[a-z0-9-]{1,64}$/.test(id) || !Number.isSafeInteger(revision) || revision<1) throw Error('metadata');
  return encode.encode(JSON.stringify(['family-session-record',1,root.id,id,revision]));
}
function retire() { retired=true; if(root) sodium.memzero(root.key); root=null; self.close(); }
async function admitted(ciphertext) {
  const accepted={}; const inspector=new Decrypter();
  inspector.addIdentity({unwrapFileKey(stanzas) {
    if(stanzas.length!==1 || stanzas[0].args.length!==3 || stanzas[0].args[0]!=='scrypt' || stanzas[0].args[2]!=='18' || stanzas[0].body.length!==32) throw Error('work policy');
    throw accepted;
  }});
  try { await inspector.decrypt(ciphertext); } catch(error) { if(error===accepted) return; }
  throw Error('admission');
}
self.onmessage=async ({data})=>{
  if(retired) return;
  if(busy || count>=32) {self.postMessage({type:'denied'});retire();return;}
  busy=true;count++;
  const started=performance.now();
  try {
    let result;
    if(data?.op==='create') {
      exact(data,'op,password'); if(root) throw Error('phase'); const password=pass(data.password);
      const key=sodium.crypto_secretstream_xchacha20poly1305_keygen();
      const id=sodium.to_hex(sodium.randombytes_buf(16));
      try {
        const e=new Encrypter();e.setPassphrase(password);
        const payload=encode.encode(JSON.stringify([1,id,Array.from(key)]));
        self.postMessage({type:'kdf-start'});
        let capsule;
        try {capsule=await e.encrypt(payload);} finally {sodium.memzero(payload);}
        if(retired) throw Error('retired');
        root={id,key:key.slice()}; result={capsule:Array.from(capsule),vault:id};
      } finally {sodium.memzero(key);}
    } else if(data?.op==='unlock') {
      exact(data,'op,password,capsule,vault');if(root) throw Error('phase');
      const password=pass(data.password),expected=vaultID(data.vault),ciphertext=bytes(data.capsule,1,8192);
      await admitted(ciphertext); const d=new Decrypter();d.addPassphrase(password);
      self.postMessage({type:'kdf-start'});
      const plaintext=await d.decrypt(ciphertext);
      try {
        if(plaintext.length>1024) throw Error('capsule size');
        const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(plaintext));
        if(!Array.isArray(value)||value.length!==3||value[0]!==1||vaultID(value[1])!==expected) throw Error('capsule');
        const key=bytes(value[2],32);if(retired){sodium.memzero(key);throw Error('retired');}
        root={id:expected,key};result={opened:true};
      } finally {sodium.memzero(plaintext);}
    } else if(data?.op==='seal') {
      exact(data,'op,id,revision,fixture_tag');if(!root) throw Error('locked');
      const ad=metadata(data.id,data.revision);
      // Non-FINAL tags are fixture generation only, using public library APIs.
      // They must all be rejected by the saved-record reader below.
      if(!['FINAL','MESSAGE','PUSH','REKEY'].includes(data.fixture_tag)) throw Error('tag');
      const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(root.key);
      const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,dummy(),ad,sodium['crypto_secretstream_xchacha20poly1305_TAG_'+data.fixture_tag]);
      result={record:{header:Array.from(header),ciphertext:Array.from(cipher)}};
    } else if(data?.op==='read') {
      exact(data,'op,id,revision,record');if(!root) throw Error('locked');exact(data.record,'header,ciphertext');
      const ad=metadata(data.id,data.revision),header=bytes(data.record.header,24),cipher=bytes(data.record.ciphertext,2065);
      const state=sodium.crypto_secretstream_xchacha20poly1305_init_pull(header,root.key);
      const output=sodium.crypto_secretstream_xchacha20poly1305_pull(state,cipher,ad);
      if(!output) throw Error('authentication');
      try {
        if(output.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL || output.message.length!==2048 || !output.message.every(x=>x===42)) throw Error('final');
        result={matched:true};
      } finally {sodium.memzero(output.message);}
    } else if(data?.op==='status') {
      exact(data,'op');result={opened:!!root,commands:count,wasm:true,heap:sodium.libsodium.HEAPU8.length,version:sodium.sodium_version_string()};
    } else {throw Error('operation');}
    if(!retired) {
      self.postMessage({type:'done',...result,...(count===32?{retired:true}:{}),ms:Math.round((performance.now()-started)*1000)/1000});
      if(count===32) retire();
    }
  } catch {if(!retired) self.postMessage({type:'denied'});retire();}
  finally {busy=false;}
};
self.postMessage({type:'ready',wasm:true,heap:sodium.libsodium.HEAPU8.length});
