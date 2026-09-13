"""Actual encrypted custody -> native declaration -> ordered bind, generated only."""
import base64
import time

def run(a,b,databases,rpc,init,reopen,prepare,proof,page,passwords,pins,direct,config,commit,crash,digest,hold_next,arrived,release,tamper,restart):
    group=rpc(a,'status')['group_id']
    intent={'id':'context-prepared','source':'family','target':'second','source_group':group,'pins':pins}
    path='/v1/mls/rooms/second/preparation'
    def fork(p,i,value=intent,reject=False,password=None):
        p.evaluate("spawn('fork')")
        arg={'identity':['alice','bob'][i],'database':databases[i],'password':password or passwords[i],'intent':value}
        result=p.evaluate('q=>call("fork","fork",q)',arg)
        if reject:assert not result['ok'] and 'result' not in result;return
        assert result['ok'],result
        return result['result']
    def inspect(p):return rpc(p,'test-aggregate-digest')
    def reserved():return direct('owner','GET',path)[1]['prepared']
    reservation={'room':'second','source_room':'family','source_group':group}
    assert direct('owner','POST','/v1/mls/context-reservations',reservation)[0]==201
    bind={'room':'second','group_id':'be'*32,'device_id':pins[0]['device_id'],'peer_device':pins[1]['device_id']}
    assert direct('owner','POST','/v1/mls/rooms',bind)[0]==409
    before=digest(a,0)
    for mode in ['invalid-json','oversize','wrong-header','wrong-room','wrong-key','duplicate-pin']:
        hook={'context':mode,'seen':0,'path':path};tamper[0]=hook
        try:fork(a,0,reject=True)
        finally:tamper[0]=None
        assert hook['seen']==1 and digest(a,0)==before and reserved()==[]
    fork(a,0,reject=True,password='X'*48)
    assert digest(a,0)==before and reserved()==[]
    proof['checks']['malformed_public_preparation_or_wrong_password_never_declares_or_consumes_slot']=True

    prepare(a,'app-old-pending',b'generated source pending')
    source=inspect(a)[0]
    one=fork(a,0)
    assert one['committed'] and one['preparation_accepted'] and not one['pair_prepared']
    assert inspect(a)[0]==source and len(reserved())==1
    assert direct('owner','POST','/v1/mls/rooms',bind)[0]==409
    assert direct('owner','POST','/v1/mls/reservations',{'room':'second','peer_actor':'bob'})[0]==409
    stable=digest(a,0)
    assert fork(a,0)==one and digest(a,0)==stable
    fork(a,0,{**intent,'id':'context-conflict'},reject=True)
    assert digest(a,0)==stable and len(reserved())==1
    proof['checks']['first_committed_custody_declares_once_and_cannot_bind_or_change_intent']=True

    # Hold the actual second declaration response, then kill its owned browser.
    b.evaluate("spawn('fork')")
    arrived.clear();release.clear();hold_next[0]=True
    b.evaluate('q=>{window.pending=call("fork","fork",q)}',{'identity':'bob','database':databases[1],'password':passwords[1],'intent':intent})
    assert arrived.wait(15)
    assert len(reserved())==2
    crash(1);release.set();b=page(1);init(b,1)
    before=digest(b,1);two=fork(b,1)
    assert two['pair_prepared'] and two['preparation_accepted'] and digest(b,1)==before
    assert inspect(a)[0]==source
    restart()
    assert len(reserved())==2 and direct('owner','POST','/v1/mls/context-reservations',reservation)[0]==200
    proof['checks']['lost_declaration_reply_browser_sigkill_server_restart_exact_retry']=True

    sa,sb=page(0),page(1);init(sa,0,selected_room='second');init(sb,1,selected_room='second')
    rpc(sa,'create');rpc(sa,'bind');rpc(sb,'attach')
    for sender,receiver in [(sb,sa),(sa,sb),(sb,sa)]:
        rpc(sender,'advance');rpc(sender,'flush');rpc(sender,'sync');rpc(receiver,'sync')
    assert rpc(sa,'status')['phase']==rpc(sb,'status')['phase']=='ready'
    prepare(sa,'app-new',b'generated protected conversation');rpc(sa,'flush');rpc(sa,'sync');rpc(sb,'sync')
    payload=bytes(range(256))*32
    prepare(sb,'app-file',payload,'file');rpc(sb,'flush');rpc(sb,'sync');rpc(sa,'sync')
    assert base64.b64decode(rpc(sa,'status')['messages'][-1]['payload'])==payload
    assert inspect(a)[0]==source
    rpc(a,'flush');rpc(a,'sync');rpc(b,'sync')
    assert rpc(b,'status')['messages'][-1]['client_id']=='app-old-pending'
    assert fork(a,0)['pair_prepared']
    proof['checks']['both_prepared_actual_mls_handshake_text_file_source_outbox_preserved']=True

    before=digest(a,0)
    config['devices'][1]['status']='revoked';config['devices'][1]['device_revision']=2;commit(2,config['people'])
    until=time.monotonic()+5
    while time.monotonic()<until:
        if direct('owner','GET',path)[0]==403:break
        time.sleep(.05)
    else:raise AssertionError('preparation revocation')
    fork(a,0,reject=True);rpc(sa,'sync',reject=True)
    assert digest(a,0)==before
    proof['checks']['revocation_denies_declaration_retry_and_native_delivery_without_reset']=True
    proof['boundary']='Actual OpenMLS worker/native preparation proof, no DOM UX or cryptographic proof of storage from a hostile declaring principal'
