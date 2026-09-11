#!/usr/bin/env python3
"""Regression for interrupted lifecycle uncertainty erased by public list reset."""
import argparse, json, threading
import tempfile
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from playwright.sync_api import sync_playwright,expect
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--web-root',type=Path,default=root/'experiments/openmls-browser/web');args=parser.parse_args();web=args.web_root
(root/'artifacts').mkdir(exist_ok=True)
work=Path(tempfile.mkdtemp(prefix='handoff-protocol-',dir=root/'artifacts'))
allowed={x:'text/javascript' for x in ('successor-handoff-ui.js','successor-handoff.js','successor-ui.js')};allowed.update({'successor-handoff.html':'text/html','successor-ui.css':'text/css'})
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  name=self.path.lstrip('/') or 'successor-handoff.html'
  if name not in allowed:self.send_error(404);return
  body=(web/name).read_bytes();self.send_response(200);self.send_header('Content-Type',allowed[name]);self.end_headers();self.wfile.write(body)
 def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
pin=lambda actor,device,key:{'actor':actor,'device_id':device,'device_revision':1,'signing_key':key*64}
context={'version':1,'intent_id':'generated-intent','decision_revision':1,'expires_at':1,'source_room':'source','source_group':'ab'*16,'target_room':'target','predecessor':pin('alice','old','1'),'candidate':pin('alice','new','2'),'peer':pin('bob','peer','3'),'candidate_fingerprint':'4'*64,'package_sha256':'5'*64,'admission':'preflight-only'}
doc={'version':1,'scopes':[{'identity':'alice','role':'candidate','database':'generated-review-db','reservation':{'version':1,'reservation_id':'generated-reservation','context':context,'phase':'reserved-inactive'}}]}
checks={}
try:
 with sync_playwright() as pw:
  browser=pw.chromium.launch(headless=True);p=browser.new_page();p.goto(f'http://127.0.0.1:{server.server_port}/');p.wait_for_selector('#handoff-load')
  results=[]
  for initial in ('working','local-committed'):
   for mode in ('manual-lock','broadcast-lock','hide','import','load'):
    p.reload();p.wait_for_selector('#handoff-load')
    p.evaluate("""initial=>{window.Worker=class {constructor(){setTimeout(()=>this.onmessage?.({data:{boot:true}}),0)}postMessage(){if(initial==='local-committed')setTimeout(()=>this.onmessage?.({data:{id:1,progress:'local-committed'}}),0)}terminate(){window.terminated=true}};}""",initial)
    p.set_input_files('#handoff-file',{'name':'generated.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#handoff-import');expect(p.locator('#scope option')).to_have_count(2)
    p.click('#handoff-save');p.select_option('#scope','1');p.select_option('#action','closure-close');p.fill('#password','synthetic-only');p.check('#consent');p.click('#run');expect(p.locator('#status')).to_have_attribute('data-state',initial)
    if mode=='manual-lock':p.click('#lock')
    elif mode=='broadcast-lock':p.evaluate("()=>{const c=new BroadcastChannel('family-vault-ui-lock-v1');c.postMessage('lock');setTimeout(()=>c.close(),10)}")
    elif mode=='hide':p.evaluate("()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'))}")
    elif mode=='import':
     p.set_input_files('#handoff-file',{'name':'generated.json','mimeType':'application/json','buffer':json.dumps(doc).encode()});p.click('#handoff-import')
    else:p.click('#handoff-load')
    expect(p.locator('#handoff-uncertain')).to_be_visible()
    assert p.locator('#password').input_value()=='' and p.locator('#scope').input_value()=='' and p.evaluate('window.terminated')
    if mode!='hide':
     p.click('#handoff-load');expect(p.locator('#scope option')).to_have_count(2)
     expect(p.locator('#handoff-uncertain')).to_be_visible()
    checks[initial+'_'+mode+'_retains_unknown_warning']=True
    after={'mode':mode,'before_state':initial,'state':p.locator('#status').get_attribute('data-state'),'text':p.locator('#status').inner_text(),'handoff_text':p.locator('#handoff-status').inner_text(),'worker_terminated':p.evaluate('window.terminated'),'scope':p.locator('#scope').input_value(),'password':p.locator('#password').input_value()}
    results.append(after)
  proof={'kind':'controlled fake Worker cancellation protocol; separate from actual private custody proof','passed':True,'checks':checks}
  (work/'verification.json').write_text(json.dumps(proof,indent=2)+'\n');print(work/'verification.json')
  browser.close()
finally:server.shutdown();server.server_close()
