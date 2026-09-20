// Run the actual transport with deterministic clock/network faults, no private fixtures.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const data=s=>'data:text/javascript;base64,'+Buffer.from(s).toString('base64');
const wasm=data(`import {createHash} from 'node:crypto';export const staged_checksum=b=>new Uint8Array(createHash('sha256').update(b).digest());`);
const trust=data((await readFile(new URL('../experiments/openmls-browser/web/trust-directory.js',import.meta.url),'utf8')).replace("'./pkg/family_mls_browser_experiment.js'",JSON.stringify(wasm)));
const source=await readFile(new URL('../experiments/openmls-browser/web/custody-declaration.js',import.meta.url),'utf8');
const {immutable,declaration,declareCustody}=await import(data(source.replace("'./trust-directory.js'",JSON.stringify(trust)).replace("'./pkg/family_mls_browser_experiment.js'",JSON.stringify(wasm))));
const digest=s=>createHash('sha256').update(s).digest('hex');
const expected=immutable({reservation_id:'r',context:{intent_id:'i',expires_at:4000000000,candidate:{device_id:'c'},peer:{device_id:'p'}}});
const own=declaration(expected,'peer');
assert.equal(own.context_sha256,digest(JSON.stringify(expected.context)));
assert.equal(own.declaration_id,digest(JSON.stringify(['family-successor-custody-declaration',1,'peer','r',own.context_sha256,'p'])));
assert.throws(()=>{expected.context.peer.device_id='x'});
const entry=role=>({...declaration(expected,role),device_id:expected.context[role].device_id});
const value={version:1,reservation_id:'r',context_sha256:own.context_sha256,revision:2,phase:'pair-declared-inactive',declarations:['candidate','peer'].map(entry)};
let count=0;
function store(){return {identity:'alice',dead:false,controllers:new Set(),live(){if(this.dead)throw Error('closed')}};}
function response(v=value,status=200,actor='alice'){return new Response(JSON.stringify(v),{status,headers:{'X-Family-Actor':actor}});}
const originalFetch=globalThis.fetch,originalNow=Date.now;
try{
 let requests=[];
 globalThis.fetch=async(path,options)=>{requests.push({path,options});return response();};
 const s=store(),r=await declareCustody(s,expected,'peer');assert.equal(r.own_declared,true);assert.equal(s.controllers.size,0);
 assert.deepEqual(requests.map(x=>x.options.method),['POST','GET']);
 assert.equal(requests[0].options.body,JSON.stringify(own));
 for(const {path,options} of requests){assert.equal(path,'/v1/mls/successors/i/custody');assert.equal(options.redirect,'error');assert.equal(options.credentials,'same-origin');assert.equal(options.cache,'no-store');assert.equal(options.headers['X-Family-Device'],'p');assert(options.signal.aborted);}
 count++;
 for(const fault of ['expiry-after-fetch','expiry-after-body','close-after-fetch','close-after-body','abort-after-fetch','abort-after-body','get-stale-slot','get-changed-id']){
  const s=store();let calls=0;Date.now=originalNow;
  globalThis.fetch=async(path,options)=>{
   calls++;let v=structuredClone(value);
   const retire=()=>{if(fault.startsWith('expiry'))Date.now=()=>4000000000001;else if(fault.startsWith('close'))s.dead=true;else options.signal.dispatchEvent(new Event('abort'));};
   // A real AbortController, including the store's tracked controller, owns state.
   const abort=()=>{for(const c of s.controllers)c.abort();};
   if(fault.endsWith('after-fetch')){fault.startsWith('abort')?abort():retire();return response();}
   if(fault.endsWith('after-body'))return {status:200,redirected:false,headers:new Headers({'X-Family-Actor':'alice'}),body:new ReadableStream({start(controller){controller.enqueue(new TextEncoder().encode(JSON.stringify(v)));fault.startsWith('abort')?abort():retire();controller.close();}})};
   if(calls===2){if(fault==='get-stale-slot'){v.declarations=v.declarations.slice(1);v.revision=1;v.phase='custody-pending';}else v.declarations[0].declaration_id='substitution';}
   return response(v);
  };
  await assert.rejects(declareCustody(s,expected,'peer'),fault);assert.equal(s.controllers.size,0);count++;
 }
 Date.now=originalNow;
 // A lost POST never triggers a second request in this invocation. New worker
 // reuses the same receipt ID; the real paired browser suite verifies persistence.
 let firstBody;
 globalThis.fetch=async(path,options)=>{firstBody=options.body;throw Error('reply lost')};
 await assert.rejects(declareCustody(store(),expected,'peer'));
 globalThis.fetch=async(path,options)=>{if(options.method==='POST')assert.equal(options.body,firstBody);return response()};
 await declareCustody(store(),expected,'peer');count++;
 console.log(JSON.stringify({passed:true,checks:count}));
}finally{globalThis.fetch=originalFetch;Date.now=originalNow;}
