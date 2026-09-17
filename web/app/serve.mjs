// Minimal static server for dist/ — no dependencies.
// Usage: npm run build && npm run serve  (PORT env overrides 8080)

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isHashedAsset } from './build-lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, 'dist');
const port = Number(process.env.PORT ?? 8080);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

// E2EE 클라이언트의 보안 헤더. 인라인 스크립트·스타일 없음(boot.js 분리, 클래스만 사용),
// WASM은 'wasm-unsafe-eval'만 허용. 홈서버는 사용자가 입력하므로 https:/wss: 전체를 허용하고,
// 파일보관함 임베드(config.json)는 https 프레임만. 이 앱을 남이 프레임에 넣는 것은 금지.
export const SECURITY_HEADERS = Object.freeze({
  'content-security-policy': [
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval'",
    "style-src 'self'",
    "img-src 'self' blob: data:",
    "media-src 'self' blob:",
    "font-src 'self'",
    "connect-src 'self' https: wss:",
    'frame-src https:',
    "worker-src 'self'",
    "manifest-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join('; '),
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=()',
  'strict-transport-security': 'max-age=31536000; includeSubDomains',
  'x-frame-options': 'DENY',
});

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    let pathname = decodeURIComponent(url.pathname);
    if (pathname.endsWith('/')) pathname += 'index.html';
    // Resolve inside dist/ only.
    const resolved = normalize(join(root, pathname));
    if (resolved !== root && !resolved.startsWith(root + sep)) {
      res.writeHead(403, SECURITY_HEADERS).end('forbidden');
      return;
    }
    const info = await stat(resolved).catch(() => null);
    const target = info?.isFile() ? resolved : join(root, 'index.html');
    const body = await readFile(target);
    const ext = extname(target);
    // 해시 파일명 자산은 내용이 곧 이름이라 영구 캐시; 문서·SW·설정은 캐시 금지; 바이너리·아이콘은 하루.
    const cacheControl = isHashedAsset(target)
      ? 'public, max-age=31536000, immutable'
      : ext === '.wasm' || ext === '.svg' || ext === '.png' || ext === '.ico'
        ? 'public, max-age=86400'
        : 'no-store';
    res.writeHead(200, { ...SECURITY_HEADERS, 'content-type': MIME[ext] ?? 'application/octet-stream', 'cache-control': cacheControl });
    res.end(body);
  } catch {
    res.writeHead(404, SECURITY_HEADERS).end('not found');
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`serving ${root} at http://127.0.0.1:${port}`);
});
