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
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--vault', action='store_true');mode.add_argument('--history', action='store_true');mode.add_argument('--aggregate', action='store_true')
    mode.add_argument('--aggregate-history', action='store_true');mode.add_argument('--successor', action='store_true');mode.add_argument('--candidate', action='store_true');mode.add_argument('--peer', action='store_true');mode.add_argument('--custody', action='store_true')
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
    if args.vault:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-vault-ui') for f in flags],e) for n,b,flags,e in cases]
        cases.append(('mutually_exclusive_modes', binary, ['--synthetic-only','--synthetic-mls-ui','--synthetic-vault-ui'], 'select only one encrypted UI mode'))
        cases.append(('old_bundle_absent_in_vault_binary', binary, ['--synthetic-only','--synthetic-mls-ui','--auth-state',str(directory/'missing')], 'encrypted assets absent'))
    if args.history:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-history-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-history-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    if args.aggregate:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-aggregate-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault','history'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-aggregate-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    if args.aggregate_history:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-aggregate-history-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault','history','aggregate'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-aggregate-history-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    if args.successor:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-successor-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault','history','aggregate','aggregate-history'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-successor-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    if args.candidate:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-candidate-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault','history','aggregate','aggregate-history','successor'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-candidate-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    if args.peer:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-peer-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault','history','aggregate','aggregate-history','successor','candidate'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-peer-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    if args.custody:
        cases = [(n,b,[f.replace('--synthetic-mls-ui','--synthetic-custody-ui') for f in flags],e) for n,b,flags,e in cases]
        for other in ('mls','vault','history','aggregate','aggregate-history','successor','candidate','peer'):
            cases.append(('mutually_exclusive_'+other,binary,['--synthetic-only','--synthetic-custody-ui','--synthetic-'+other+'-ui'],'select only one encrypted UI mode'))
            cases.append(('old_'+other+'_bundle_absent',binary,['--synthetic-only','--synthetic-'+other+'-ui','--auth-state',str(directory/'missing')],'encrypted assets absent'))
    for name, executable, flags, error in cases:
        state = directory / name
        state.mkdir(mode=0o700)
        result = subprocess.run([str(executable), '--state', str(state), *flags], capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and not list(state.iterdir()), name
        assert 'listening' not in result.stderr, name
        if error:
            assert error in result.stderr, name
        checks[name] = True
    proof = {'synthetic_only': True, 'vault_mode': args.vault, 'history_mode': args.history, 'aggregate_mode':args.aggregate, 'aggregate_history_mode':args.aggregate_history,'successor_mode':args.successor,'candidate_mode':args.candidate,'peer_mode':args.peer,'custody_mode':args.custody, 'checks': checks, 'binaries': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (binary, plain)}}
    path = directory / 'verification.json'
    path.write_text(json.dumps(proof, indent=2) + '\n')
    path.chmod(0o600)
    print(path)

if __name__ == '__main__':
    main()
