// #752 PR 2: index.html 의 <link rel="modulepreload"> 목록 = main.js 의 정적 import 폐포(main.js 제외).
// 빠지면 그 모듈은 import 단계를 따라 늦게 받고, 남으면(지운 모듈) 404 요청이 하나 생긴다. 공유 모듈(commit-policy.js 등)은
// build.sh 가 experiments/openmls-browser/web 에서 복사하므로 거기서 찾는다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const here = new URL('../', import.meta.url);
const shared = new URL('../../../../experiments/openmls-browser/web/', import.meta.url);
const IMPORT = /^\s*(?:import|export)\s+(?:[^'"]*?from\s+)?['"]\.\/([^'"]+)['"]/gm;

function source(name) {
  for (const base of [here, shared]) {
    const url = new URL(name, base);
    if (existsSync(url)) return readFileSync(url, 'utf8');
  }
  throw new Error(`module not found in hande or shared web: ${name}`);
}

function importClosure(entry) {
  const seen = new Set();
  const stack = [entry];
  while (stack.length) {
    const name = stack.pop();
    if (seen.has(name)) continue;
    seen.add(name);
    for (const m of source(name).matchAll(IMPORT)) stack.push(m[1]);
  }
  return seen;
}

const html = readFileSync(new URL('index.html', here), 'utf8');
const preloads = [...html.matchAll(/<link rel="modulepreload" href="\.\/([^"]+)"/g)].map((m) => m[1]);

test('modulepreload 목록 = main.js import 폐포(main.js 제외) — 빠짐·남음 없음', () => {
  const closure = importClosure('main.js');
  closure.delete('main.js');
  assert.deepEqual([...preloads].sort(), [...closure].sort());
});

test('modulepreload 는 중복 없이, main.js 스크립트보다 앞(head)에 있다', () => {
  assert.equal(new Set(preloads).size, preloads.length);
  assert.ok(preloads.length > 0);
  assert.ok(html.lastIndexOf('rel="modulepreload"') < html.indexOf('</head>'));
  assert.ok(html.indexOf('</head>') < html.indexOf('src="./main.js"'));
});

test('미리 받는 모듈은 모두 배포(build.sh)와 서비스 워커 셸(SHELL_ASSETS)에 있다', async () => {
  const { SHELL_ASSETS } = await import('../sw-policy.js');
  const build = readFileSync(new URL('build.sh', here), 'utf8');
  for (const name of preloads) {
    assert.ok(SHELL_ASSETS.includes(`./${name}`), `SHELL_ASSETS: ${name}`);
    assert.match(build, new RegExp(`\\s${name.replace('.', '\\.')}[\\s;]`), `build.sh: ${name}`);
  }
});
