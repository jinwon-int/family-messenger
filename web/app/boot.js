// 모듈 로드·실행 실패를 빈 화면 대신 화면에 그대로 보여준다(진단용, 비밀값 없음).
// 인라인 <script>였으나 CSP(script-src 'self')를 위해 파일로 분리했다.
(function () {
  function show(message) {
    var app = document.getElementById('app');
    if (!app) return;
    var note = document.createElement('pre');
    note.className = 'boot-error';
    note.textContent = '화면을 시작하지 못했습니다.\n' + message;
    app.replaceChildren(note);
  }
  window.onerror = function (message, source, line, col) {
    show(message + ' (' + (source || '?') + ':' + (line || '?') + ')');
  };
  window.addEventListener('unhandledrejection', function (event) {
    show('promise: ' + (event.reason && (event.reason.message || event.reason)));
  });
})();
