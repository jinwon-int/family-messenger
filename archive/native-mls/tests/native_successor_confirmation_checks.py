"""Opaque confirmation relay durability; real cryptography has browser proof."""
import base64
from concurrent.futures import ThreadPoolExecutor
import json


def confirm(request,binding,handshake,start,stop,checks):
    path='/v1/mls/successors/replacement-1/confirmation'
    group=json.loads(handshake)['records'][1]['request']['group_id']
    slots=[('owner','alice-candidate',dict(binding,kind='candidate_proof',group_id=group,payload=base64.b64encode(b'opaque candidate proof').decode())),('family','bob-first',dict(binding,kind='peer_proof',group_id=group,payload=base64.b64encode(b'opaque peer proof').decode()))]
    def post(slot):return request(slot[0],path,'POST',obj=slot[2],headers={'X-Family-Device':slot[1]})
    assert post(slots[1])[0]==409
    for i,slot in enumerate(slots):
        with ThreadPoolExecutor(max_workers=8) as pool:results=list(pool.map(lambda _:post(slot),range(8)))
        assert sorted(r[0] for r in results)==[200]*7+[201]
        raw=results[0][1];assert all(r[1]==raw for r in results)
        stop();start();assert post(slot)==(200,raw)
        v=json.loads(raw);assert v['revision']==i+1 and v['records'][i]['request']==slot[2]
    assert v['phase']=='confirmations-recorded-inactive'
    assert request('owner','/v1/mls/rooms/new-secure-1/log',headers={'X-Family-Device':'alice-candidate'})[0]==403
    checks['confirmation_each_slot_race_sigkill_exact_reconciliation_still_inactive']=True
    return path,raw
