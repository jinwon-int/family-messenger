# 한데 웹 (`archive/native-mls/web/hande`, #431)

「한데」 iOS 앱의 **PC 크롬 버전**. 전달·암호화는 독자 트랙 그대로(v2 릴레이 + OpenMLS 파사드),
화면 구조·조작은 패밀리챗 웹앱(`web/app`)에서 가져왔다. 런타임은 섞지 않는다(결정 E 규칙 1 —
matrix-js-sdk 없음, 빌드 도구·npm 의존 없음, 플레인 ES 모듈).

## 왜 릴레이가 서빙하나 (RELAY-APP.md 와 같은 이유)

브라우저가 말을 거는 origin 은 릴레이 하나여야 한다: same-origin `fetch('/v2/…')` 에 Cloudflare Access
쿠키가 자동으로 실리고 엣지가 `Cf-Access-Jwt-Assertion` 을 넣는다. 릴레이는 `-hande-host <호스트>
-hande-dir <디렉터리>` 로 **그 호스트의 루트(`/`)** 에 이 디렉터리를 무인증 서빙하고(정적 코드에 비밀 없음),
`/v2/*` 는 모든 호스트에서 JWT 뒤에 있다(`server/hande.go`). 한데 호스트는 릴레이와 **같은 Access 앱의
도메인**이어야 JWT `aud` 가 `-access-audience` 와 맞는다(별도 앱이면 401).

```text
<hande-dir>/
  index.html styles.css strings.js ui.js app.js main.js          ← 화면·상태기계 (이 디렉터리)
  keyboard.js shortcuts.js timeline-caret.js                     ← 키보드 판정·전역 단축키·캐럿 모드(패밀리챗 이식, #478)
  room-order.js                                                  ← 대화 목록 고정 순서(▲▼ 편집, 이 기기 localStorage — 패밀리챗 이식, #480)
  attachment-view.js agent-markdown.js                           ← 첨부 미리보기 판별 · 에이전트 답장 마크다운(iOS AgentMarkdown 블록 규칙 이식, 텍스트 노드만)
  room.js device.js relay.js identity.js worker-bridge.js        ← 방 세션(relay-app.js sync 이식)·기기(신원·로비·방 목록)·릴레이·신원
  durable-worker.js session-store.js history-store.js            ← openmls-browser/web 원본 그대로(build.sh 가 복사)
  commit-policy.js relay-attachments.js
  pkg/family_mls_browser_experiment.js *_bg.wasm custody.js      ← build.sh 번들(bundle-sha256.txt 일치본)
  icons/ manifest.webmanifest [config.json]
```

조립: `archive/native-mls/web/hande/build.sh <mls-pkg> <out>`. `config.json` (선택, 미커밋)
`{"defaultRoom":"<방>"}` — 없으면 `family`.

## 흐름 (iOS AppModel.Phase 와 같음)

1. **이름 선택**(첫 실행 1회, `.needsActor`): 영문 소문자 이름 → 기기 ID `<actor>-web-<6hex>`(`identity.js`).
   저장소 암호(custody scrypt)는 사람이 입력하지 않고 브라우저가 만들어 localStorage 에 둔다 — 같은 프로필의
   IndexedDB 와 같은 신뢰 경계(iOS Keychain 에 해당). 사용자 잠금 암호는 후속.
2. **기기 등록**(`.needsEnrollment`): 워커가 서명키를 만들면 지문·등록 JSON(`device_id`·`actor`·`subject`·
   `signing_key`·`fingerprint`)을 보여 준다. `subject` 는 `GET /v2/me`(엣지 JWT 의 `sub`)로 채운다. 릴레이가
   403 `device_subject_mismatch` 를 돌려주는 동안 이 화면이 4초 폴링으로 기다리고, 운영자가 `-enroll-first` /
   `-add-device`(신뢰 기기 승인 E2 — 이 앱의 「신뢰 기기 승인」시트가 서명한다)로 체인에 올리면 다음 폴링에서
   대화 화면으로 넘어간다. 재시작 불필요.
