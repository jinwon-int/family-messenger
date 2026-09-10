// Test-only generated archive forger: returns encrypted negative fixtures only.
// No production assets import this worker; never writes an active profile.
import {Decrypter} from 'age-encryption';
import sodium from 'libsodium-wrappers';
import init,{staged_checksum} from '/pkg/family_mls_browser_experiment.js';
await init();await sodium.ready;
const enc=new TextEncoder(),dec=new TextDecoder(),b64=x=>{let s='';for(let i=0;i<x.length;i+=8192)s+=String.fromCharCode(...x.subarray(i,i+8192));return btoa(s)},un=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
self.onmessage=async({data})=>{
 try{
  if(data.archive.length>6*1024*1024)throw Error('fixture bound');
  const archive=JSON.parse(dec.decode(new Uint8Array(data.archive))),s=archive.state,d=new Decrypter();d.addPassphrase(data.password);data.password=null;
  const capsule=await d.decrypt(un(s.capsule)),p=JSON.parse(dec.decode(capsule)),key=new Uint8Array(p[6]);
  const aad=enc.encode(JSON.stringify(['family-native-vault',1,archive.database,s.identity,s.room,s.vault,s.revision]));
  const opened=sodium.crypto_secretstream_xchacha20poly1305_pull(sodium.crypto_secretstream_xchacha20poly1305_init_pull(un(s.header),key),un(s.cipher),aad);
  const original=JSON.parse(dec.decode(opened.message)),out={};
  for(const kind of ['wrong-sender','pending-as-history','damaged-provider','non-final','wrong-epoch','wrong-fork','duplicate-room','missing-room','duplicate-provider','reordered-intent']){
   const aggregate=structuredClone(original),r=aggregate.rooms[1];
   if(kind==='wrong-sender')r.messages[0].sender_actor=r.messages[0].sender_actor==='alice'?'bob':'alice';
   if(kind==='pending-as-history'){if(!r.pending?.frame)throw Error('pending required');r.messages.push(r.pending.frame);}
   if(kind==='damaged-provider'){const c=un(r.crypto);c[0]^=1;r.crypto=b64(c);}
   if(kind==='wrong-epoch')r.epoch++;
   if(kind==='wrong-fork')aggregate.fork.id='context-forged';
   if(kind==='duplicate-room')r.room=aggregate.rooms[0].room;
   if(kind==='missing-room')aggregate.rooms.pop();
   if(kind==='duplicate-provider')r.crypto=aggregate.rooms[0].crypto;
   if(kind==='reordered-intent')aggregate.fork=Object.fromEntries(Object.entries(aggregate.fork).reverse());
   r.checksum=sodium.to_hex(staged_checksum(enc.encode(JSON.stringify([4,r.identity,r.room,r.pins,r.group,r.binding,r.cursor,r.revision,r.epoch,r.phase,r.pending,r.receipts,r.messages,sodium.to_hex(un(r.crypto))]))));
   const fresh=sodium.crypto_secretstream_xchacha20poly1305_init_push(key),cipher=sodium.crypto_secretstream_xchacha20poly1305_push(fresh.state,enc.encode(JSON.stringify(aggregate)),aad,kind==='non-final'?sodium.crypto_secretstream_xchacha20poly1305_TAG_MESSAGE:sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
   out[kind]=Array.from(enc.encode(JSON.stringify({...archive,state:{...s,header:b64(fresh.header),cipher:b64(cipher)}})));
  }
  sodium.memzero(key);sodium.memzero(capsule);sodium.memzero(opened.message);self.postMessage({ok:true,fixtures:out});
 }catch{self.postMessage({ok:false});}finally{self.close();}
};
self.postMessage({ready:true});
