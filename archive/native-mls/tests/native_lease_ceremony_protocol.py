#!/usr/bin/env python3
"""Fake Worker caller failures only; real custody proof is separate."""
import json,tempfile,threading,hashlib,copy
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from playwright.sync_api import sync_playwright,expect
archive=Path(__file__).resolve().parents[2];web=archive/'experiments/openmls-browser/web';work=Path(tempfile.mkdtemp(prefix='lease-ceremony-protocol-'));work.chmod(0o700)
allowed={x:'text/javascript' for x in ('lease-ceremony-ui.js','lease-ceremony-client.js','confirmation-ceremony-client.js','custody-ceremony-client.js','candidate-preparation-client.js','peer-preparation-client.js','successor-handoff.js')};allowed.update({'lease-ceremony.html':'text/html','lease-ceremony.css':'text/css'})
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  name=self.path.lstrip('/') or 'lease-ceremony.html'
  if name not in allowed:self.send_error(404);return
  raw=(web/name).read_bytes();self.send_response(200);self.send_header('Content-Type',allowed[name]);self.end_headers();self.wfile.write(raw)
 def log_message(self,*a):pass
pin=lambda actor,device,key:{'actor':actor,'device_id':device,'device_revision':1,'signing_key':key*64}
context={'version':1,'intent_id':'generated-intent','decision_revision':1,'expires_at':1,'source_room':'source','source_group':'ab'*16,'target_room':'target','predecessor':pin('bob','old','1'),'candidate':pin('bob','new','2'),'peer':pin('alice','peer','3'),'candidate_fingerprint':hashlib.sha256(bytes.fromhex('2'*64)).hexdigest(),'package_sha256':'5'*64,'admission':'preflight-only'}
reservation={'version':1,'reservation_id':'generated-reservation','context':context,'phase':'reserved-inactive'};scope={'identity':'alice','role':'peer','database':'family-mls-device-vault-synthetic-protocol','reservation':reservation};doc={'version':1,'scopes':[scope]};expected=hashlib.sha256(json.dumps(reservation,separators=(',',':'),sort_keys=True).encode()).hexdigest()
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();checks={}
def fill(p,action='activate'):
 p.select_option('#identity','alice');p.select_option('#role','peer');p.fill('#database',scope['database']);p.select_option('#action',action)
 if action=='send':p.fill('#message-id','message-one');p.fill('#message-text','generated hello')
 p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#request-load');expect(p.locator('#request-status')).to_contain_text('요청을 읽었습니다');p.fill('#confirmation',expected);p.fill('#password','generated-password-for-protocol-only-000');p.check('#consent')
