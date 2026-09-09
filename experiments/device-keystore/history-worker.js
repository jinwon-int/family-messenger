// One-shot offline history reader. No IDB, native transport, enrollment or send API.
import {exact,expectation,decodeArchive,history,memory} from './history-core.js';
import {serveHistory} from './history-worker-contract.js';
serveHistory(async(arg,live)=>{
 if(!exact(arg,'expected,password,archive'))throw Error('argument');
 const e=expectation(arg.expected),r=decodeArchive(arg.archive,e),password=arg.password;arg.password=null;
 return history(r,e,password,live);
});
