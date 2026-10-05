"""Render the built login page in Chromium; no account or external service."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

from playwright.sync_api import expect, sync_playwright


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('../../.runtime/web-browser-smoke'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    app = Path(__file__).resolve().parents[1]
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    with (args.output / 'server.log').open('w') as log:
        server = subprocess.Popen(['node', 'serve.mjs'], cwd=app,
                                  env={**os.environ, 'PORT': str(port)}, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError('app server exited before readiness')
                try:
                    with urllib.request.urlopen(base, timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError('app server did not become ready')
            errors = []
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch()
                page = browser.new_page(viewport={'width': 390, 'height': 844}, service_workers='block')
                page.on('pageerror', lambda error: errors.append(str(error)))
                page.route('**/*', lambda route: route.continue_() if route.request.url.startswith(base + '/') else route.abort())
                response = page.goto(base, wait_until='networkidle')
                assert response.status == 200
                expect(page.get_by_role('heading', name='패밀리챗', exact=True)).to_be_visible()
                expect(page.get_by_role('button', name='로그인', exact=True)).to_be_visible()
                remember = page.get_by_role('checkbox', name='이 기기에서 로그인 유지')
                expect(remember).not_to_be_checked()
                remember.check()
                expect(remember).to_be_checked()
                remember.uncheck()
                page.screenshot(path=str(args.output / 'login.png'), full_page=True)
                assert not errors, errors
                evidence = {'login_visible': True, 'remember_opt_in': True, 'page_errors': errors,
                            'browser': browser.version, 'synthetic_only': True, 'real_device_evidence': False}
                (args.output / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n')
                browser.close()
                print(json.dumps(evidence))
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


if __name__ == '__main__':
    main()
