"""Caller lifecycle failures must terminate workers and settle requests."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[1]

class HistoryCallerTests(unittest.TestCase):
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
        script=script.replace('MODULE',json.dumps((ROOT/'experiments/device-keystore/history-client.js').as_uri()))
        result=subprocess.run(['node','--input-type=module','-e',script],text=True,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('pass',result.stdout)
