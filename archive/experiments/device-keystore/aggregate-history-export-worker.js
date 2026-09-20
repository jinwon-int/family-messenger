// Isolated coherent read-only export; never opens a live write transaction.
import {exact,expectation,encodeArchive,history} from './aggregate-history-core.js';
import {serveHistory} from './aggregate-history-worker-contract.js';
async function snapshot(database,live){
 live();if(!(await indexedDB.databases()).some(d=>d.name===database&&d.version===1))throw Error('missing database');
 const db=await new Promise((resolve,reject)=>{
  const q=indexedDB.open(database,1);q.onupgradeneeded=()=>q.transaction.abort();q.onerror=()=>reject(Error('missing'));q.onblocked=()=>reject(Error('blocked'));q.onsuccess=()=>{try{live();resolve(q.result)}catch(e){q.result.close();reject(e)}};
 });
 try{
  if(db.objectStoreNames.length!==1||!db.objectStoreNames.contains('device'))throw Error('schema');
  return await new Promise((resolve,reject)=>{
   const t=db.transaction('device','readonly'),s=t.objectStore('device');let value;
   t.onabort=()=>reject(Error('snapshot'));t.oncomplete=()=>{try{live();resolve(value)}catch(e){reject(e)}};
   const keys=s.getAllKeys(undefined,2);keys.onsuccess=()=>{if(keys.result.length!==1||keys.result[0]!=='state'){t.abort();return;}const q=s.get('state');q.onsuccess=()=>{value=q.result;};};
  });
 }finally{db.close();}
}
serveHistory(async(arg,live)=>{
 if(!exact(arg,'expected,password'))throw Error('argument');
 const e=expectation(arg.expected),password=arg.password;arg.password=null;
 const r=await snapshot(e.database,live);live();await history(r,e,password,live);live();
 return {archive:encodeArchive(r,e)};
});