try:
 with sync_playwright() as pw:
  browser=pw.chromium.launch();p=browser.new_page()
  for mode in ('spawn-throw','clone-throw','missing-boot','bad-boot','duplicate-boot','wrong-id','extra-private','bad-phase','over-memory','failure','lock','broadcast','hide','late-lock'):
   p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run')
   p.evaluate("""mode=>{
    window.terminated=false;const original=setTimeout;window.setTimeout=(f,n,...a)=>original(f,n===60000&&mode==='missing-boot'?250:n,...a);
    window.Worker=class {
     constructor(){if(mode==='spawn-throw')throw Error();window.worker=this;if(mode!=='missing-boot')original(()=>this.onmessage?.({data:mode==='bad-boot'?{boot:true,extra:true}:{boot:true}}),0)}
     postMessage(message){window.sentKeys=Object.keys(message.argument).sort();window.sentOp=message.argument.operation;if(mode==='clone-throw')throw Error();
      let data={id:1,ok:true,result:{committed:true,role:'peer',received:[],phase:'awaiting-pair',channel_full:null,outbox_status:'empty'},memory_bytes:1};
      if(mode==='duplicate-boot')data={boot:true};if(mode==='wrong-id')data.id=2;if(mode==='extra-private')data.result.approval='must reject';if(mode==='bad-phase')data.result.phase='active';if(mode==='over-memory')data.memory_bytes=134217729;if(mode==='failure')data={id:1,ok:false,memory_bytes:0};
      if(!['lock','broadcast','hide','late-lock'].includes(mode))original(()=>this.onmessage?.({data}),0);
     }
     terminate(){window.terminated=true;}
    }
   }""",mode)
   fill(p);p.click('#run')
   if mode in ('lock','late-lock','broadcast','hide'):p.wait_for_function('()=>window.worker!==undefined')
   if mode in ('lock','late-lock'):p.click('#lock')
   elif mode=='broadcast':p.evaluate("()=>{let c=new BroadcastChannel('family-vault-ui-lock-v1');c.postMessage('lock');setTimeout(()=>c.close(),10)}")
   elif mode=='hide':p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))}")
   if mode=='late-lock':p.evaluate("window.worker.onmessage({data:{id:1,ok:true,result:{},memory_bytes:1}})")
   expect(p.locator('#status')).to_have_attribute('data-state','unknown');assert p.locator('#export').is_disabled() and p.locator('#public-result').inner_text()=='' and p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked() and p.locator('#received-list').inner_text()==''
   if mode!='spawn-throw':assert p.evaluate('window.terminated'),mode
   checks[mode+'_retires_clears_credentials_no_public_success']=True
  p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run')
  p.evaluate("""()=>{
    window.Worker=class{constructor(){window.worker=this;queueMicrotask(()=>this.onmessage?.({data:{boot:true}}))}
     postMessage(message){window.sentOp=message.argument.operation;queueMicrotask(()=>this.onmessage?.({data:{id:1,ok:true,result:{committed:true,role:'peer',received:[{seq:1,text:'generated candidate hello'}],phase:'leased',channel_full:false,outbox_status:'empty'},memory_bytes:1}}))}
     terminate(){window.terminated=true;}}
  }""")
  fill(p,'sync');p.click('#run');expect(p.locator('#status')).to_have_attribute('data-state','synchronized')
  assert p.locator('#received-list li').count()==1 and p.locator('#received-list li').inner_text()=='generated candidate hello'
  exported=json.loads(p.locator('#public-result').inner_text());assert 'received' not in exported and exported['received_count']==1 and exported['last_seq']==1
  checks['sync_lists_received_text_omits_plaintext_from_public_json']=True
  p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run')
  p.evaluate("""()=>{window.Worker=class{constructor(){queueMicrotask(()=>this.onmessage?.({data:{boot:true}}))}
     postMessage(message){window.sentOp=message.argument.operation;queueMicrotask(()=>this.onmessage?.({data:{id:1,ok:true,result:{committed:true,role:'peer',received:[],phase:'leased',channel_full:false,outbox_status:'pending'},memory_bytes:1}}))}
     terminate(){}}
  }""")
  fill(p,'send');p.click('#run');expect(p.locator('#status')).to_have_attribute('data-state','outbox-pending')
  assert p.evaluate('window.sentOp')=={'kind':'send','id':'message-one','text':'generated hello'}
  checks['send_passes_id_and_text_operation_only']=True
  def parse(raw):return p.evaluate("async raw=>{try{let m=await import('/lease-ceremony-client.js');return (await m.request(raw,'alice','family-mls-device-vault-synthetic-protocol','peer')).sha256}catch{return null}}",raw)
  assert parse(json.dumps(doc))==parse(json.dumps(doc,sort_keys=True))==expected;checks['independent_digest_canonical_all_fields']=True
  for mode in ('extra','fingerprint','candidate-role','wrong-database','multiple'):
   d=copy.deepcopy(doc)
   if mode=='extra':d['scopes'][0]['password']='must reject'
   elif mode=='fingerprint':d['scopes'][0]['reservation']['context']['candidate_fingerprint']='0'*64
   elif mode=='candidate-role':d['scopes'][0]['role']='candidate'
   elif mode=='wrong-database':d['scopes'][0]['database']='another-database'
   else:d['scopes'].append(copy.deepcopy(scope))
   assert parse(json.dumps(d)) is None
  checks['peer_file_extensions_substitution_multiple_scope_rejected']=True
  proof={'kind':'fake Worker protocol only, no actual private custody','passed':True,'checks':checks};(work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json');browser.close()
finally:server.shutdown();server.server_close()
