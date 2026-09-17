// Pure helpers for build.mjs (content hashing + shell rewrites). Kept
// dependency-free so tests/build_lib.test.js can run without esbuild.

import { createHash } from 'node:crypto';

/** First 8 hex chars of sha256 — enough to make a filename change on every edit. */
export function shortHash(bytes) {
  return createHash('sha256').update(bytes).digest('hex').slice(0, 8);
}

/** `styles.css` + bytes → `styles-1a2b3c4d.css`. */
export function hashedName(fileName, bytes) {
  const dot = fileName.lastIndexOf('.');
  const stem = dot > 0 ? fileName.slice(0, dot) : fileName;
  const ext = dot > 0 ? fileName.slice(dot) : '';
  return `${stem}-${shortHash(bytes)}${ext}`;
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Replace quoted asset references in index.html. Any `?v=` query on the
 * source reference is dropped — the hash in the name is the version now.
 * @param {string} html
 * @param {Record<string, string>} map e.g. {'./main.js': './main-ABC123.js'}
 */
export function rewriteIndex(html, map) {
  let out = html;
  for (const [from, to] of Object.entries(map)) {
    const pattern = new RegExp(`(["'])${escapeRegExp(from)}(\\?[^"']*)?\\1`, 'g');
    out = out.replace(pattern, `$1${to}$1`);
  }
  return out;
}

/** Fill the service worker template: cache name + precache list. */
export function rewriteServiceWorker(source, { cacheName, shell }) {
  if (!source.includes('__CACHE_NAME__') || !source.includes('__SHELL_ASSETS__')) {
    throw new Error('sw.js template placeholders missing (__CACHE_NAME__ / __SHELL_ASSETS__)');
  }
  // replaceAll: the template mentions the tokens in its header comment too.
  return source.replaceAll('__CACHE_NAME__', cacheName).replaceAll('__SHELL_ASSETS__', JSON.stringify(shell));
}

/** True for content-addressed files (`name-<8 hex/alnum>.ext`) that may be cached forever. */
export function isHashedAsset(pathname) {
  return /-[A-Za-z0-9]{8}\.(?:js|css)$/.test(pathname);
}
