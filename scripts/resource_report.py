#!/usr/bin/env python3
"""Read-only dependency census and process resource sampling.

Records the facts required by docs/OWN-SYSTEM.md step 1: direct and indirect
package lists, server process counts and measured resource use. The script
never sends network traffic, never reads message content, and never writes
outside its output stream. Census inputs are repository manifest files; watch
sampling reads /proc for the descendant tree of one locally started command;
docker sampling calls read-only docker stats for one compose project.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import time

CENSUS_SCHEMA = "family.resource.census.v1"
WATCH_SCHEMA = "family.resource.watch.v1"
DOCKER_SCHEMA = "family.resource.docker.v1"


def census_go(root):
    """Direct requires from go.mod; distinct summed modules from go.sum."""
    gomod = root / 'server' / 'go.mod'
    gosum = root / 'server' / 'go.sum'
    direct = []
    block = False
    for raw in gomod.read_text().splitlines():
        line = raw.strip()
        if line.startswith('require ('):
            block = True
            continue
        if block and line == ')':
            block = False
            continue
        if block or line.startswith('require '):
            line = line.removeprefix('require ').strip()
            if not line or line.startswith('//'):
                continue
            parts = line.split()
            if len(parts) >= 2:
                direct.append({'module': parts[0], 'version': parts[1]})
    summed = set()
    for raw in gosum.read_text().splitlines():
        parts = raw.split()
        if len(parts) >= 2:
            summed.add(parts[0])
    return {'direct': direct, 'distinct_summed_modules': len(summed)}


WASM_RECORD = Path('archive') / 'experiments' / 'openmls-browser' / 'dependencies.json'
WASM_NOTE = ('archived: the browser MLS experiment was frozen by decision D (2026-09-13) '
             'and is excluded from the build; its pinned record is read from archive/ '
             'when present and skipped otherwise')


def census_wasm(root):
    """Reuse the pinned per-package record of the archived experiment; never re-derive it."""
    path = root / WASM_RECORD
    if not path.is_file():
        return {'status': 'skipped', 'note': WASM_NOTE, 'record': str(WASM_RECORD)}
    record = json.loads(path.read_text())
    return {'status': 'archived', 'note': WASM_NOTE, 'record': str(WASM_RECORD),
            'schema': record.get('schema'),
            'external_direct': record.get('external_direct'),
            'external_transitive': record.get('external_transitive'),
            'full_lock_external_packages': record.get('full_lock_external_packages'),
            'scope': record.get('scope')}


def census_python(root):
    pins = []
    for name in ('requirements-matrix.txt', 'requirements-native-test.txt'):
        for raw in (root / name).read_text().splitlines():
            line = raw.strip()
            if line and not line.startswith('#'):
                pins.append({'file': name, 'pin': line})
    return pins


def census_images(root):
    images = []
    for raw in (root / 'compose.yaml').read_text().splitlines():
        match = re.match(r'\s*image:\s*(\S+)\s*$', raw)
        if match:
            images.append(match.group(1))
    return images


def census(root):
    # Live inputs are fixed manifests relative to the repository root; a missing
    # one raises rather than silently producing a partial census. The archived
    # WASM record is the exception: it reports 'skipped' with a note when absent.
    root = Path(root)
    return {'schema': CENSUS_SCHEMA,
            'go': census_go(root),
            'wasm': census_wasm(root),
            'python': census_python(root),
            'images': census_images(root)}


def _read_proc(pid):
    """Best-effort /proc read; races with process exit return None."""
    try:
        comm = Path(f'/proc/{pid}/comm').read_text().strip()
        status = Path(f'/proc/{pid}/status').read_text()
        statm = Path(f'/proc/{pid}/stat').read_text()
    except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
        return None
    hwm = None
    for line in status.splitlines():
        if line.startswith('VmHWM:'):
            hwm = int(line.split()[1]) * 1024
            break
    # Fields after the closing ')': state is [0], ppid is [1].
    tail = statm[statm.rindex(')') + 2:].split()
    return {'comm': comm, 'ppid': int(tail[1]), 'hwm_bytes': hwm}


def _descendants(child):
    table = {}
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit():
            continue
        info = _read_proc(int(entry.name))
        if info is not None:
            table[int(entry.name)] = info
    seen = set()
    frontier = [child]
    while frontier:
        pid = frontier.pop()
        for pid2, info in table.items():
            if info['ppid'] == pid and pid2 not in seen:
                seen.add(pid2)
                frontier.append(pid2)
    return [(pid, table[pid]) for pid in seen]


def watch(command, poll_seconds=0.05, grace_seconds=0.3):
    """Run command; sample its descendant processes until it exits.

    Metrics cover the command's subprocess tree only, so unrelated same-name
    processes on a shared host are never attributed. RSS is the kernel's
    VmHWM peak, which stays valid once a process has been seen even if it
    exits before later samples. Very short-lived processes can still be
    missed entirely, so the process counts are observed lower bounds; the
    authoritative process inventory lives in the component documentation.
    The child's stdout is forwarded to stderr so this function's stdout
    stays a single parseable JSON record.
    """
    if not command:
        raise ValueError('watch requires a command')
    started = time.monotonic()
    # rusage of reaped descendants has microsecond granularity; /proc CPU
    # fields only advance in 10 ms scheduler ticks and read as zero for the
    # short loopback workloads this tool measures.
    rusage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    child = subprocess.Popen(command, stdout=sys.stderr)
    peak_rss = 0
    max_count = 0
    distinct_pids = set()
    comms = set()
    deadline_grace = None
    while True:
        # One snapshot drives every metric, so the report cannot mix
        # samples taken at different moments.
        snapshot = _descendants(child.pid)
        for pid, info in snapshot:
            distinct_pids.add(pid)
            comms.add(info['comm'])
            if info['hwm_bytes'] is not None:
                peak_rss = max(peak_rss, info['hwm_bytes'])
        max_count = max(max_count, len(snapshot))
        code = child.poll()
        if code is not None:
            if deadline_grace is None:
                deadline_grace = time.monotonic() + grace_seconds
            elif time.monotonic() >= deadline_grace:
                break
        else:
            deadline_grace = None
        time.sleep(poll_seconds)
    child.wait()
    rusage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {'schema': WATCH_SCHEMA,
            'command': command,
            'exit_code': child.returncode,
            'wall_seconds': round(time.monotonic() - started, 3),
            'children_cpu_seconds': round(
                (rusage_after.ru_utime - rusage_before.ru_utime)
                + (rusage_after.ru_stime - rusage_before.ru_stime), 6),
            'max_descendant_process_count': max_count,
            'distinct_descendant_pids': len(distinct_pids),
            'descendant_comm_names': sorted(comms),
            'peak_descendant_rss_bytes': peak_rss}


_MEM = re.compile(r'^([0-9.]+)(KiB|MiB|GiB|B)$')


def parse_memory(text):
    match = _MEM.match(text.strip())
    if not match:
        raise ValueError(f'unreadable memory figure: {text!r}')
    factor = {'B': 1, 'KiB': 1024, 'MiB': 1024 ** 2, 'GiB': 1024 ** 3}[match.group(2)]
    return int(float(match.group(1)) * factor)


def parse_docker_stats_line(line):
    """Parse one `docker stats --format '{{json .}}'` line into safe numbers."""
    fields = json.loads(line)
    used, _, limit = fields['MemUsage'].partition(' / ')
    return {'name': fields['Name'],
            'memory_used_bytes': parse_memory(used),
            'memory_limit_bytes': parse_memory(limit),
            'cpu_percent': float(fields['CPUPerc'].removesuffix('%'))}


def docker_stats(project=None, timeout=30):
    """Read-only snapshot of running container usage; requires docker CLI."""
    command = ['docker', 'stats', '--no-stream', '--format', '{{json .}}']
    if project:
        command = ['docker', 'compose', '-p', project, 'stats', '--no-stream',
                   '--format', '{{json .}}']
    raw = subprocess.run(command, capture_output=True, text=True,
                         timeout=timeout, check=True).stdout
    containers = [parse_docker_stats_line(line) for line in raw.splitlines() if line.strip()]
    return {'schema': DOCKER_SCHEMA, 'containers': containers,
            'container_count': len(containers)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    c = sub.add_parser('census', help='manifest dependency census')
    c.add_argument('--root', default='.', type=Path)
    w = sub.add_parser('watch', help='measure one command\'s process tree')
    w.add_argument('--poll-seconds', type=float, default=0.05)
    w.add_argument('--grace-seconds', type=float, default=0.3)
    w.add_argument('command', nargs='+')
    d = sub.add_parser('docker', help='read-only running container usage')
    d.add_argument('--project', default=None)
    args = parser.parse_args()
    if args.mode == 'census':
        report = census(args.root)
    elif args.mode == 'watch':
        report = watch(args.command, poll_seconds=args.poll_seconds,
                       grace_seconds=args.grace_seconds)
    else:
        report = docker_stats(args.project)
    json.dump(report, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
