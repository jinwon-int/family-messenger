// Explicit preserving v1 -> v2 transition in the SAME encrypted aggregate.
// Only signer custody. No native delivery, declaration, candidate or new root.
import {AggregateStore} from './aggregate-store.js';
import {fresh,publicKey} from './aggregate-state-v4.js';
import {reservation,pair,validatePeer,same} from './successor-peer-state.js';
export {reservation} from './successor-peer-state.js';
import {staged_identity_context} from '/pkg/family_mls_browser_experiment.js';
import {exact,fail,unhex} from '/trust-directory.js';
const {default:sodium}=await import('libsodium-wrappers');await sodium.ready;
const MAX=4*1024*1024,enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
const b64=b=>{let s='';for(let i=0;i<b.length;i+=8192)s+=String.fromCharCode(...b.subarray(i,i+8192));return btoa(s);};
function encode(a){const bytes=enc.encode(JSON.stringify({...a,rooms:a.rooms.map(r=>({...r,crypto:b64(r.crypto)}))}));if(bytes.length>MAX)fail();return bytes;}
function decode(bytes){
 if(bytes.length<1||bytes.length>MAX)fail();const a=JSON.parse(dec.decode(bytes));
 if(!a||!Array.isArray(a.rooms)||a.rooms.length<1||a.rooms.length>2)fail();
 for(const r of a.rooms){if(!r||typeof r.crypto!=='string'||r.crypto.length>1398104)fail();const b=Uint8Array.from(atob(r.crypto),c=>c.charCodeAt(0));if(!b.length||b.length>1048576||b64(b)!==r.crypto)fail();r.crypto=b;}return a;
}
export class SuccessorPeerStore extends AggregateStore {
 async admission(expected){
  this.live();const c=expected.context;if(c.expires_at*1000<=Date.now())fail();
  const controller=new AbortController();this.controllers.add(controller);const timer=setTimeout(()=>controller.abort(),5000);
  try{
   const response=await fetch('/v1/mls/successors/'+c.intent_id+'/reservation',{credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'X-Family-Actor':this.identity,'X-Family-Device':c.peer.device_id},signal:controller.signal});
   if(!response.ok||response.headers.get('X-Family-Actor')!==this.identity)fail();
   const reader=response.body.getReader();let n=0,parts=[];
   for(;;){const {done,value}=await reader.read();if(done)break;n+=value.length;if(n>4096)fail();parts.push(value);}
   const raw=new Uint8Array(n);let at=0;for(const p of parts){raw.set(p,at);at+=p.length;}
   if(!same(reservation(JSON.parse(dec.decode(raw)),this.identity),expected)||c.expires_at*1000<=Date.now())fail();this.live();
  }finally{controller.abort();clearTimeout(timer);this.controllers.delete(controller);}
 }
 async prepare(arg){
  this.live();if(this.create||++this.operations>256||!exact(arg,['accepted','reservation'])||arg.accepted!==true)fail();
  const expected=reservation(arg.reservation,this.identity);if(this.selectedRoom!==expected.context.source_room)fail();
  // Fresh restricted admission before any password KDF; this is not old-room
  // admission and must never be passed to the ordinary native worker.
  await this.admission(expected);
  return this.lock('family-native-vault-state:'+this.database,async live=>{
   const before=await this.read();this.outer(before);let a,original,candidate;
   try{
    await this.key(before,null,{publicKey});live();
    const state=sodium.crypto_secretstream_xchacha20poly1305_init_pull(before.header,this.root.key);
    const out=sodium.crypto_secretstream_xchacha20poly1305_pull(state,before.cipher,this.aad(before.revision));if(!out)fail();
    try{if(out.tag!==sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL)fail();a=decode(out.message);}finally{sodium.memzero(out.message);}
    if(validatePeer(a,this.identity,expected)!==this.root.pub)fail();original=encode(a);
    await this.admission(expected);live();
    if(a.version===1){
     const source=a.rooms[0],c=expected.context;
     // Authenticate the OLD group with its actual predecessor member. The
     // vetted API copies only the intact signer into an empty provider.
     const crypto=staged_identity_context(source.crypto,this.identity,unhex(c.peer.signing_key),unhex(c.source_group),c.predecessor.actor,unhex(c.predecessor.signing_key));
     a={version:2,identity:this.identity,primary_room:a.primary_room,rooms:[source,fresh(this.identity,c.target_room,crypto,pair(c,true))],successor:expected};
    }
    if(validatePeer(a,this.identity,expected)!==this.root.pub)fail();candidate=encode(a);this.maxSerialized=candidate.length;
    let after=null;
    if(candidate.length!==original.length||!candidate.every((v,i)=>v===original[i])){
     const revision=before.revision+1;if(revision>512)fail();
     const {state,header}=sodium.crypto_secretstream_xchacha20poly1305_init_push(this.root.key);
     const cipher=sodium.crypto_secretstream_xchacha20poly1305_push(state,candidate,this.aad(revision),sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
     after={...before,revision,header,cipher};
    }
    await this.admission(expected);live();await this.commit(before,after,'',live);live();
    this.root.seen=(after??before).revision;
    return {committed:true,phase:'inactive-peer-custody',reservation_id:expected.reservation_id,intent_id:expected.context.intent_id,room:expected.context.target_room,public_key:Array.from(unhex(this.root.pub))};
   }finally{if(original)sodium.memzero(original);if(candidate)sodium.memzero(candidate);if(a?.rooms)for(const r of a.rooms)if(r.crypto instanceof Uint8Array)sodium.memzero(r.crypto);}
  });
 }
}
