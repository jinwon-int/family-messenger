import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from fleet_core import Request
from fleet_matrix_state import MatrixStore, main, operator_name

ACCOUNT='@bot:test.invalid'
ROOM='!room:test.invalid'
OWNER='@owner:test.invalid'
SCOPE=hashlib.sha256(json.dumps([ACCOUNT,ROOM,OWNER]).encode()).hexdigest()
OTHER='f'*64


def uncertain_job(store,event='$job'):
    store.accept_batch([Request(event,ROOM,OWNER,'synthetic prompt',SCOPE)],'token')
    store.claim();store.uncertain_job(event)


class UnblockTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.state=Path(self.temp.name)/'state'
        self.addCleanup(self.temp.cleanup)

    def cli(self,*argv):
        out,err=io.StringIO(),io.StringIO()
        code=main(list(argv),out=out,err=err)
        return code,out.getvalue(),err.getvalue()

    def test_recorded_scope_block_is_cleared_once_and_audited(self):
        with MatrixStore(self.state,ACCOUNT) as s:
            uncertain_job(s)
            s.set_meta('worker_cleanup_unconfirmed',{'scope':SCOPE,'event_id':'$job','updated':1.0})
            s.set_meta('worker_cleanup_in_progress',True)
            self.assertEqual(s.block()['blocked_scopes'],[SCOPE])
            result=s.unblock(SCOPE,'runtime pid verified exited',operator_name())
            self.assertEqual(result['cleared'],['worker_cleanup_unconfirmed','worker_cleanup_in_progress'])
            self.assertIsNone(s.block())
            self.assertIsNone(s.get_meta('worker_cleanup_unconfirmed'))
            self.assertIs(s.get_meta('worker_cleanup_in_progress'),False)
            with self.assertRaisesRegex(ValueError,'no-block'):s.unblock(SCOPE,'again',operator_name())
        with MatrixStore(self.state,ACCOUNT) as s:
            audit=s.audit()
            self.assertEqual(len(audit),1)
            self.assertEqual((audit[0]['action'],audit[0]['scope'],audit[0]['reason']),
                             ('unblock',SCOPE,'runtime pid verified exited'))
            self.assertEqual(audit[0]['actor'],operator_name())
            self.assertEqual(json.loads(audit[0]['before'])['worker_cleanup_unconfirmed']['event_id'],'$job')
            self.assertNotIn('synthetic prompt',audit[0]['before'])
            self.assertTrue(s.uncertain(),'uncertain work still needs /ack; unblock never rewrites jobs')

    def test_other_scope_or_invalid_input_changes_nothing(self):
        with MatrixStore(self.state,ACCOUNT) as s:
            s.set_meta('worker_cleanup_unconfirmed',{'scope':SCOPE,'event_id':'$job','updated':1.0})
            for scope,reason in ((OTHER,'ok'),('not-hex','ok'),(SCOPE,''),(SCOPE,'x'*2000)):
                with self.subTest(scope=scope,reason=reason),self.assertRaises(ValueError):
                    s.unblock(scope,reason,operator_name())
            self.assertEqual(s.block()['blocked_scopes'],[SCOPE])
            self.assertEqual(s.audit(),[])

    def test_legacy_boolean_block_is_attributed_through_uncertain_jobs(self):
        with MatrixStore(self.state,ACCOUNT) as s:
            s.set_meta('worker_cleanup_unconfirmed',True)
            self.assertEqual(s.block()['blocked_scopes'],[])
            with self.assertRaisesRegex(ValueError,'scope-not-blocked'):s.unblock(SCOPE,'reason',operator_name())
            uncertain_job(s)
            self.assertEqual(s.block()['blocked_scopes'],[SCOPE])
            s.unblock(SCOPE,'reason',operator_name())
            self.assertIsNone(s.block())

    def test_cli_refuses_while_service_holds_the_lock(self):
        with MatrixStore(self.state,ACCOUNT) as s:
            s.set_meta('worker_cleanup_unconfirmed',{'scope':SCOPE,'event_id':'$job','updated':1.0})
            code,out,err=self.cli('unblock','--state',str(self.state),'--account',ACCOUNT,'--scope',SCOPE,'--reason','x')
            self.assertEqual(code,2);self.assertIn('locked',err);self.assertEqual(out,'')
            self.assertTrue(s.get_meta('worker_cleanup_unconfirmed'))
            self.assertEqual(s.audit(),[])

    def test_cli_status_then_unblock_prints_changes(self):
        with MatrixStore(self.state,ACCOUNT) as s:
            s.set_meta('worker_cleanup_unconfirmed',{'scope':SCOPE,'event_id':'$job','updated':1.0})
        code,out,_=self.cli('status','--state',str(self.state/'inbox.sqlite3'),'--account',ACCOUNT)
        self.assertEqual(code,0);self.assertEqual(json.loads(out)['block']['blocked_scopes'],[SCOPE])
        code,_,err=self.cli('unblock','--state',str(self.state),'--account',ACCOUNT,'--scope',OTHER,'--reason','x')
        self.assertEqual(code,2);self.assertIn('scope-not-blocked',err)
        code,out,_=self.cli('unblock','--state',str(self.state),'--account',ACCOUNT,'--scope',SCOPE,'--reason','verified')
        self.assertEqual(code,0)
        report=json.loads(out)['unblocked']
        self.assertEqual((report['cleared'],report['scope'],report['audit_seq']),(['worker_cleanup_unconfirmed'],SCOPE,1))
        code,out,_=self.cli('status','--state',str(self.state),'--account',ACCOUNT)
        self.assertEqual(code,0);self.assertIsNone(json.loads(out)['block'])
        code,_,err=self.cli('unblock','--state',str(self.state),'--account','@other:test.invalid','--scope',SCOPE,'--reason','x')
        self.assertEqual(code,2);self.assertIn('identity',err)

    def test_cli_requires_state_and_account(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
            main(['status','--state',str(self.state)],out=io.StringIO(),err=io.StringIO())


if __name__=='__main__':unittest.main()
