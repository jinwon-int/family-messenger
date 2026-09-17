// Bundles the app into dist/ with esbuild (matrix-js-sdk + rust crypto
// WASM) and copies the static shell. Run via `npm run build`.

import { build } from 'esbuild';
import { copyFile, cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { hashedName, rewriteIndex, rewriteServiceWorker, shortHash } from './build-lib.mjs';
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

const result = await build({
  entryPoints: [join(here, 'src/main.js')],
  bundle: true,
  format: 'esm',
  // esnext 기본값은 가족 기기의 구형 모바일 브라우저에서 파싱 실패로 빈 화면을 만든다
  // (2026-09-16 첫 공개에서 관측). 명시 하한으로 내린다.
  target: ['es2020'],
  outdir: dist,
  // 내용 해시 파일명: 배포마다 URL이 바뀌어 어떤 캐시(옛 서비스 워커 포함)에도 갇히지 않는다.
  entryNames: '[name]-[hash]',
  metafile: true,
  minify: true,
  sourcemap: false,
  loader: { '.wasm': 'file' },
  logLevel: 'info',
});
const bundleName = basename(Object.keys(result.metafile.outputs).find((out) => out.endsWith('.js')));

// 정적 자산도 내용 해시로 이름을 붙여 복사한다.
const stylesBytes = await readFile(join(here, 'styles.css'));
const stylesName = hashedName('styles.css', stylesBytes);
await writeFile(join(dist, stylesName), stylesBytes);
const bootBytes = await readFile(join(here, 'boot.js'));
const bootName = hashedName('boot.js', bootBytes);
await writeFile(join(dist, bootName), bootBytes);
await cp(join(here, 'manifest.webmanifest'), join(dist, 'manifest.webmanifest'));
await cp(join(here, 'icons'), join(dist, 'icons'), { recursive: true });

// index.html의 참조를 해시 파일명으로, sw.js의 캐시 이름·프리캐시 목록을 이번 빌드 값으로.
const indexHtml = rewriteIndex(await readFile(join(here, 'index.html'), 'utf8'), {
  './styles.css': `./${stylesName}`,
  './boot.js': `./${bootName}`,
  './main.js': `./${bundleName}`,
});
await writeFile(join(dist, 'index.html'), indexHtml);
const buildId = shortHash(Buffer.concat([stylesBytes, bootBytes, await readFile(join(dist, bundleName)), Buffer.from(indexHtml)]));
const shell = ['./', './index.html', `./${bundleName}`, `./${stylesName}`, `./${bootName}`, './manifest.webmanifest', './icons/icon.svg'];
await writeFile(join(dist, 'sw.js'), rewriteServiceWorker(await readFile(join(here, 'sw.js'), 'utf8'), { cacheName: `familychat-${buildId}`, shell }));

// 배포 시 설정(web/app/config.json, git-ignored)을 dist에 싣는다. 없으면 빈 설정 —
// 공개 저장소에는 실제 호스트명을 두지 않는다(config.example.json 참고).
const configSource = join(here, 'config.json');
await writeFile(join(dist, 'config.json'), existsSync(configSource) ? await readFile(configSource) : '{}\n');

// Fail the build if the bundle does not reference the copied wasm.
const bundle = await readFile(join(dist, bundleName), 'utf8');
if (!bundle.includes('matrix_sdk_crypto_wasm_bg.wasm')) {
  console.error('bundle does not reference the rust crypto wasm asset');
  process.exit(1);
}

console.log(`dist/ ready (${bundleName}, ${stylesName}, ${bootName}, cache familychat-${buildId})`);
