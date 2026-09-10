"""Caller lifecycle failures must terminate workers and settle requests."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]

class HistoryCallerTests(unittest.TestCase):
    module = 'history-client.js'
    reader = 'HistoryReader'
    def test_retirement_with_immutable_input_and_terminal_close(self):
        script=r'''
import assert from 'node:assert/strict';
const events={},timers=new Set(),workers=[];
globalThis.document={hidden:false};globalThis.addEventListener=(name,fn)=>events[name]=fn;
globalThis.setTimeout=()=>{const id={};timers.add(id);return id};globalThis.clearTimeout=id=>timers.delete(id);
globalThis.Worker=class {constructor(){workers.push(this);this.terminated=false;this.sent=[]}terminate(){this.terminated=true}postMessage(data){this.sent.push(data)}};
const {HistoryReader}=await import(MODULE);
const argument=()=>Object.freeze({archive:new Uint8Array([1]),password:'synthetic-password-only-32-characters',expected:{}});
let c=new HistoryReader(),p=c.read(argument()),w=workers.at(-1);
w.onmessage({data:{ready:true}});assert.equal(w.sent.length,1);
c.lock();assert.equal((await p).ok,false);assert.equal(w.terminated,true);assert.equal(c.active,null);assert.equal(timers.size,0);
w.onmessage({data:{id:1,ok:true,result:{late:true}}});assert.equal(c.active,null);c.close();
// Lock before ready must not depend on mutating a caller-owned property.
c=new HistoryReader();p=c.read(argument());w=workers.at(-1);c.lock();assert.equal((await p).ok,false);assert(w.terminated);c.close();
const count=workers.length;assert.equal((await c.read(argument())).ok,false);assert.equal(workers.length,count);events.pagehide();assert.equal(c.active,null);
// UI cleanup callback errors do not interrupt retirement or settlement.
c=new HistoryReader(()=>{throw Error('synthetic consumer error')});p=c.read(argument());w=workers.at(-1);c.close();assert.equal((await p).ok,false);assert(w.terminated);assert.equal(timers.size,0);
// A tiny view must not clone an oversized backing allocation.
c=new HistoryReader();const before=workers.length;assert.equal((await c.read({...argument(),archive:new Uint8Array(new ArrayBuffer(6*1024*1024+1),0,1)})).ok,false);assert.equal(workers.length,before);c.close();
// A clone failure after ready terminates immediately and cannot affect a later caller.
c=new HistoryReader();p=c.read(argument());w=workers.at(-1);w.postMessage=()=>{throw Error('clone failed')};w.onmessage({data:{ready:true}});assert.equal((await p).ok,false);assert(w.terminated);assert.equal(timers.size,0);c.close();
console.log('immutable before/after ready, terminal close, callback failure, backing cap, clone failure: pass');
'''
        script=script.replace('HistoryReader',self.reader).replace('MODULE',json.dumps((ROOT/'experiments/device-keystore'/self.module).as_uri()))
        result=subprocess.run(['node','--input-type=module','-e',script],text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('pass',result.stdout)

    def test_metadata_and_password_caps_before_worker_creation(self):
        script = '''
import assert from 'node:assert/strict';
globalThis.addEventListener=()=>{};
globalThis.document={hidden:false};
let workers=0;globalThis.Worker=class{constructor(){workers++}};
const {AggregateHistoryReader}=await import(MODULE);
const c=new AggregateHistoryReader();
const good={archive:new Uint8Array([1]),expected:{},password:'s'.repeat(32)};
for(const value of [{...good,password:'s'.repeat(129)}, {...good,password:'short'},
 {...good,expected:{huge:'한'.repeat(1400)}}])assert.equal((await c.read(value)).ok,false);
assert.equal(workers,0);c.close();
'''.replace('AggregateHistoryReader',self.reader).replace('MODULE',json.dumps((ROOT/'experiments/device-keystore'/self.module).as_uri()))
        result=subprocess.run(['node','--input-type=module','-e',script],text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_callback_close_and_mutable_argument_cannot_bypass_admission(self):
        script = r'''
import assert from 'node:assert/strict';
const workers=[];globalThis.document={hidden:false};globalThis.addEventListener=()=>{};
globalThis.Worker=class{constructor(){workers.push(this);this.sent=[]}terminate(){this.dead=true}postMessage(x){this.sent.push(x)}};
const {AggregateHistoryReader}=await import(MODULE);
const argument=()=>({archive:new Uint8Array([1]),expected:{identity:'alice'},password:'s'.repeat(32)});
let once=false,c=new AggregateHistoryReader(()=>{if(!once){once=true;c.close()}});
assert.equal((await c.read(argument())).ok,false);assert.equal(workers.length,0);
c=new AggregateHistoryReader();const arg=argument(),pending=c.read(arg),w=workers.at(-1);
arg.archive=new Uint8Array(6*1024*1024+1);arg.expected.identity='bob';arg.password='different-password';
w.onmessage({data:{ready:true}});assert.equal(w.sent.length,1);
assert.deepEqual(Array.from(w.sent[0].argument.archive),[1]);assert.equal(w.sent[0].argument.expected.identity,'alice');assert.equal(w.sent[0].argument.password,'s'.repeat(32));
c.close();assert.equal((await pending).ok,false);assert(w.dead);
// Reentrant cleanup can start a new operation; the superseded outer read must
// not overwrite or orphan that operation's handle.
let inner=null,reenter=false;c=new AggregateHistoryReader(()=>{if(!reenter){reenter=true;inner=c.read(argument())}});
assert.equal((await c.read(argument())).ok,false);assert(c.active);const live=workers.at(-1);c.close();assert.equal((await inner).ok,false);assert(live.dead);
'''.replace('AggregateHistoryReader',self.reader).replace('MODULE',json.dumps((ROOT/'experiments/device-keystore'/self.module).as_uri()))
        result=subprocess.run(['node','--input-type=module','-e',script],text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)


class AggregateHistoryCallerTests(HistoryCallerTests):
    module = 'aggregate-history-client.js'
    reader = 'AggregateHistoryReader'
