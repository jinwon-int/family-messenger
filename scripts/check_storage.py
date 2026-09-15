#!/usr/bin/env python3
"""Read-only disk/retention-budget check. Never purges messages or media.

Storage trees are operator-supplied arguments; the module itself carries no
compose-project coupling. It remains the measure for the Tuwunel plane: the
retained storage timer runs it against the data tree, and the Tuwunel backup
path (scripts/tuwunel_backup.py) imports measure()/GIB for its free-space
prechecks. The compose-era example path (.runtime) retired with
archive/synapse-stack/.
"""
import argparse
import json
import os
from pathlib import Path
import stat

GIB = 1024 ** 3


def measure(root):
    """Count allocated bytes without following links or crossing filesystems."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    seen = set()
    def walk(fd, device, depth):
        if depth > 128:
            raise ValueError('storage tree exceeds depth limit')
        total = os.fstat(fd).st_blocks * 512
        with os.scandir(fd) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode) or info.st_dev != device:
                    raise ValueError('symlink or nested filesystem in storage tree')
                if stat.S_ISDIR(info.st_mode):
                    child = os.open(entry.name, flags, dir_fd=fd)
                    try:
                        opened = os.fstat(child)
                        if opened.st_dev != device or opened.st_ino != info.st_ino:
                            raise ValueError('storage directory changed during scan')
                        total += walk(child, device, depth+1)
                    finally:
                        os.close(child)
                elif stat.S_ISREG(info.st_mode):
                    key = (info.st_dev, info.st_ino)
                    if key not in seen:
                        seen.add(key)
                        total += info.st_blocks * 512
                else:
                    raise ValueError('special file in storage tree')
        return total
    root = Path(root)
    if '..' in root.parts:
        raise ValueError('parent traversal in storage path')
    root = root.absolute()
    fd = os.open('/', flags)
    try:
        for part in root.parts[1:]:
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        retained = walk(fd, os.fstat(fd).st_dev, 0)
        disk = os.fstatvfs(fd)
        return retained, disk.f_bavail*disk.f_frsize, disk.f_blocks*disk.f_frsize
    finally:
        os.close(fd)


def tree_bytes(root):
    return measure(root)[0]


def evaluate(free, total, retained, min_free, max_retained):
    alerts = []
    if free < min_free:
        alerts.append('filesystem_free_below_reserve')
    if retained >= max_retained:
        alerts.append('retention_budget_reached')
    return {'status': 'warning' if alerts else 'ok', 'alerts': alerts,
            'free_gib': round(free/GIB, 2), 'total_gib': round(total/GIB, 2),
            'retained_gib': round(retained/GIB, 2)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory', type=Path)
    p.add_argument('--min-free-gib', type=int, required=True)
    p.add_argument('--max-retained-gib', type=int, required=True)
    a = p.parse_args()
    if min(a.min_free_gib, a.max_retained_gib) <= 0:
        p.error('thresholds must be positive')
    try:
        # These trees must be owned by the operator, not writable by users.
        retained, free, total = measure(a.directory)
        result = evaluate(free, total, retained,
                          a.min_free_gib*GIB, a.max_retained_gib*GIB)
    except (OSError, ValueError):
        print(json.dumps({'status': 'error', 'alerts': ['storage_measurement_failed']}))
        return 2
    print(json.dumps(result))
    return 0 if result['status'] == 'ok' else 1


if __name__ == '__main__':
    raise SystemExit(main())
