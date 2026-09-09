#!/usr/bin/env python3
"""Actual executable selection failures must precede opening synthetic chat state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--plain-binary', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    directory = Path(tempfile.mkdtemp(prefix='native-asset-activation-', dir=root / 'artifacts'))
    directory.chmod(0o700)
    checks = {}
    binary = args.binary.resolve()
    plain = args.plain_binary.resolve()
    cases = [
        ('no_synthetic_ack', binary, ['--synthetic-mls-ui'], 'requires --synthetic-only'),
        ('public_bind', binary, ['--synthetic-only', '--synthetic-mls-ui', '--listen', '0.0.0.0:18920'], 'only 127.0.0.1'),
        ('missing_auth_selection', binary, ['--synthetic-only', '--synthetic-mls-ui'], 'requires explicit signed auth-state'),
        ('empty_auth_selection', binary, ['--synthetic-only', '--synthetic-mls-ui', '--auth-state='], 'requires explicit signed auth-state'),
        ('bundle_absent_in_default_binary', plain, ['--synthetic-only', '--synthetic-mls-ui', '--auth-state', str(directory / 'missing')], 'encrypted assets absent'),
        ('invalid_selected_policy', binary, ['--synthetic-only', '--synthetic-mls-ui', '--auth-state', str(directory / 'missing')], None),
    ]
    for name, executable, flags, error in cases:
        state = directory / name
        state.mkdir(mode=0o700)
        result = subprocess.run([str(executable), '--state', str(state), *flags], capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and not list(state.iterdir()), name
        assert 'listening' not in result.stderr, name
        if error:
            assert error in result.stderr, name
        checks[name] = True
    proof = {'synthetic_only': True, 'checks': checks, 'binaries': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (binary, plain)}}
    path = directory / 'verification.json'
    path.write_text(json.dumps(proof, indent=2) + '\n')
    path.chmod(0o600)
    print(path)

if __name__ == '__main__':
    main()
