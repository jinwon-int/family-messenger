// Bundles the app into dist/ with esbuild (matrix-js-sdk + rust crypto
// WASM) and copies the static shell. Run via `npm run build`.

import { build } from 'esbuild';
import { copyFile, cp, mkdir, readdir, readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, 'dist');

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

// The rust-crypto WASM glue resolves its .wasm binary at runtime via
// `new URL("./pkg/matrix_sdk_crypto_wasm_bg.wasm", import.meta.url)` —
// invisible to bundlers — so the build copies it next to main.js at the
// exact relative path the glue expects.
const require = createRequire(import.meta.url);
let wasmPackageDir;
try {
  wasmPackageDir = dirname(require.resolve('@matrix-org/matrix-sdk-crypto-wasm/package.json'));
} catch {
  // package.json not in the exports map: walk up from the main entry.
  wasmPackageDir = dirname(require.resolve('@matrix-org/matrix-sdk-crypto-wasm'));
  while (!existsSync(join(wasmPackageDir, 'package.json'))) {
    const parent = dirname(wasmPackageDir);
    if (parent === wasmPackageDir) {
      console.error('could not locate @matrix-org/matrix-sdk-crypto-wasm package root');
      process.exit(1);
    }
    wasmPackageDir = parent;
  }
}
const wasmFiles = (await readdir(join(wasmPackageDir, 'pkg'), { recursive: false })).filter((f) => f.endsWith('.wasm'));
if (wasmFiles.length !== 1) {
  console.error(`expected exactly one .wasm in @matrix-org/matrix-sdk-crypto-wasm/pkg, found: ${wasmFiles.join(', ')}`);
  process.exit(1);
}
await mkdir(join(dist, 'pkg'), { recursive: true });
await copyFile(join(wasmPackageDir, 'pkg', wasmFiles[0]), join(dist, 'pkg', 'matrix_sdk_crypto_wasm_bg.wasm'));

await build({
  entryPoints: [join(here, 'src/main.js')],
  bundle: true,
  format: 'esm',
  // esnext 기본값은 가족 기기의 구형 모바일 브라우저에서 파싱 실패로 빈 화면을 만든다
  // (2026-09-16 첫 공개에서 관측). 명시 하한으로 내린다.
  target: ['es2020'],
  outfile: join(dist, 'main.js'),
  minify: true,
  sourcemap: false,
  loader: { '.wasm': 'file' },
  logLevel: 'info',
});

for (const file of ['index.html', 'styles.css', 'manifest.webmanifest', 'sw.js']) {
  await cp(join(here, file), join(dist, file));
}
await cp(join(here, 'icons'), join(dist, 'icons'), { recursive: true });

// Fail the build if the bundle does not reference the copied wasm.
const bundle = await readFile(join(dist, 'main.js'), 'utf8');
if (!bundle.includes('matrix_sdk_crypto_wasm_bg.wasm')) {
  console.error('bundle does not reference the rust crypto wasm asset');
  process.exit(1);
}

console.log('dist/ ready');
