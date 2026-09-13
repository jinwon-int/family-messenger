"""Opaque signed relay process proof; no cryptographic completion or activation."""
import base64
from concurrent.futures import ThreadPoolExecutor
import json


def exchange(request,binding,start,stop,checks):
    path='/v1/mls/successors/replacement-1/handshake'
    group='cd'*16
    slots=[('owner','alice-candidate',dict(binding,kind='key_package',group_id='',payload=base64.b64encode(b'synthetic public package reference').decode())),
           ('family','bob-first',dict(binding,kind='welcome',group_id=group,payload=base64.b64encode(b'synthetic opaque Welcome').decode())),
           ('owner','alice-candidate',dict(binding,kind='ack',group_id=group,payload=''))]
    def post(who,device,q):return request(who,path,'POST',obj=q,headers={'X-Family-Device':device})
    assert request(None,path)[0]==401
    assert post(*slots[1])[0]==409 and post(*slots[2])[0]==409
    assert post('family','bob-first',slots[0][2])[0]==403
    assert post('owner','alice-candidate',dict(slots[0][2],payload=base64.b64encode(b'regenerated package').decode()))[0]==400
    for index,slot in enumerate(slots):
        with ThreadPoolExecutor(max_workers=8) as pool:results=list(pool.map(lambda _:post(*slot),range(8)))
        assert sorted(x[0] for x in results)==[200]*7+[201]
        first=results[0][1];assert all(x[1]==first for x in results)
        # Drop the successful result, kill the owned server, and reconcile exact bytes.
        stop();start();assert post(*slot)==(200,first)
        value=json.loads(first);assert value['revision']==index+1
        assert value['records'][index]['request']==slot[2]
        for old in slots[:index+1]:assert post(*old)==(200,first)
        if index==1:assert post(slot[0],slot[1],dict(slot[2],payload=base64.b64encode(b'changed Welcome').decode()))[0]==409
    assert json.loads(first)['phase']=='exchange-recorded-inactive'
    for who,device,_ in slots[:2]:
        assert request(who,'/v1/mls/rooms/new-secure-1/log',headers={'X-Family-Device':device})[0]==403
        assert request(who,'/v1/rooms/new-secure-1/messages',headers={'X-Family-Device':device})[0]==403
    checks['handshake_exact_package_order_cas_and_each_slot_sigkill_retry']=True
    checks['opaque_exchange_remains_inactive_with_ordinary_delivery_denied']=True
    return path,first
