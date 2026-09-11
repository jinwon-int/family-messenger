#!/usr/bin/env python3
"""Fake Worker caller failures only; real custody proof is separate."""
import json,tempfile,threading,hashlib,copy
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from playwright.sync_api import sync_playwright,expect
root=Path(__file__).resolve().parents[1];web=root/'experiments/openmls-browser/web';work=Path(tempfile.mkdtemp(prefix='custody-protocol-',dir=root/'artifacts'));work.chmod(0o700)
allowed={x:'text/javascript' for x in ('custody-ceremony-ui.js','custody-ceremony-client.js','candidate-preparation-client.js','peer-preparation-client.js','successor-handoff.js')};allowed.update({'custody-ceremony.html':'text/html','custody-ceremony.css':'text/css'})
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  name=self.path.lstrip('/') or 'custody-ceremony.html'
  if name not in allowed:self.send_error(404);return
  raw=(web/name).read_bytes();self.send_response(200);self.send_header('Content-Type',allowed[name]);self.end_headers();self.wfile.write(raw)
 def log_message(self,*a):pass
pin=lambda actor,device,key:{'actor':actor,'device_id':device,'device_revision':1,'signing_key':key*64}
context={'version':1,'intent_id':'generated-intent','decision_revision':1,'expires_at':1,'source_room':'source','source_group':'ab'*16,'target_room':'target','predecessor':pin('bob','old','1'),'candidate':pin('bob','new','2'),'peer':pin('alice','peer','3'),'candidate_fingerprint':hashlib.sha256(bytes.fromhex('2'*64)).hexdigest(),'package_sha256':'5'*64,'admission':'preflight-only'}
reservation={'version':1,'reservation_id':'generated-reservation','context':context,'phase':'reserved-inactive'};scope={'identity':'alice','role':'peer','database':'family-mls-device-vault-synthetic-protocol','reservation':reservation};doc={'version':1,'scopes':[scope]};expected=hashlib.sha256(json.dumps(reservation,separators=(',',':'),sort_keys=True).encode()).hexdigest()
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();checks={}
try:
 with sync_playwright() as pw:
  browser=pw.chromium.launch();p=browser.new_page()
  for mode in ('spawn-throw','clone-throw','missing-boot','bad-boot','duplicate-boot','wrong-id','extra-private','bad-key','bad-room','over-memory','failure','lock','broadcast','hide','late-lock'):
   p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run')
   p.evaluate("""mode=>{
    window.terminated=false;const original=setTimeout;window.setTimeout=(f,n,...a)=>original(f,n===60000&&mode==='missing-boot'?250:n,...a);
    window.Worker=class {
     constructor(){if(mode==='spawn-throw')throw Error();window.worker=this;if(mode!=='missing-boot')original(()=>this.onmessage?.({data:mode==='bad-boot'?{boot:true,extra:true}:{boot:true}}),0)}
     postMessage(message){window.sentKeys=Object.keys(message.argument).sort();if(mode==='clone-throw')throw Error();
      let data={id:1,ok:true,result:{committed:true,phase:'inactive-peer-custody',public_key:Array(32).fill(51),reservation_id:'generated-reservation',intent_id:'generated-intent',room:'target'},memory_bytes:1};
      if(mode==='duplicate-boot')data={boot:true};if(mode==='wrong-id')data.id=2;if(mode==='extra-private')data.result.private='must reject';if(mode==='bad-key')data.result.public_key[0]=300;if(mode==='bad-room')data.result.room='wrong';if(mode==='over-memory')data.memory_bytes=134217729;if(mode==='failure')data={id:1,ok:false,memory_bytes:0};
      if(!['lock','broadcast','hide','late-lock'].includes(mode))original(()=>this.onmessage?.({data}),0);
     }
     terminate(){window.terminated=true;}
    }
   }""",mode)
   p.select_option('#identity','alice');p.select_option('#role','peer');p.fill('#database',scope['database']);p.select_option('#action','prepare');p.locator('#request-file').set_input_files({'name':'request.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#request-load');expect(p.locator('#request-status')).to_contain_text('요청을 읽었습니다');p.fill('#confirmation',expected);p.fill('#password','generated-password-for-protocol-only-000');p.check('#consent');p.click('#run')
   if mode in ('lock','late-lock','broadcast','hide'):p.wait_for_function('()=>window.worker!==undefined')
   if mode in ('lock','late-lock'):p.click('#lock')
   elif mode=='broadcast':p.evaluate("()=>{let c=new BroadcastChannel('family-vault-ui-lock-v1');c.postMessage('lock');setTimeout(()=>c.close(),10)}")
   elif mode=='hide':p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))}")
   if mode=='late-lock':p.evaluate("window.worker.onmessage({data:{id:1,ok:true,result:{},memory_bytes:1}})")
   expect(p.locator('#status')).to_have_attribute('data-state','unknown');assert p.locator('#export').is_disabled() and p.locator('#public-result').inner_text()=='' and p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked()
   if mode!='spawn-throw':assert p.evaluate('window.terminated'),mode
   checks[mode+'_retires_clears_credentials_no_public_success']=True
  p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#run')
  def parse(raw):return p.evaluate("async raw=>{try{let m=await import('/custody-ceremony-client.js');return (await m.request(raw,'alice','family-mls-device-vault-synthetic-protocol','peer')).sha256}catch{return null}}",raw)
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
  assert p.evaluate("async d=>{const m=await import('/custody-ceremony-client.js'),r=await m.request(JSON.stringify(d),'alice',d.scopes[0].database,'peer');return Object.isFrozen(r.reservation)&&Object.isFrozen(r.reservation.context.peer)}",doc);checks['owned_immutable_reservation_before_private_worker']=True
  # Independently reproduce the original worker's normalized public wire order.
  c=copy.deepcopy(context)
  for k in ('predecessor','candidate','peer'):
   v=c[k];c[k]={n:v[n] for n in ('device_id','actor','signing_key','device_revision')}
  ch=hashlib.sha256(json.dumps(c,separators=(',',':')).encode()).hexdigest();did=hashlib.sha256(json.dumps(['family-successor-custody-declaration',1,'peer',reservation['reservation_id'],ch,c['peer']['device_id']],separators=(',',':')).encode()).hexdigest()
  slot={'role':'peer','declaration_id':did,'device_id':'peer','reservation_id':reservation['reservation_id'],'context_sha256':ch}
  value={'committed':True,'own_declared':True,'role':'peer','declaration_id':did,'readiness':{'version':1,'reservation_id':reservation['reservation_id'],'context_sha256':ch,'revision':1,'phase':'custody-pending','declarations':[slot]}}
  def validate(v):return p.evaluate("async ([v,e])=>{try{const m=await import('/custody-ceremony-client.js');return (await m.result(v,'alice','family-mls-device-vault-synthetic-protocol','peer','declare',e)).state}catch{return null}}",[v,reservation])
  assert validate(value)=='own-declared'
  for mode in ('own-id','phase','private','foreign','missing','count','duplicate'):
   v=copy.deepcopy(value)
   if mode=='own-id':v['declaration_id']='0'*64
   elif mode=='phase':v['readiness']['phase']='active'
   elif mode=='private':v['provider']='reject'
   elif mode=='foreign':v['readiness']['context_sha256']='0'*64
   elif mode=='missing':v['readiness']['declarations']=[]
   elif mode=='count':v['readiness']['revision']=2
   else:v['readiness'].update(revision=2,phase='pair-declared-inactive',declarations=[slot,slot])
   assert validate(v) is None,mode
  checks['declaration_result_normalized_digest_exact_own_slot_and_nonactivation']=True
  proof={'kind':'fake Worker protocol only, no actual private custody','passed':True,'checks':checks};(work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json');browser.close()
finally:server.shutdown();server.server_close()
