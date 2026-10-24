#!/usr/bin/env python3
"""Atomic record writer for a node's ccc push spool (shared by health_check.py and homeserver_watchdog.py).

The node's bridge (Matrix on the homeserver node, Telegram on the dual-channel node)
globs ``*.json`` in the spool directory and moves delivered records away. A record is
therefore written as a dot-prefixed ``.tmp`` file (0600, O_EXCL, no symlink following)
and renamed into place after fsync, so the bridge never reads a half-written file.
Which bridge consumes the spool is the node's business: this module only writes.
"""
import json
import os
from pathlib import Path


def write_spool_record(spool, name, record):
    """Write ``record`` (a JSON object) as ``<spool>/<name>`` atomically; return ``name``.

    Raises ValueError when the spool directory is missing or a symlink, OSError on
    I/O failure. A failed write leaves no temp file behind.
    """
    spool = Path(spool)
    if spool.is_symlink() or not spool.is_dir():
        raise ValueError('untrusted push spool directory')
    if not name or name.startswith('.') or '/' in name:
        raise ValueError('bad spool record name')
    tmp = spool / ('.' + name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(record, out)
            out.flush()
            os.fsync(out.fileno())
        os.rename(tmp, spool / name)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    return name
