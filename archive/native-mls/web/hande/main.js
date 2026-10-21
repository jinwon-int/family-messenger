// Entry point. Module errors before the app starts (old browser, blocked worker)
// land in the boot note instead of a blank page.
import {startApp} from './app.js';

const root = document.getElementById('app');
try {
  startApp(root);
} catch (error) {
  root.textContent = `앱을 시작할 수 없습니다: ${error.message}`;
}

// PWA 설치·오프라인 셸(#480 D): 등록은 최선 노력 — 없어도 앱은 그대로 동작한다. 모듈 워커(sw-policy.js import).
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js', { type: 'module' }).catch(() => { /* best effort */ });
  });
}
