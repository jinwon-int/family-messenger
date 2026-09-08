#!/usr/bin/env python3
"""Read-only disk/retention-budget check. Never purges messages or media."""
import argparse
import json
import os
from pathlib import Path
import shutil
import stat

GIB = 1024 ** 3


def tree_bytes(root):
    """Count allocated bytes without following links or crossing filesystems."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    def walk(fd, device, depth):
        if depth > 128:
            raise ValueError('storage tree exceeds depth limit')
        total = 0
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
                    total += info.st_blocks * 512
                else:
                    raise ValueError('special file in storage tree')
        return total
    fd = os.open(root, flags)
    try:
        return walk(fd, os.fstat(fd).st_dev, 0)
    finally:
        os.close(fd)


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
        retained = tree_bytes(a.directory)
        disk = shutil.disk_usage(a.directory)
        result = evaluate(disk.free, disk.total, retained,
                          a.min_free_gib*GIB, a.max_retained_gib*GIB)
    except (OSError, ValueError):
        print(json.dumps({'status': 'error', 'alerts': ['storage_measurement_failed']}))
        return 2
    print(json.dumps(result))
    return 0 if result['status'] == 'ok' else 1


if __name__ == '__main__':
    raise SystemExit(main())
