import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('initialize',ROOT/'scripts/init.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


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
                with self.assertRaises(ValueError):m.initialize(root,'preview.invalid','http://127.0.0.1:18808','http://127.0.0.1:18809',True)
                self.assertEqual(before,(root/'.runtime/synapse/homeserver.yaml').read_bytes())

    def test_reject_symlink_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'.runtime').symlink_to(root/'missing')
            with self.assertRaises(ValueError):m.initialize(root,'preview.invalid','http://127.0.0.1:18808','http://127.0.0.1:18809',True)


if __name__=='__main__':unittest.main()
