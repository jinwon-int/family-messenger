import {exact,fail} from './trust-directory.js';
import {immutable} from './custody-declaration.js';
import {enrollmentHTTP} from './enrollment-wire.js';
export function enrollmentWorker(wasm,store,normalize,role){
 let started=false,dead=false;const close=()=>{dead=true;store.close();};
 self.onmessage=async({data})=>{let id=null;try{
 if(!exact(data,['id','method','argument'])||!Number.isSafeInteger(data.id)||data.id<1)fail();id=data.id;
 if(data.method==='lock'){if(data.argument!==null)fail();close();self.postMessage({id,ok:true,result:{locked:true}});self.close();return;}
 if(dead||started||data.method!=='enrollment')fail();started=true;const a=data.argument;
 if(!exact(a,['identity','database','password','intent','operation'])||!['alice','bob'].includes(a.identity)||!exact(a.intent,['accepted','reservation'])||a.intent.accepted!==true)fail();
 const op=a.operation;if(!op||!['enroll','observe','sync','send'].includes(op.kind)||!exact(op,op.kind==='send'?['kind','id','text']:['kind']))fail();
 if(op.kind==='send'&&(typeof op.id!=='string'||!/^[a-zA-Z0-9_-]{1,64}$/.test(op.id)||typeof op.text!=='string'||!op.text.length||new TextEncoder().encode(op.text).length>256))fail();
 const operation=immutable(structuredClone(op)),e=immutable(normalize(a.intent.reservation,a.identity));const selected=store.argument({identity:a.identity,database:a.database,password:a.password,room:role==='candidate'?'candidate-proposal-v1':e.context.source_room,create:false});a.password=null;store.identity=selected.identity;
 await store.open(selected.database,selected.identity,selected.room);let local=await store.enroll(e,operation);if(!local.committed||dead)fail();
 if(operation.kind==='enroll'&&!local.own_declared){await enrollmentHTTP(store,e,role,'enrollment',local.approval);local=await store.enroll(e,{kind:'observe'});}
 else if(['send','sync'].includes(operation.kind)&&local.pending&&!local.channel_full){await enrollmentHTTP(store,e,role,'enrolled-channel',local.pending);local=await store.enroll(e,{kind:'sync'});}
 const memory=wasm.memory.buffer.byteLength+store.memoryBytes();if(dead||memory>128*1024*1024)fail();const {approval,pending,...result}=local;self.postMessage({id,ok:true,result,memory_bytes:memory});close();self.close();
 }catch(_){close();self.postMessage({id,ok:false,memory_bytes:0});self.close();}};self.postMessage({boot:true});
}
