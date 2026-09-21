// 알림 시트 DOM 시험 (#167 C).
//
// 이 시트의 값어치는 "iOS에서 왜 안 되는지" 안내에 있다. 순수 로직 시험은
// pushAvailability 문자열까지만 보므로, 그 문자열이 실제로 화면에 나오는지는
// 여기서만 확인된다. #126이 지적한 "ui.js DOM 시험 0건"을 반복하지 않는다.

import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';

const window = new Window({ url: 'https://chat.example.test/' });
for (const key of ['window', 'document', 'HTMLElement', 'Node', 'Event', 'CSS', 'FormData', 'Intl']) {
  if (!(key in globalThis) || key === 'window' || key === 'document') globalThis[key] = window[key] ?? globalThis[key];
}
globalThis.window = window;
globalThis.document = window.document;
if (!globalThis.CSS) globalThis.CSS = window.CSS;

const ui = await import('../../src/ui.js');
const { strings } = await import('../../src/strings.js');

const root = () => {
  document.body.innerHTML = '<div id="app"></div>';
  return document.getElementById('app');
};

/** 시트를 열고 첫 load()가 반영될 때까지 기다린다. */
async function openSheet(availability, handlers = {}) {
  const node = root();
  let current = availability;
  ui.openNotificationsSheet(node, {
    load: async () => current,
    enable: handlers.enable ?? (async () => ({ ok: true })),
    disable: handlers.disable ?? (async () => ({ ok: true })),
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  return {
    node,
    dialog: node.querySelector('dialog'),
    set: (value) => { current = value; },
    text: () => node.querySelector('dialog').textContent,
    button: (label) => [...node.querySelectorAll('button')].find((b) => b.textContent === label) ?? null,
  };
}

test('알림 시트: 꺼짐 상태는 켜기 버튼을 보여준다', async () => {
  const sheet = await openSheet('off');
  assert.ok(sheet.text().includes(strings.notifications.off));
  assert.ok(sheet.button(strings.notifications.enable), '켜기 버튼이 있어야 한다');
  assert.equal(sheet.button(strings.notifications.disable), null);
});

test('알림 시트: 켜짐 상태는 끄기 버튼을 보여준다', async () => {
  const sheet = await openSheet('on');
  assert.ok(sheet.text().includes(strings.notifications.on));
  assert.ok(sheet.button(strings.notifications.disable));
  assert.equal(sheet.button(strings.notifications.enable), null);
});

test('알림 시트: iOS 탭에서는 홈화면 추가 안내와 순서 경고를 보여준다', async () => {
  // 순서를 틀리면(Safari에서 로그인 후 홈화면 추가) 세션·키가 승계되지 않는다.
  // 그 경고가 화면에 실제로 나와야 의미가 있다.
  const sheet = await openSheet('ios-needs-install');
  const text = sheet.text();
  assert.ok(text.includes(strings.notifications.iosSteps), '설치 절차');
  assert.ok(text.includes(strings.notifications.iosOrder), '순서 경고');
  assert.ok(text.includes(strings.notifications.iosTitle), '제목이 iOS용으로 바뀐다');
  // 켤 수 없는 상태이므로 토글 버튼을 주면 안 된다 — 눌러도 아무 일이 없다.
  assert.equal(sheet.button(strings.notifications.enable), null);
  assert.equal(sheet.button(strings.notifications.disable), null);
});

test('알림 시트: 차단·미지원·미설정은 각각 다른 이유를 보여준다', async () => {
  for (const [availability, expected] of [
    ['denied', strings.notifications.denied],
    ['unsupported', strings.notifications.unsupported],
    ['not-configured', strings.notifications.notConfigured],
  ]) {
    const sheet = await openSheet(availability);
    assert.ok(sheet.text().includes(expected), availability);
    assert.equal(sheet.button(strings.notifications.enable), null, `${availability}: 켜기 버튼을 주면 안 된다`);
  }
});

test('알림 시트: 켜기에 성공하면 켜짐 상태로 다시 그린다', async () => {
  let called = 0;
  const sheet = await openSheet('off', { enable: async () => { called += 1; return { ok: true }; } });
  sheet.set('on');
  sheet.button(strings.notifications.enable).click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(called, 1);
  assert.ok(sheet.text().includes(strings.notifications.on));
  assert.ok(sheet.button(strings.notifications.disable));
});

test('알림 시트: 권한 거절은 일반 실패와 다른 문구를 보여준다', async () => {
  const sheet = await openSheet('off', { enable: async () => ({ ok: false, reason: 'no-permission' }) });
  sheet.button(strings.notifications.enable).click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(sheet.text().includes(strings.notifications.permissionRefused));
  assert.ok(!sheet.text().includes(strings.notifications.enableFailed));
});

test('알림 시트: 켜기가 실패하면 이유를 보여주고 꺼짐으로 남는다', async () => {
  const sheet = await openSheet('off', { enable: async () => ({ ok: false, reason: 'pusher-failed' }) });
  sheet.button(strings.notifications.enable).click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(sheet.text().includes(strings.notifications.enableFailed));
  assert.ok(sheet.button(strings.notifications.enable), '다시 시도할 수 있어야 한다');
});

test('알림 시트: 켜기가 던져도 시트가 살아 있다', async () => {
  const sheet = await openSheet('off', { enable: async () => { throw new Error('boom'); } });
  sheet.button(strings.notifications.enable).click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(sheet.text().includes(strings.notifications.enableFailed));
  assert.ok(sheet.button(strings.notifications.enable));
});

test('알림 시트: 끄기에 성공하면 꺼짐 상태로 다시 그린다', async () => {
  const sheet = await openSheet('on', { disable: async () => ({ ok: true, removed: true, unsubscribed: true }) });
  sheet.set('off');
  sheet.button(strings.notifications.disable).click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(sheet.text().includes(strings.notifications.off));
});

test('알림 시트: 화면에 "null"이나 "undefined" 글자가 나오지 않는다', async () => {
  // #126 회귀: replaceChildren(..., null, ...)이 텍스트 "null"을 그렸다.
  for (const availability of ['off', 'on', 'denied', 'unsupported', 'not-configured', 'ios-needs-install']) {
    const sheet = await openSheet(availability);
    const text = sheet.text();
    assert.ok(!text.includes('null'), `${availability}: "null"이 화면에 있다`);
    assert.ok(!text.includes('undefined'), `${availability}: "undefined"가 화면에 있다`);
  }
});
