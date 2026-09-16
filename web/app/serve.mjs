// Minimal static server for dist/ — no dependencies.
// Usage: npm run build && npm run serve  (PORT env overrides 8080)

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

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

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    let pathname = decodeURIComponent(url.pathname);
    if (pathname.endsWith('/')) pathname += 'index.html';
    // Resolve inside dist/ only.
    const resolved = normalize(join(root, pathname));
    if (resolved !== root && !resolved.startsWith(root + sep)) {
      res.writeHead(403).end('forbidden');
      return;
    }
    const info = await stat(resolved).catch(() => null);
    const target = info?.isFile() ? resolved : join(root, 'index.html');
    const body = await readFile(target);
    const ext = extname(target);
    // 코드 자산은 재배포가 즉시 보이도록 캐시 금지; 불변에 가까운 바이너리·아이콘만 짧게 캐시.
    const cacheControl = ext === '.wasm' || ext === '.svg' || ext === '.png' || ext === '.ico'
      ? 'public, max-age=86400'
      : 'no-store';
    res.writeHead(200, { 'content-type': MIME[ext] ?? 'application/octet-stream', 'cache-control': cacheControl });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`serving ${root} at http://127.0.0.1:${port}`);
});
