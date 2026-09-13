"""User file input and explicit saved-list reopen; no installScopes injection."""
import copy
import json
from playwright.sync_api import expect
from password_worker_smoke import safe_bytes


def handoff_assets(root,assets,proof):
    for name in ('successor-handoff.html','successor-handoff.js','successor-handoff-ui.js'):
        assets['/successor-handoff/' if name.endswith('.html') else '/'+name]=safe_bytes(root/'experiments/openmls-browser/web'/name,65536)
    proof['handoff_original_assets']=True


def handoff_driver(scope,proof):
    imported=set();reopens={role:0 for role in ('candidate','peer')}
    def upload(p,doc):
        p.set_input_files('#handoff-file',{'name':'request.json','mimeType':'application/json','buffer':json.dumps(doc).encode()})
        p.click('#handoff-import')
    def empty(p):
        assert p.locator('#scope').input_value()=='' and p.locator('#action').input_value()=='' and p.locator('#password').input_value()=='' and p.locator('#run').is_disabled()
    def prepare(p,role):
        if not p.url.endswith('/successor-handoff/'):
            p.goto(p.url.split('/',3)[0]+'//'+p.url.split('/')[2]+'/successor-handoff/');p.wait_for_selector('#handoff-import');empty(p)
            assert p.locator('#scope option').count()==1
            if role not in imported:
                for bad in ({'version':1,'scopes':[dict(scope(role),password='must-not-be-retained')]},{'version':1,'scopes':[scope(role),scope(role)]}):
                    upload(p,bad);expect(p.locator('#handoff-status')).to_contain_text('불러올 수 없습니다');empty(p)
                    assert p.locator('#scope option').count()==1 and p.locator('#handoff-save').is_disabled()
                upload(p,{'version':1,'scopes':[scope(role)]});expect(p.locator('#scope option')).to_have_count(2);empty(p)
                p.click('#handoff-save');expect(p.locator('#handoff-status')).to_contain_text('보관했습니다')
                imported.add(role);p.reload();p.wait_for_selector('#handoff-load');empty(p)
                assert p.locator('#scope option').count()==1
            p.click('#handoff-load');expect(p.locator('#scope option')).to_have_count(2);empty(p);reopens[role]+=1
            assert p.locator('#handoff-file').input_value()==''
        if imported=={'candidate','peer'}:
            proof['checks']['handoff_public_file_exact_shape_rejects_extensions_and_duplicates']=True
        if all(n>=2 for n in reopens.values()):
            proof['checks']['handoff_explicit_saved_reopen_after_actual_browser_restart_no_auto_selection']=True
    def check(p,role,perform):
        prepare(p,role)
        bad=copy.deepcopy(scope(role));bad['reservation']['context']['target_room']='substituted-target'
        upload(p,{'version':1,'scopes':[bad]});expect(p.locator('#scope option')).to_have_count(2)
        assert perform(p,role,'enrollment-observe')=='unknown'
        # Imported hints do not overwrite the previously explicitly saved list.
        p.click('#handoff-load');expect(p.locator('#scope option')).to_have_count(2)
        assert perform(p,role,'enrollment-observe')=='active'
    return prepare,check
