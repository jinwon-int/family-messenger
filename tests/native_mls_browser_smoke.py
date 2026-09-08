#!/usr/bin/env python3
"""Only disposable local static assets and generated synthetic MLS bytes."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[1]
    evidence = Path(tempfile.mkdtemp(prefix='native-mls-browser-', dir=repo / 'artifacts'))
    paths = {'/': repo / 'experiments/openmls-browser/web/index.html'}
    for name in ['main.js', 'worker.js', 'durable-worker.js']:
        paths['/' + name] = repo / 'experiments/openmls-browser/web' / name
    for name in ['family_mls_browser_experiment.js', 'family_mls_browser_experiment_bg.wasm']:
        paths['/pkg/' + name] = args.bundle / name
    assets = {}
    for route, path in paths.items():
        st = path.lstat()
        if not path.is_file() or path.is_symlink() or st.st_nlink != 1 or st.st_size > 32 * 1024 * 1024:
            raise RuntimeError('unsafe or oversized asset')
        assets[route] = path.read_bytes()
    receipt = {'synthetic_only': True, 'durable_state': False, 'checks': {}, 'memory_bytes': 0,
               'memory_scope': 'maximum per worker WASM linear memory, not aggregate context/browser memory; multiple workers remain live',
               'assets': {route: {'bytes': len(raw), 'gzip_bytes': len(gzip.compress(raw, mtime=0)),
                                   'sha256': hashlib.sha256(raw).hexdigest()} for route, raw in assets.items()}}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            origin = 'http://' + expected_host
            if self.headers.get('Host') != expected_host or self.headers.get('Origin') not in (None, origin):
                self.send_error(403)
                return
            if self.path not in assets:
                self.send_error(404)
                return
            body = assets[self.path]
            self.send_response(200)
            self.send_header('Content-Type', 'application/wasm' if self.path.endswith('.wasm') else
                             'text/javascript' if self.path.endswith('.js') else 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    expected_host = f'127.0.0.1:{server.server_port}'
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            receipt['browser'] = browser.version
            contexts = [browser.new_context() for _ in range(2)]
            pages = [context.new_page() for context in contexts]
            for page in pages:
                page.goto('http://' + expected_host)
                page.wait_for_function('window.ready === true')
                page.evaluate("spawn('main')")
            alice, bob = pages

            def call(page, method, argument=None, name='main', reject=False):
                value = page.evaluate('([name, method, argument]) => call(name, method, argument)', [name, method, argument])
                receipt['memory_bytes'] = max(receipt['memory_bytes'], value['memory_bytes'])
                assert value['memory_bytes'] <= 128 * 1024 * 1024
                if reject:
                    assert value['ok'] is False and 'result' not in value, (method, value)
                    return
                assert value['ok'] is True, (method, value)
                return value.get('result')

            def pair(name, join=True):
                if name != 'main':
                    alice.evaluate('name => spawn(name)', name)
                    bob.evaluate('name => spawn(name)', name)
                times = [call(alice, 'init', 'alice', name=name)['init_ms'],
                         call(bob, 'init', 'bob', name=name)['init_ms']]
                package = call(bob, 'key_package', name=name)
                call(alice, 'create', name=name)
                welcome = call(alice, 'invite', package, name=name)
                if join:
                    call(bob, 'join', welcome, name=name)
                return package, welcome, times

            package, welcome, receipt['init_ms'] = pair('main')
            text = list('synthetic hello 한글'.encode())
            encrypted = call(alice, 'encrypt', text)
            assert bytes(text) not in bytes(encrypted)
            assert call(bob, 'decrypt', encrypted) == text
            raw = list(bytes(range(256)) * 4)
            encrypted_file = call(bob, 'encrypt', raw)
            assert bytes(raw) not in bytes(encrypted_file)
            assert call(alice, 'decrypt', encrypted_file) == raw
            receipt['checks']['text_and_opaque_1024_bytes'] = True
            call(bob, 'decrypt', encrypted, reject=True)
            call(bob, 'encrypt', text, reject=True)
            receipt['checks']['replay_rejected_and_device_retired'] = True

            bob.evaluate("spawn('outsider')")
            call(bob, 'init', 'outsider', name='outsider')
            call(bob, 'join', welcome, name='outsider', reject=True)
            call(bob, 'create', name='outsider', reject=True)
            receipt['checks']['nonmember_welcome_rejected_and_retired'] = True
            _, repeated_welcome, _ = pair('welcome')
            call(bob, 'join', repeated_welcome, name='welcome', reject=True)
            receipt['checks']['existing_group_welcome_rejected'] = True

            _, original_welcome, _ = pair('damaged-welcome', join=False)
            damaged_welcome = original_welcome.copy()
            damaged_welcome[-1] ^= 1
            call(bob, 'join', damaged_welcome, name='damaged-welcome', reject=True)
            call(bob, 'join', original_welcome, name='damaged-welcome', reject=True)
            call(bob, 'key_package', name='damaged-welcome', reject=True)
            receipt['checks']['damaged_welcome_retires_original_retry'] = True

            tamper_package, tamper_welcome, _ = pair('tamper')
            original = call(alice, 'encrypt', list(b'synthetic tamper'), name='tamper')
            altered = original.copy()
            altered[-1] ^= 1
            call(bob, 'decrypt', altered, name='tamper', reject=True)
            # Regression: OpenMLS can consume the generation before authentication.
            # This memory-only wrapper must retire rather than silently reuse it.
            call(bob, 'decrypt', original, name='tamper', reject=True)
            for method, argument in [('encrypt', text), ('create', None), ('key_package', None),
                                     ('invite', tamper_package), ('join', tamper_welcome),
                                     ('remove', None), ('commit', [])]:
                call(bob, method, argument, name='tamper', reject=True)
            receipt['checks']['tamper_retires_original_retry_and_all_operations'] = True

            pair('wrong')
            pair('different')
            other = call(bob, 'encrypt', list(b'different group'), name='different')
            valid = call(alice, 'encrypt', text, name='wrong')
            call(bob, 'decrypt', valid, name='different', reject=True)
            call(alice, 'decrypt', other, name='wrong', reject=True)
            receipt['checks']['wrong_group_both_directions'] = True
            for name, method, value in [('largeplain', 'encrypt', [0] * 16385),
                                        ('largewire', 'decrypt', [0] * 65537),
                                        ('malformed', 'decrypt', [1, 2, 3])]:
                pair(name)
                call(bob, method, value, name=name, reject=True)
            receipt['checks']['input_limits_and_malformed'] = True

            # Separate pairs: failed receive deliberately retires a device, so it
            # must not then process a removal commit using uncertain state.
            pair('withheld')
            call(alice, 'remove', name='withheld')
            new_epoch = call(alice, 'encrypt', text, name='withheld')
            call(bob, 'decrypt', new_epoch, name='withheld', reject=True)
            pair('removed')
            commit = call(alice, 'remove', name='removed')
            call(bob, 'commit', commit, name='removed')
            call(bob, 'encrypt', text, name='removed', reject=True)
            pair('removed-read')
            removed_commit = call(alice, 'remove', name='removed-read')
            call(bob, 'commit', removed_commit, name='removed-read')
            new_epoch = call(alice, 'encrypt', text, name='removed-read')
            call(bob, 'decrypt', new_epoch, name='removed-read', reject=True)
            receipt['checks']['removed_device_before_commit_after_commit_read_and_send'] = True
            receipt['wire_bytes'] = {'key_package': len(package), 'welcome': len(welcome), 'text': len(encrypted),
                                     'file': len(encrypted_file), 'remove_commit': len(commit)}
            for context in contexts:
                context.close()
            browser.close()
        receipt['passed'] = True
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        (evidence / 'verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(evidence / 'verification.json', flush=True)


if __name__ == '__main__':
    main()
