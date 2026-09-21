// Development-only synthetic keys in IndexedDB. No production key protection.
import init, {staged_init, staged_trusted_apply, staged_epoch, staged_checksum, staged_public_key, staged_group_id, staged_check_trust} from './pkg/family_mls_browser_experiment.js';
import {normalizePins, readDirectory, matchDirectory} from './trust-directory.js';
const wasm = await init();
const MAX_STATE = 1024 * 1024, MAX_BINARY = 2 * 1024 * 1024, MAX_LEDGER = 32;
const allowed = new Set(['key_package', 'create', 'invite', 'join', 'encrypt', 'decrypt']);
let db, identity, room, retired=false;
const fail = () => { throw new Error('rejected'); };
const exact = (value, keys) => value && Object.getPrototypeOf(value) === Object.prototype &&
  Object.keys(value).sort().join(',') === keys.sort().join(',');
const equal = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
function input(value) {
  if (!Array.isArray(value) || value.length > 65536 || !value.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) fail();
  return new Uint8Array(value);
}
// Fixed field order and byte hex encoding; no host-dependent object serialization.
const toHex=b=>Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
const fromHex=s=>new Uint8Array(s.match(/../g).map(x=>parseInt(x,16)));
function checksum(record) {
  const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  const encoded = JSON.stringify(['family-mls-trusted-state-v2', record.version, record.identity, record.room, record.pins, record.group_id,
    record.revision, record.cursor, record.epoch, hex(record.crypto),
    record.ledger.map(x => [x.id, x.method, x.sequence, x.epoch, hex(x.input), hex(x.output)])]);
  return staged_checksum(new TextEncoder().encode(encoded));
}
function valid(record, verifyChecksum = true) {
  if (!exact(record, ['version', 'identity', 'revision', 'crypto', 'ledger', 'cursor', 'epoch', 'checksum', 'room', 'pins', 'group_id']) || record.version !== 2 ||
      record.identity !== identity || record.room !== room || typeof record.group_id !== 'string' || record.group_id.length>256 || typeof record.epoch !== 'string' || record.epoch.length > 20 ||
      !(record.checksum instanceof Uint8Array) || record.checksum.length !== 32 || !Number.isSafeInteger(record.revision) || record.revision < 1 ||
      !Number.isSafeInteger(record.cursor) || record.cursor < 0 ||
      !(record.crypto instanceof Uint8Array) || !record.crypto.length || record.crypto.length > MAX_STATE ||
      !Array.isArray(record.ledger) || record.ledger.length > MAX_LEDGER || record.revision !== record.ledger.length + 1 + (record.pins===null?0:1)) fail();
  let size = record.crypto.length, cursor = 0;
  const ids = new Set();
  for (const item of record.ledger) {
    if (!exact(item, ['id', 'method', 'input', 'output', 'sequence', 'epoch']) ||
        typeof item.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(item.id) || ids.has(item.id) || !allowed.has(item.method) || typeof item.epoch !== 'string' || item.epoch.length > 20 ||
        !(item.input instanceof Uint8Array) || item.input.length > 65536 ||
        !(item.output instanceof Uint8Array) || item.output.length > 65536 ||
        !Number.isSafeInteger(item.sequence) || item.sequence < 0) fail();
    if (item.method === 'decrypt' ? item.sequence !== ++cursor : item.sequence !== 0) fail();
    ids.add(item.id); size += item.input.length + item.output.length;
  }
  if(record.pins!==null) {
    const pins=normalizePins(record.pins);
    if(JSON.stringify(pins)!==JSON.stringify(record.pins))fail();
    const own=pins.find(x=>x.actor===identity),peer=pins.find(x=>x.actor!==identity);
    if(own.signing_key!==toHex(staged_public_key(record.crypto,identity)))fail();
    staged_check_trust(record.crypto,identity,peer.actor,fromHex(peer.signing_key));
  } else if(record.ledger.length!==0 || record.group_id!=='' || record.epoch!=='none')fail();
  if(record.group_id!==toHex(staged_group_id(record.crypto,identity)))fail();
  if (cursor !== record.cursor || size > MAX_BINARY) fail();
  if (verifyChecksum && !equal(record.checksum, checksum(record))) fail();
  if (staged_epoch(record.crypto, identity) !== record.epoch) fail();
}
function open(name) {
  if (typeof name !== 'string' || !/^family-mls-trusted-synthetic-[a-z0-9-]{1,64}$/.test(name)) fail();
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = event => {
      if (event.oldVersion !== 0) { request.transaction.abort(); return; }
      request.result.createObjectStore('device').add({version: 0, identity, room}, 'state');
    };
    request.onerror = () => reject(new Error('state unavailable'));
    request.onblocked = () => reject(new Error('state blocked'));
    request.onsuccess = () => {
      const opened = request.result;
      if (opened.objectStoreNames.length !== 1 || !opened.objectStoreNames.contains('device')) {
        opened.close(); reject(new Error('unknown schema')); return;
      }
      opened.onversionchange = () => opened.close();
      resolve(opened);
    };
  });
}
function transaction(operation, argument, directory) {
  return new Promise((resolve, reject) => {
    // Cross-tab read/write transactions serialize the complete read-modify-write.
    const tx = db.transaction('device', 'readwrite', {durability: 'strict'});
    const store = tx.objectStore('device');
    let response, fault;
    const abort = () => { try { tx.abort(); } catch (_) {} };
    tx.onerror = () => {}; // onabort is the single failure result.
    tx.onabort = () => reject(new Error('transaction rejected'));
    tx.oncomplete = () => {
      // Test-only lost-response fault. Durable state may now contain the operation.
      if (fault !== 'lost-response') resolve(response);
    };
    const keys = store.getAllKeys(undefined, 2);
    keys.onsuccess = () => {
      if (keys.result.length > 1 || (keys.result.length && keys.result[0] !== 'state')) { abort(); return; }
      const get = store.get('state');
      get.onsuccess = () => {
        try {
          let record = get.result;
          if (operation === 'initialize') {
            if (exact(record, ['version', 'identity', 'room']) && record.version === 0 && record.identity === identity && record.room===room) {
              if(directory.devices.some(x=>x.actor===identity))fail();
              record = {version: 2, identity, room, pins:null, group_id:'', revision: 1, crypto: staged_init(identity), ledger: [], cursor: 0, epoch: 'none', checksum: new Uint8Array(32)};
              valid(record, false); record.checksum = checksum(record); valid(record); store.put(record, 'state');
            } else valid(record);
            current(record,directory);
            response = publicStatus(record);
            return;
          }
          valid(record);current(record,directory);
          if(operation==='pin') {
            if(!exact(argument,['pins','fault'])||!['','abort-before-write','abort-after-write','lost-response'].includes(argument.fault))fail();
            const pins=normalizePins(argument.pins);matchDirectory(pins,directory);fault=argument.fault;
            if(record.pins!==null){if(JSON.stringify(record.pins)!==JSON.stringify(pins))fail();response=publicStatus(record);return;}
            record.pins=pins;record.revision++;valid(record,false);record.checksum=checksum(record);valid(record);
            if(fault==='abort-before-write'){abort();return;}
            store.put(record,'state');
            if(fault==='abort-after-write'){abort();return;}
            response=publicStatus(record);return;
          }
          if (operation === 'status') {
            response = publicStatus(record);
            return;
          }
          if(record.pins===null)fail();
          if (!exact(argument, ['id', 'method', 'bytes', 'sequence', 'fault']) ||
              typeof argument.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(argument.id) || !allowed.has(argument.method) ||
              !Number.isSafeInteger(argument.sequence) || argument.sequence < 0 ||
              !['', 'abort-before-write', 'abort-after-write', 'lost-response'].includes(argument.fault)) fail();
          fault = argument.fault;
          const bytes = input(argument.bytes);
          const prior = record.ledger.find(x => x.id === argument.id);
          if (prior) {
            if (prior.method !== argument.method || prior.sequence !== argument.sequence || !equal(prior.input, bytes) ||
                (prior.method === 'encrypt' && prior.epoch !== record.epoch)) fail();
            response = {output: Array.from(prior.output), revision: record.revision, cursor: record.cursor, replay: true};
            return;
          }
          if (record.ledger.length >= MAX_LEDGER || record.revision >= Number.MAX_SAFE_INTEGER) fail();
          if (argument.method === 'decrypt' ? argument.sequence !== record.cursor + 1 : argument.sequence !== 0) fail();
          let candidate;
          try {
            // Synchronous WASM call inside the active IDB transaction callback.
            // It constructs a fresh provider; no candidate state survives an abort.
            const peer=record.pins.find(x=>x.actor!==identity);
            candidate = staged_trusted_apply(record.crypto, identity, argument.method, bytes, peer.actor, fromHex(peer.signing_key));
            record.crypto = candidate.state();
            const groupID=toHex(staged_group_id(record.crypto,identity));
            if(record.group_id && groupID!==record.group_id)fail();
            record.group_id=groupID;
            record.epoch = candidate.epoch();
            const output = candidate.output();
            record.ledger.push({id: argument.id, method: argument.method, input: bytes, output, sequence: argument.sequence, epoch: record.epoch});
            record.revision++;
            if (argument.method === 'decrypt') record.cursor = argument.sequence;
            valid(record, false); record.checksum = checksum(record); valid(record);
            if (fault === 'abort-before-write') { abort(); return; }
            store.put(record, 'state');
            if (fault === 'abort-after-write') { abort(); return; }
            response = {output: Array.from(output), revision: record.revision, cursor: record.cursor, replay: false};
          } finally { if (candidate) candidate.free(); }
        } catch (_) { abort(); }
      };
    };
  });
}
function current(record,directory){
 if(record.pins!==null)matchDirectory(record.pins,directory);
 else {
  const own=directory.devices.find(x=>x.actor===identity);
  if(own&&(own.status!=='active'||own.signing_key!==toHex(staged_public_key(record.crypto,identity))))fail();
 }
}
function publicStatus(record){return {revision:record.revision,cursor:record.cursor,operations:record.ledger.map(x=>x.id),pins:record.pins,public_key:Array.from(staged_public_key(record.crypto,identity)),group_id:record.group_id};}
// Network admission is always outside IDB; each transaction reads/validates the
// complete current record again. No live candidate survives failure or restart.
let queue=Promise.resolve();
self.onmessage=({data})=>{
 queue=queue.then(async()=>{
  let id;
  try{
   if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1||typeof data.method!=='string')fail();
   id=data.id;const {method,argument}=data;if(retired)fail();let result;
   if(method==='init'){
    if(db||!exact(argument,['identity','room','database'])||typeof argument.identity!=='string'||!/^[a-zA-Z0-9_.:-]{1,64}$/.test(argument.identity)||typeof argument.room!=='string'||!/^[a-zA-Z0-9_-]{1,64}$/.test(argument.room))fail();
    identity=argument.identity;room=argument.room;
    const directory=await readDirectory(identity,room);
    db=await open(argument.database);result=await transaction('initialize',undefined,directory);
   }else{
    if(!db||!['status','pin','operation'].includes(method))fail();
    const directory=await readDirectory(identity,room);
    result=await transaction(method,argument,directory);
   }
   if(wasm.memory.buffer.byteLength>128*1024*1024)fail();
   self.postMessage({id,ok:true,result,memory_bytes:wasm.memory.buffer.byteLength});
  }catch(_){
   retired=true;if(db){db.close();db=undefined;}
   self.postMessage({id,ok:false,error:'trusted state rejected',memory_bytes:wasm.memory.buffer.byteLength});
  }
 });
};
self.postMessage({boot:true});
