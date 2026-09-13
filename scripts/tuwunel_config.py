#!/usr/bin/env python3
"""Shared loader for the stage-1 Tuwunel homeserver config and admin token.

The config shape follows deploy/tuwunel/tuwunel.toml.example: keys live either
at the top level or under ``[global]``; ``address`` is a string or a list of
strings (every entry must be loopback); the database lives at ``database_path``
(legacy ``[database] path`` is accepted as a fallback) and the built-in online
backups at ``database_backup_path``, which must not sit inside the database.
One copy of this logic serves admin.py, tuwunel_backup.py and the restore drill.
"""
from pathlib import Path
import stat
import tomllib

ROOT = Path(__file__).resolve().parents[1]
TUWUNEL_CONFIG = ROOT / '.runtime/tuwunel/tuwunel.toml'
TUWUNEL_TOKEN = ROOT / '.runtime/tuwunel/admin_token'
LOOPBACK = ('127.0.0.1', 'localhost', '::1')
_MISSING = object()


def setting(config, *keys, default=_MISSING):
    """Read a config key from either top level or the [global] section."""
    sections = [config]
    if isinstance(config.get('global'), dict):
        sections.append(config['global'])
    for section in sections:
        node = section
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                node = None
                break
            node = node[key]
        if node is not None:
            return node
    if default is not _MISSING:
        return default
    raise KeyError('.'.join(keys))


def loopback_addresses(value):
    """Normalize ``address`` (str or list of str) and require every entry loopback."""
    addresses = [value] if isinstance(value, str) else value
    if not isinstance(addresses, list) or not addresses:
        raise ValueError('address must be a string or a non-empty list of strings')
    for address in addresses:
        if not isinstance(address, str) or address not in LOOPBACK:
            raise ValueError('admin API requires a loopback bind; refusing non-loopback address')
    return addresses


def load_tuwunel_config(path=None):
    """Load the homeserver config and require a loopback-only listener.

    Returns config_path, base (loopback URL), server_name, address list, port,
    database (Path) and database_backup_path (Path or None when unset).
    """
    path = Path(path or TUWUNEL_CONFIG)
    with open(path, 'rb') as f:
        config = tomllib.load(f)
    addresses = loopback_addresses(setting(config, 'address'))
    port = setting(config, 'port')
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError('invalid admin API port')
    server_name = setting(config, 'server_name')
    if not isinstance(server_name, str) or not server_name:
        raise ValueError('missing server_name')
    database = setting(config, 'database_path', default=None)
    if database is None:
        database = setting(config, 'database', 'path')
    if not isinstance(database, str) or not database:
        raise ValueError('invalid database_path')
    backup = setting(config, 'database_backup_path', default=None)
    if backup is not None and (not isinstance(backup, str) or not backup):
        raise ValueError('invalid database_backup_path')
    return {'config_path': path, 'base': 'http://127.0.0.1:' + str(port), 'server_name': server_name,
            'address': addresses, 'port': port, 'database': Path(database),
            'database_backup_path': None if backup is None else Path(backup)}


def backup_directory(loaded):
    """Require database_backup_path and refuse one nested inside the database."""
    backups = loaded['database_backup_path']
    if backups is None:
        raise ValueError('database_backup_path is required for backup and restore')
    database = loaded['database']
    if backups == database or database in backups.parents:
        raise ValueError('database_backup_path must not be inside database_path')
    return backups


def load_admin_token(path=None):
    """Read the admin API bearer token; never log or echo its contents."""
    path = Path(path or TUWUNEL_TOKEN)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('admin token is not a regular file')
    if info.st_mode & 0o077:
        raise ValueError('admin token must not be readable by group or others')
    token = path.read_text().strip()
    if not token:
        raise ValueError('admin token file is empty')
    return token
