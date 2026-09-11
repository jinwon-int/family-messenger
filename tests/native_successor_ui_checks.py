"""Actual DOM adapter over the existing paired custody/enrollment/closure proof."""
import copy
from playwright.sync_api import expect
from password_worker_smoke import safe_bytes


def ui_assets(root,assets,proof):
    web=root/'experiments/openmls-browser/web'
    for name in ('successor.html','successor-ui.js','successor-ui.css','successor-lifecycle-worker.js','candidate-lifecycle-worker.js','peer-lifecycle-worker.js'):
        assets['/successor/' if name=='successor.html' else '/'+name]=safe_bytes(web/name,65536)
    # The UI runs the unmodified protected store bundle; fault bundles stay separate.
    for role in ('candidate','peer'):
        key='/'+role+'-lifecycle-worker.js';assets[key]=assets[key].replace(b'./successor-closure-store.js',b'./closure-original-store.js')
    proof['successor_ui_original_workers']=True


def install(hooks,expected,databases,database,passwords,candidate_actor,proof):
    peer_actor='alice' if candidate_actor=='bob' else 'bob';seen=set();states=[]
    def scope(role):return {'identity':candidate_actor if role=='candidate' else peer_actor,'role':role,'database':database if role=='candidate' else databases[0],'reservation':copy.deepcopy(expected)}
    if hooks.get('ui_handoff'):
        from native_successor_handoff_checks import handoff_driver
        handoff_prepare,handoff_check=handoff_driver(scope,proof)
    def prepare(p,role):
        if hooks.get('ui_handoff'):
            handoff_prepare(p,role)
        elif not p.url.endswith('/successor/'):
            p.goto(p.url.split('/',3)[0]+'//'+p.url.split('/')[2]+'/successor/');p.wait_for_selector('#scope')
            assert p.locator('#scope').input_value()=='' and p.locator('#action').input_value()==''
            assert p.locator('#run').is_disabled()
            p.evaluate("async x=>{const m=await import('/successor-ui.js');m.installScopes([x]);x.reservation.context.target_room='mutated-after-install';}",scope(role))
            assert p.locator('#scope').input_value()=='' and p.locator('#run').is_disabled()
        p.select_option('#scope','1')
        if not hooks.get('ui_handoff'):assert expected['context']['target_room'] in p.locator('#selection').inner_text()
        assert expected['context'][role]['device_id'] in p.locator('#selection').inner_text()
        seen.add(role)
    def perform(p,role,kind):
        prepare(p,role);p.select_option('#action',kind)
        assert p.locator('#password').input_value()=='' and p.locator('#run').is_disabled()
        p.fill('#password',passwords[1 if role=='candidate' else 0])
        if kind in ('enroll','closure-close'):
            assert p.locator('#run').is_disabled();p.check('#consent')
        p.click('#run');expect(p.locator('#status')).not_to_have_attribute('data-state','working',timeout=25000)
        expect(p.locator('#status')).not_to_have_attribute('data-state','local-committed',timeout=25000)
        state=p.locator('#status').get_attribute('data-state');states.append(state)
        assert state in ('unknown','active','awaiting-admin','awaiting-peer','local-saved','closed','local-closed'),state
        assert p.locator('#password').input_value()=='' and not p.locator('#consent').is_checked() and p.locator('#run').is_disabled()
        assert not any(x in p.locator('body').inner_text() for x in ('private_provider','signature','approval_sha256','crypto_secretstream'))
        return state
    def fault(p,role):
        assets=hooks['ui_asset_map'];key='/'+role+'-lifecycle-worker.js';old=assets[key]
        assets[key]=old.replace(b'./closure-original-store.js',b'./successor-closure-store.js').replace(b'lifecycleWorker(await init(),',b"self.testFault='abort-after-write';lifecycleWorker(await init(),")
        try:return perform(p,role,'closure-close')
        finally:assets[key]=old
    hooks['ui']={'fault':fault,'perform':perform,'seen':seen,'states':states,'scope':scope}
    if hooks.get('ui_handoff'):hooks['ui']['handoff_check']=lambda p,role:handoff_check(p,role,perform)


def finish(hooks,proof):
    ui=hooks['ui'];assert ui['seen']=={'candidate','peer'}
    assert all(state in ui['states'] for state in ('awaiting-admin','active','closed','unknown')),ui['states']
    proof['checks']['actual_DOM_explicit_scope_consent_no_credential_reuse_and_no_private_outputs']=True
    proof['checks']['actual_DOM_paired_approval_admin_active_closure_and_unknown_states']=True
