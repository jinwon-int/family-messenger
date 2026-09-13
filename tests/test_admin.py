import contextlib
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
from admin import AdminClient, load_admin_token, load_tuwunel_config, parse, run_command, setting

EXAMPLE = Path(__file__).parents[1] / 'deploy' / 'tuwunel' / 'tuwunel.toml.example'


def write_config(root, address=('127.0.0.1',), port='18809', server='family.example', database='data/db',
                 backups='data/backups'):
    """Config in the deploy/tuwunel/tuwunel.toml.example shape: [global], list address, database_path."""
    config = root / 'tuwunel.toml'
    lines = ['[global]', 'server_name = ' + json.dumps(server),
             'address = ' + (json.dumps(list(address)) if isinstance(address, tuple) else address),
             'port = ' + str(port), 'database_path = ' + json.dumps(str(root / database))]
    if backups is not None:
        lines.append('database_backup_path = ' + json.dumps(str(root / backups)))
    config.write_text('\n'.join(lines) + '\n')
    return config


def write_token(root, mode=0o600, text='tok\n'):
    token = root / 'admin_token'
    token.write_text(text)
    token.chmod(mode)
    return token


def recording_client(server='family.example', token='tok'):
    calls = []

    def send(method, path, body, headers):
        calls.append({'method': method, 'path': path, 'body': body, 'headers': headers})
        return {'user_id': '@fam:' + server}

    return AdminClient('http://127.0.0.1:8008', server, token, send=send), calls


class SettingTests(unittest.TestCase):
    def test_top_level_then_global_section(self):
        self.assertEqual(setting({'server_name': 'a.example'}, 'server_name'), 'a.example')
        self.assertEqual(setting({'global': {'database_path': '/x'}}, 'database_path'), '/x')
        self.assertEqual(setting({'global': {'database': {'path': '/x'}}}, 'database', 'path'), '/x')
        self.assertIsNone(setting({}, 'database_backup_path', default=None))
        with self.assertRaises(KeyError):
            setting({}, 'server_name')


class LoadConfigTests(unittest.TestCase):
    def test_reads_loopback_base_and_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = write_config(Path(tmp))
            loaded = load_tuwunel_config(config)
            self.assertEqual(loaded['base'], 'http://127.0.0.1:18809')
            self.assertEqual(loaded['server_name'], 'family.example')
            self.assertEqual(loaded['address'], ['127.0.0.1'])
            self.assertEqual(loaded['database'], Path(tmp) / 'data' / 'db')
            self.assertEqual(loaded['database_backup_path'], Path(tmp) / 'data' / 'backups')
            self.assertEqual(loaded['config_path'], config)

    def test_address_string_form_and_multiple_loopback_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(load_tuwunel_config(write_config(Path(tmp), address='"127.0.0.1"'))['address'],
                             ['127.0.0.1'])
            self.assertEqual(load_tuwunel_config(write_config(Path(tmp), address=('127.0.0.1', '::1')))['address'],
                             ['127.0.0.1', '::1'])

    def test_legacy_top_level_and_database_table_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'tuwunel.toml'
            config.write_text('server_name = "family.example"\n'
                              'address = "127.0.0.1"\n'
                              'port = 18809\n'
                              '[database]\n'
                              'path = ' + json.dumps(str(Path(tmp) / 'db')) + '\n')
            loaded = load_tuwunel_config(config)
            self.assertEqual(loaded['base'], 'http://127.0.0.1:18809')
            self.assertEqual(loaded['database'], Path(tmp) / 'db')
            self.assertIsNone(loaded['database_backup_path'])

    def test_parses_shipped_example_config(self):
        text = re.sub(r'<[^>\n]*>', 'example.com', EXAMPLE.read_text())
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'tuwunel.toml'
            config.write_text(text)
            loaded = load_tuwunel_config(config)
            self.assertEqual(loaded['base'], 'http://127.0.0.1:8008')
            self.assertEqual(loaded['server_name'], 'example.com')
            self.assertEqual(loaded['address'], ['127.0.0.1'])
            self.assertEqual(loaded['database'], Path('/var/lib/tuwunel'))
            self.assertEqual(loaded['database_backup_path'], Path('/var/lib/tuwunel-backups'))

    def test_refuses_non_loopback_address(self):
        with tempfile.TemporaryDirectory() as tmp:
            for address in ('"0.0.0.0"', ('127.0.0.1', '0.0.0.0'), '[]', '8008'):
                with self.subTest(address=address), self.assertRaises(ValueError):
                    load_tuwunel_config(write_config(Path(tmp), address=address))

    def test_refuses_non_integer_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = write_config(Path(tmp), port='"18809"')
            with self.assertRaises(ValueError):
                load_tuwunel_config(config)


