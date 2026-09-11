#!/usr/bin/env python3
"""Disposable fake Worker protocol cases, separate from real custody evidence."""
import json,tempfile,threading,hashlib,copy
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from playwright.sync_api import sync_playwright,expect
root=Path(__file__).resolve().parents[1];web=root/'experiments/openmls-browser/web';work=Path(tempfile.mkdtemp(prefix='candidate-protocol-',dir=root/'artifacts'));work.chmod(0o700)
allowed={x:'text/javascript' for x in ('candidate-preparation-ui.js','candidate-preparation-client.js','candidate-attempts.js','successor-handoff.js')};allowed.update({'candidate-preparation.html':'text/html','candidate-preparation.css':'text/css'})
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  name=self.path.lstrip('/') or 'candidate-preparation.html'
  if name not in allowed:self.send_error(404);return
  raw=(web/name).read_bytes();self.send_response(200);self.send_header('Content-Type',allowed[name]);self.end_headers();self.wfile.write(raw)
 def log_message(self,*a):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();checks={}
try:
 with sync_playwright() as pw:
  browser=pw.chromium.launch();p=browser.new_page()
  for mode in ('spawn-throw','clone-throw','missing-boot','bad-boot','duplicate-boot','wrong-id','extra-private','bad-package','over-memory','failure','lock','broadcast','hide','late-lock'):
   p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run')
   p.evaluate("""mode=>{
    window.mode=mode;window.terminated=false;const original=setTimeout;window.setTimeout=(f,n,...a)=>original(f,n===60000&&mode==='missing-boot'?250:n,...a);
    window.Worker=class {
     constructor(){if(mode==='spawn-throw')throw Error();window.worker=this;if(mode!=='missing-boot')original(()=>this.onmessage?.({data:mode==='bad-boot'?{boot:true,extra:true}:{boot:true}}),0)}
     postMessage(message){window.sentKeys=Object.keys(message.argument).sort();if(mode==='clone-throw')throw Error();
      let data={id:1,ok:true,result:{committed:true,phase:'unassigned-proposal',public_key:'a'.repeat(64),package:'01',package_sha256:'0'.repeat(64),reservation_id:null},memory_bytes:1};
      if(mode==='duplicate-boot')data={boot:true};if(mode==='wrong-id')data.id=2;if(mode==='extra-private')data.result.private='must reject';if(mode==='over-memory')data.memory_bytes=134217729;if(mode==='failure')data={id:1,ok:false,memory_bytes:0};
      if(!['lock','broadcast','hide','late-lock'].includes(mode))original(()=>this.onmessage?.({data}),0);
     }
     terminate(){window.terminated=true;}
    }
   }""",mode)
   p.select_option('#identity','alice');p.fill('#database','family-mls-candidate-synthetic-protocol');p.select_option('#action','reopen');p.fill('#password','generated-password-for-protocol-only-000');p.check('#consent');p.click('#run')
   if mode in ('lock','late-lock','broadcast','hide'):p.wait_for_function('()=>window.worker!==undefined')
   if mode in ('lock','late-lock'):p.click('#lock')
   elif mode=='broadcast':p.evaluate("()=>{let c=new BroadcastChannel('family-vault-ui-lock-v1');c.postMessage('lock');setTimeout(()=>c.close(),10)}")
   elif mode=='hide':p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))}")
   if mode=='late-lock':p.evaluate("window.worker.onmessage({data:{id:1,ok:true,result:{},memory_bytes:1}})")
   expect(p.locator('#status')).to_have_attribute('data-state','unknown');assert p.locator('#export').is_disabled() and p.locator('#public-result').inner_text()=='' and p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
   if mode!='spawn-throw':assert p.evaluate('window.terminated'),mode
   checks[mode+'_retires_clears_credentials_no_public_success']=True
  # A permanent public attempt marker prevents create after restart. It cannot
  # substitute for existing encrypted custody on a reopen.
  p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run');p.select_option('#identity','alice');p.fill('#database','family-mls-candidate-synthetic-protocol');p.select_option('#action','create');p.fill('#password','generated-password-for-protocol-only-000');p.check('#consent');p.evaluate("()=>{window.Worker=class{constructor(){throw Error('should not be constructed')}}}");p.click('#run');expect(p.locator('#status')).to_have_attribute('data-state','unknown');expect(p.locator('#attempt')).to_be_visible();assert p.locator('#export').is_disabled();checks['restart_attempt_cannot_create_again']=True
  p.reload();p.wait_for_selector('#run');p.evaluate("()=>{window.Worker=class{constructor(){window.unexpectedWorker=true}};indexedDB.open=()=>{throw Error('unavailable')}}");p.select_option('#identity','alice');p.fill('#database','family-mls-candidate-synthetic-storage-denied');p.select_option('#action','create');p.fill('#password','generated-password-for-protocol-only-000');p.check('#consent');p.click('#run');expect(p.locator('#status')).to_have_attribute('data-state','unknown');assert not p.evaluate('window.unexpectedWorker===true') and p.locator('#password').input_value()=='';checks['attempt_storage_failure_zero_worker_launch']=True
  p.reload();p.wait_for_selector('#run')
  pin=lambda actor,device,key:{'actor':actor,'device_id':device,'device_revision':1,'signing_key':key*64}
  context={'version':1,'intent_id':'generated-intent','decision_revision':1,'expires_at':1,'source_room':'source','source_group':'ab'*16,'target_room':'target','predecessor':pin('alice','old','1'),'candidate':pin('alice','new','2'),'peer':pin('bob','peer','3'),'candidate_fingerprint':hashlib.sha256(bytes.fromhex('2'*64)).hexdigest(),'package_sha256':'5'*64,'admission':'preflight-only'}
  reservation={'version':1,'reservation_id':'generated-reservation','context':context,'phase':'reserved-inactive'};scope={'identity':'alice','role':'candidate','database':'family-mls-candidate-synthetic-protocol','reservation':reservation};doc={'version':1,'scopes':[scope]}
  def parse(raw):return p.evaluate("async raw=>{try{let m=await import('/candidate-preparation-client.js');return (await m.request(raw,'alice','family-mls-candidate-synthetic-protocol')).sha256}catch{return null}}",raw)
  expected=hashlib.sha256(json.dumps(reservation,separators=(',',':'),sort_keys=True).encode()).hexdigest();assert parse(json.dumps(doc))==parse(json.dumps(doc,sort_keys=True))==expected;checks['independent_digest_canonical_key_order_all_fields']=True
  for mode in ('extra','fingerprint','peer-role','wrong-database','multiple'):
   d=copy.deepcopy(doc)
   if mode=='extra':d['scopes'][0]['password']='must reject'
   elif mode=='fingerprint':d['scopes'][0]['reservation']['context']['candidate_fingerprint']='0'*64
   elif mode=='peer-role':d['scopes'][0]['role']='peer'
   elif mode=='wrong-database':d['scopes'][0]['database']='another-database'
   else:d['scopes'].append(copy.deepcopy(scope))
   assert parse(json.dumps(d)) is None
  checks['candidate_file_extensions_substitution_multiple_scope_rejected']=True
  proof={'kind':'fake Worker protocol only, no actual private custody','passed':True,'checks':checks};(work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json');browser.close()
finally:server.shutdown();server.server_close()
