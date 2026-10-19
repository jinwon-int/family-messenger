// Entry point. Module errors before the app starts (old browser, blocked worker)
// land in the boot note instead of a blank page.
import {startApp} from './app.js';

const root = document.getElementById('app');
try {
  startApp(root);
} catch (error) {
  root.textContent = `앱을 시작할 수 없습니다: ${error.message}`;
}
