import test from 'node:test';
import assert from 'node:assert/strict';
// DOMPurify security fixtures need a standards-compatible parser. happy-dom
// loops on the SVG removal fixture below; use jsdom for sanitizer coverage.
import { JSDOM } from 'jsdom';
const { window } = new JSDOM('', { url: 'https://chat.example.test/' });
globalThis.window = window;
globalThis.document = window.document;
const { richMessageFragment } = await import('../../src/rich-text.js');

test('Matrix formatting renders Korean paragraphs, lists, links, code and tables', () => {
  const fragment = richMessageFragment('<h2>결과</h2><p><strong>정상</strong> · <em>확인</em></p><ul><li>여유 공간 21GB</li></ul><pre><code>df -h\n&lt;tag&gt;</code></pre><a href="https://example.com">상세</a><table><tr><th>상태</th><td>정상</td></tr></table>');
  assert.equal(fragment.querySelector('strong').textContent, '정상');
  assert.equal(fragment.querySelector('li').textContent, '여유 공간 21GB');
  assert.equal(fragment.querySelector('pre code').textContent, 'df -h\n<tag>');
  assert.equal(fragment.querySelector('td').textContent, '정상');
  assert.equal(fragment.querySelector('a').getAttribute('target'), '_blank');
  assert.equal(fragment.querySelector('a').getAttribute('rel'), 'noopener noreferrer');
});

test('received HTML cannot introduce scripts, embeds, styles, controls or tracking images', () => {
  const fragment = richMessageFragment('<p id="app" class="shell" style="position:fixed" onclick="alert(1)">안전<strong onmouseover="x()">확인</strong></p><script>alert(1)</script><img src="https://example.com/pixel" onerror="x()"><svg onload="x()"><a href="javascript:x()">x</a></svg><iframe src="https://example.com"></iframe><form><input name="body"></form><style>body{display:none}</style>');
  assert.ok(fragment.textContent.includes('안전확인'));
  assert.equal(fragment.querySelector('script,img,svg,iframe,form,input,style'), null);
  for (const node of fragment.querySelectorAll('*')) assert.equal(node.attributes.length, 0);
});

test('unsafe and relative link schemes are inert; safe links stay usable', () => {
  for (const href of ['javascript:alert(1)', 'jav&#x61;script:alert(1)', 'java&#10;script:alert(1)', 'data:text/html,x', '//example.com', '/logout', 'file:///etc/passwd', 'https://exa&#10;mple.com']) {
    const fragment = richMessageFragment(`<a href="${href}">본문</a>`);
    assert.equal(fragment.querySelector('a').getAttribute('href'), null, href);
  }
  assert.equal(richMessageFragment('<a href="mailto:test@example.com">메일</a>').querySelector('a').getAttribute('href'), 'mailto:test@example.com');
});

test('missing, empty, non-text and oversized rich bodies fall back to the plain body', () => {
  for (const html of [null, undefined, {}, '', '<img src="https://example.com">', '<script>x()</script>', 'x'.repeat(100_001)]) {
    assert.equal(richMessageFragment(html), null);
  }
});