class LoadTokenTests(unittest.TestCase):
    def test_reads_private_regular_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(load_admin_token(write_token(Path(tmp))), 'tok')

    def test_refuses_group_or_other_readable(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                load_admin_token(write_token(Path(tmp), mode=0o644))

    def test_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = write_token(Path(tmp))
            link = Path(tmp) / 'link'
            link.symlink_to(real)
            with self.assertRaises(ValueError):
                load_admin_token(link)

    def test_refuses_empty_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                load_admin_token(write_token(Path(tmp), text='  \n'))


class AdminClientTests(unittest.TestCase):
    def test_refuses_non_loopback_base(self):
        with self.assertRaises(ValueError):
            AdminClient('http://matrix.example.com:8008', 'family.example', 'tok', send=lambda *a: {})

    def test_user_id_shape_and_validation(self):
        client, calls = recording_client()
        self.assertEqual(client.user_id('fam'), '@fam:family.example')
        with self.assertRaises(ValueError):
            client.user_id('Fam')
        with self.assertRaises(ValueError):
            client.user_id('fa m')
        self.assertEqual(calls, [])

    def test_create_user_omits_admin_field_by_default(self):
        client, calls = recording_client()
        client.create_user('fam', 'password1234')
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['method'], 'PUT')
        self.assertEqual(calls[0]['path'], '/_synapse/admin/v2/users/%40fam%3Afamily.example')
        self.assertEqual(json.loads(calls[0]['body']), {'password': 'password1234'})
        self.assertEqual(calls[0]['headers']['Authorization'], 'Bearer tok')
        self.assertEqual(calls[0]['headers']['Content-Type'], 'application/json')

    def test_create_user_sends_admin_true_only_when_explicit(self):
        client, calls = recording_client()
        client.create_user('fam', 'password1234', admin=True)
        self.assertEqual(json.loads(calls[0]['body']),
                         {'password': 'password1234', 'admin': True})

    def test_create_user_sends_display_name(self):
        client, calls = recording_client()
        client.create_user('fam', 'password1234', display_name='가족')
        self.assertEqual(json.loads(calls[0]['body']),
                         {'password': 'password1234', 'displayname': '가족'})

    def test_create_user_rejects_short_password_before_any_call(self):
        client, calls = recording_client()
        with self.assertRaises(ValueError):
            client.create_user('fam', 'password123')
        self.assertEqual(calls, [])

    def test_deactivate_user_posts(self):
        client, calls = recording_client()
        client.deactivate_user('@fam:family.example')
        self.assertEqual(calls[0]['method'], 'POST')
        self.assertEqual(calls[0]['path'],
                         '/_synapse/admin/v1/deactivate/%40fam%3Afamily.example')
        self.assertEqual(json.loads(calls[0]['body']), {})

    def test_list_users_query(self):
        client, calls = recording_client()
        client.list_users()
        client.list_users(deactivated=True)
        self.assertEqual(calls[0]['path'], '/_synapse/admin/v2/users?deactivated=false')
        self.assertEqual(calls[1]['path'], '/_synapse/admin/v2/users?deactivated=true')

    def test_list_rooms_gets_rooms(self):
        client, calls = recording_client()
        client.list_rooms()
        self.assertEqual((calls[0]['method'], calls[0]['path']), ('GET', '/_synapse/admin/v1/rooms'))


