import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('initialize',ROOT/'scripts/init.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
spec=importlib.util.spec_from_file_location('admin',ROOT/'scripts/admin.py');admin=importlib.util.module_from_spec(spec);spec.loader.exec_module(admin)


class ConfigurationTests(unittest.TestCase):
    def test_reject_unsafe_origins(self):
        for web,matrix in [('https://a.example','http://b.example'),('https://a.example','https://a.example'),
                           ('https://user:secret@a.example','https://b.example'),('https://a.example/path','https://b.example')]:
            with self.subTest(web=web),self.assertRaises(ValueError):m.validated_urls('a.example',web,matrix,False)

    def test_private_defaults(self):
        hs,client=m.configs('family.example','https://chat.example','https://matrix.example','db-secret','reg-secret')
        self.assertFalse(hs['enable_registration']);self.assertFalse(hs['allow_guest_access'])
        self.assertEqual(hs['federation_domain_whitelist'],[])
        self.assertEqual(hs['listeners'][0]['resources'][0]['names'],['client'])
        self.assertEqual(hs['encryption_enabled_by_default_for_room_type'],'all')
        self.assertNotIn('m.identity_server',client['default_server_config'])

    def test_initialization_secrets_and_no_overwrite(self):
        for umask in (0o022,0o077):
            with tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);old=os.umask(umask)
                try:m.initialize(root,'preview.invalid','http://127.0.0.1:18808','http://127.0.0.1:18809',True)
                finally:os.umask(old)
                before=(root/'.runtime/synapse/homeserver.yaml').read_bytes()
                for n in ('.env','.runtime/postgres.env','.runtime/synapse/homeserver.yaml'):
                    self.assertEqual((root/n).stat().st_mode & 0o777,0o600)
                self.assertEqual((root/'.runtime/element.json').stat().st_mode & 0o777,0o644)
                with self.assertRaises(ValueError):m.initialize(root,'preview.invalid','http://127.0.0.1:18808','http://127.0.0.1:18809',True)
                self.assertEqual(before,(root/'.runtime/synapse/homeserver.yaml').read_bytes())

    def test_reject_symlink_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'.runtime').symlink_to(root/'missing')
            with self.assertRaises(ValueError):m.initialize(root,'preview.invalid','http://127.0.0.1:18808','http://127.0.0.1:18809',True)

    def test_custom_ports_and_admin_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            m.initialize(root,'preview.invalid','http://127.0.0.1:19908','http://127.0.0.1:19909',True)
            self.assertIn('WEB_PORT=19908', (root/'.env').read_text())
            self.assertIn('MATRIX_PORT=19909', (root/'.env').read_text())
            self.assertEqual(admin.local_base(root),'http://127.0.0.1:19909')
            with mock.patch.object(admin,'ROOT',root),mock.patch.object(admin.urllib.request,'build_opener') as opener:
                response=opener.return_value.open.return_value.__enter__.return_value
                response.read.return_value=b'{}'
                admin.request('/_synapse/admin/v1/register',{'password':'synthetic-password'})
                self.assertEqual(opener.return_value.open.call_args.args[0].full_url,'http://127.0.0.1:19909/_synapse/admin/v1/register')
            (root/'.env').write_text((root/'.env').read_text().replace('19909','18809'))
            with mock.patch.object(admin,'ROOT',root),mock.patch.object(admin.urllib.request,'build_opener') as opener:
                with self.assertRaises(ValueError):admin.request('/_synapse/admin/v1/register',{'password':'synthetic-password'})
                opener.assert_not_called()

    def test_same_preview_ports_rejected(self):
        with self.assertRaises(ValueError):m.validated_urls('preview.invalid','http://127.0.0.1:19908','http://127.0.0.1:19908',True)


if __name__=='__main__':unittest.main()
