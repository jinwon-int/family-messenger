// Entry point. Module errors before the app starts (old browser, blocked worker)
// land in the boot note instead of a blank page.
import {installTheme} from './theme.js';
import {startApp} from './app.js';

// 화면 테마(밤 기본 · 낮불 · 시스템 따라가기)는 첫 그리기 전에 <html data-theme> 로 건다. CSP 가 인라인 스크립트를
// 막아(script-src 'self') 모듈 시작이 가장 이른 자리다 — 낮불을 고른 기기는 한 프레임 밤이 보일 수 있다.
const theme = installTheme();

const root = document.getElementById('app');
try {
  startApp(root, {theme});
} catch (error) {
  root.textContent = `앱을 시작할 수 없습니다: ${error.message}`;
}

// PWA 설치·오프라인 셸(#480 D): 등록은 최선 노력 — 없어도 앱은 그대로 동작한다. 모듈 워커(sw-policy.js import).
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js', { type: 'module' }).catch(() => { /* best effort */ });
  });
}