class ParseTests(unittest.TestCase):
    def test_legacy_positional_form_is_register(self):
        args = parse(['owner', '--admin'])
        self.assertEqual((args.command, args.username, args.admin), ('register', 'owner', True))
        args = parse(['family_member'])
        self.assertEqual((args.command, args.username, args.admin), ('register', 'family_member', False))

    def test_no_arguments_fails(self):
        with self.assertRaises(SystemExit):
            parse([])

    def test_create_subcommand(self):
        args = parse(['create', 'fam', '--display-name', '가족'])
        self.assertEqual((args.command, args.username, args.admin, args.display_name),
                         ('create', 'fam', False, '가족'))

    def test_deactivate_requires_yes_flag_parsing(self):
        args = parse(['deactivate', '@fam:family.example', '--yes'])
        self.assertEqual((args.command, args.user_id, args.yes),
                         ('deactivate', '@fam:family.example', True))

    def test_listing_subcommands(self):
        self.assertEqual(parse(['list-users']).deactivated, False)
        self.assertEqual(parse(['list-users', '--deactivated']).deactivated, True)
        self.assertEqual(parse(['list-rooms']).command, 'list-rooms')


class RunCommandTests(unittest.TestCase):
    def test_register_password_mismatch_fails(self):
        with mock.patch('getpass.getpass', side_effect=['password1234', 'password4321']):
            with self.assertRaises(ValueError):
                run_command(parse(['owner']))

    def test_create_uses_config_token_and_reports_user(self):
        loaded = {'base': 'http://127.0.0.1:18809', 'server_name': 'family.example',
                  'database': Path('/tmp/db'), 'config_path': Path('/tmp/t.toml')}

        class StubClient:
            instance = None

            def __init__(self, base, server, token, send=None):
                self.init = (base, server, token)
                StubClient.instance = self

            def create_user(self, username, password, admin=False, display_name=None):
                self.created = (username, password, admin, display_name)
                return {'user_id': '@fam:family.example'}

        with mock.patch('getpass.getpass', return_value='password1234'), \
             mock.patch('admin.load_tuwunel_config', return_value=loaded), \
             mock.patch('admin.load_admin_token', return_value='tok'), \
             mock.patch('admin.AdminClient', StubClient) as stub:
            run_command(parse(['create', 'fam', '--display-name', '가족']))
            self.assertEqual(stub.instance.init, ('http://127.0.0.1:18809', 'family.example', 'tok'))
            self.assertEqual(stub.instance.created, ('fam', 'password1234', False, '가족'))

    def test_create_prints_full_user_id_from_name_user_id_or_fallback(self):
        loaded = {'base': 'http://127.0.0.1:18809', 'server_name': 'family.example',
                  'database': Path('/tmp/db'), 'config_path': Path('/tmp/t.toml')}
        cases = [({'name': '@fam:family.example'}, '@fam:family.example'),  # Tuwunel PUT v2/users
                 ({'user_id': '@fam:family.example'}, '@fam:family.example'),  # Synapse
                 ({}, '@fam:family.example')]  # neither: derived from username + server_name
        for result, expected in cases:
            with self.subTest(result=result):
                client = AdminClient('http://127.0.0.1:18809', 'family.example', 'tok',
                                     send=lambda *a, result=result: result)
                out = io.StringIO()
                with mock.patch('getpass.getpass', return_value='password1234'), \
                     mock.patch('admin.load_tuwunel_config', return_value=loaded), \
                     mock.patch('admin.load_admin_token', return_value='tok'), \
                     mock.patch('admin.AdminClient', return_value=client), \
                     contextlib.redirect_stdout(out):
                    run_command(parse(['create', 'fam']))
                self.assertEqual(out.getvalue(), 'Created ' + expected + '; credentials were not logged.\n')
                self.assertNotIn('Created fam;', out.getvalue())

    def test_deactivate_refuses_without_yes(self):
        with self.assertRaises(ValueError):
            run_command(parse(['deactivate', '@fam:family.example']))


if __name__ == '__main__':
    unittest.main()
