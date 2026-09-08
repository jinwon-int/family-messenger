"""Bounded synthetic worker for frontend control and cleanup tests."""
import json
import sys
import time

command=json.loads(sys.stdin.readline())
tid=command['turn_id']
def emit(**kw):print(json.dumps({'turn_id':tid,**kw}),flush=True)
emit(type='session',session_id='synthetic-session')
mode=sys.argv[1]
if mode in ('approve','cancel'):
    emit(type='approval',approval_id='n'*32,description='Synthetic action',arguments={'value':1})
    control=json.loads(sys.stdin.readline())
    assert control['turn_id']==tid
    if mode=='cancel':
        assert control['type']=='cancel'
        emit(type='result',status='uncertain',runtime_closed=True)
        sys.exit(1)  # The merged worker deliberately retires after uncertainty.
    assert control['type']=='approve' and control['approval_id']=='n'*32
    emit(type='approval-resolved',approval_id='n'*32,allowed=True)
emit(type='result',status='complete',text='synthetic answer',session_id='synthetic-session')
if mode=='slow-close':time.sleep(.3)
if mode=='hung-close':time.sleep(100)
assert sys.stdin.read()==''
sys.exit(1 if mode=='bad-close' else 0)