3. **대화**(`.ready`): 목록 pane + 대화 pane(900px 부터 분할). 방 처리 순서는 `room.js` = relay-app.js `sync()`
   = 봇·iOS 와 같다(내 commit echo → merge_pending(+Welcome) · Welcome → join · 타인 commit → stage →
   정책 ①~④ → merge / discard + ⛔ 정지 · application → decrypt → 봉인 보관(#370) → ack).
   「+」: 참여 요청(키 패키지 게시)·방 만들기. 메뉴: 초대·멤버 제거(#289)·신뢰 기기 승인·설정·이 기기 지우기.
4. **정지**(`.halted`, #261/#289): 거부·제거는 durable 하고 새로고침 뒤에도 남는다. 다음 행동은 「이 기기 지우기」
   → 새 기기 ID(#290) → 운영자 등록 → 재초대뿐이다.

**다중 방(#431 4단계)**: 워커의 multi 모드(`device.js`, openmls-browser PERSISTENCE.md "다중 스토어")로 신원 스토어
(`-identity`, 서명키) 하나에서 방 스토어를 파생한다 — iOS `_identity`/`_lobby` 슬롯과 같다. 방 목록 = 릴레이 `GET /v2/rooms`
의 멤버 방 ∪ 여기서 만든/참여 요청한 방 ∪ 로비 Welcome 으로 열린 방. **로비 키**(#380): 등록 뒤 8초 틱마다 `GET /v2/lobby/status`
로 부족분을 `-lobby` 스토어에서 만들어 `POST /v2/lobby/keypackages`(소비분은 FIFO 로 로컬 비밀 삭제). `GET /v2/lobby/welcomes` 에
미참여 방이 있으면 — 오너 actor 는 자동 참여(방 스토어 = 로비 사본 → 커서를 Welcome 앞으로 → join), 가족 기기는 목록 위
초대 카드(수락 1탭 / 무시). 「초대」는 방별 키 패키지 → 없으면 상대의 로비 키를 그 방으로 소비한다(iOS RoomMembership 과 동일).
1차(방 1개) 설치는 첫 실행에서 기본 방 DB 의 서명키가 신원 스토어로 **이전**되므로 재등록이 필요 없다.

## 키보드 (#478 — 패밀리챗 `web/app` 과 동일)

판정은 `keyboard.js`(순수 함수), 전역 설치는 `shortcuts.js`(document 위임 — 목록·방 pane 이 교체돼도 유지), 캐럿 모드는 `timeline-caret.js`.
시트(`dialog[open]`)가 떠 있거나 IME 조합 중이면 가로채지 않는다.

| 키 | 어디서 | 동작 |
|---|---|---|
| Enter / Shift+Enter | 작성창 | 전송 / 줄바꿈(조합 확정 Enter 는 무시). 보내는 중의 Enter 는 글을 그대로 둔다. 전송이 실패하면 글을 되살린다 |
| PageDown / PageUp | 2분할(900px~) | 목록 순서대로 다음/이전 방을 바로 열고 작성창에 커서(가려진 행만 목록 스크롤) |
| PageDown / PageUp | 단일 pane 목록 / 방 화면 | 행 사이 포커스 이동(열지 않음) / 이전·다음 방으로 전환 |
| Home | 방 화면 어디서나 | 목록으로(초안은 방별 보존) |
| Esc · End | 작성창 | 대화 내용으로 포커스(End 는 수정키 없을 때만) |
| ↑ / ↓ | 대화 내용 | 60px 스크롤 |
| Esc | 대화 내용 | 캐럿 모드(점선 테두리) — Shift+방향키·Shift+Home/End 로 글자 선택, Ctrl+C 복사. Esc 로 복귀, Enter 로 작성창 |
| Enter | 대화형 요소 밖 | 작성창으로 커서 |

## 대화 목록 (#480 A — 패밀리챗 `web/app` 과 동일)

- 순서: 최근 활동순으로 움직이지 않는다. 기본은 참여한 순서, 「↕ 순서」로 편집 모드(▲▼, PC 는 끌어서) → 이 기기
  localStorage `hande:room-order:<device>` 에 저장(패밀리챗은 account data 로 기기 간 동기화 — 한데에는 그 저장소가 없다).
  편집 중에는 행을 눌러도 열리지 않고 PageUp/PageDown 도 방을 열지 않는다.
- 행: 이름 옆 **N 배지**(안 읽은 방, 보조기기에는 "새 메시지"), 상대 시각(방금/N분 전/N시간 전/어제/M.D.), 미리보기는
  마크다운 기호를 걷어낸 한 줄 — 첨부는 `[사진]`(내용 판별) / `[파일]`.

## 검증

- 순수 모듈: `node --test archive/native-mls/web/hande/tests/*.test.mjs` — 방 세션(가짜 워커·대본 릴레이: 403
  대기, Welcome 참여, 해독→보관→ack, 전송 CAS 재시도, 초대 commit→echo→Welcome, 거부·제거 정지, #296 복구),
  문구·검증 헬퍼, 키보드 판정(`keyboard.test.mjs`), 목록 순서(`room-order.test.mjs`).
- 브라우저: `archive/native-mls/tests/native_hande_web_smoke.py --bundle <mls-pkg> --relay-binary <relay>` —
  격리 릴레이(`-access-mode disabled`, `-hande-host`)가 이 디렉터리를 서빙하고 두 Chromium 컨텍스트가 **화면만
  으로** 이름 선택 → 방 만들기 → 참여 요청 → 초대 → 참여 → 양방향 메시지 → 새로고침 뒤 보관 이력 복원, 이어서 둘째 방을
  **로비 키로** 초대(가족 기기: 초대 카드 수락 / 오너 기기: 자동 참여)하고 두 방이 서로 섞이지 않음, 그리고
  키보드(PageDown/PageUp 방 전환·Esc/Enter 포커스·Home 목록)를 거친다.
- Go: `hande_test.go`(호스트 라우팅·가둠·헤더), `me_test.go`.

## 증명하지 않는 것

실제 CF Access 엣지 경유(합성 릴레이는 JWT 없음) · 푸시 알림(webpush 게이트웨이 없음) · 기기 간 이력 이전 · 모바일 브라우저 ·
오너 두 기기의 실사용(인수검사 #243 계열은 사람이 한다).
