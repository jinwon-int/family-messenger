# 우리 웹 화면 (web/app) — 1단계 착수 슬라이스

> **상태(2026-09-13): 1단계 착수 코드.** [개발 순서](ROADMAP.md) 1단계의 "우리 웹 화면" 항목을
> [결정 D](DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md)에 따라 `matrix-js-sdk`(Rust 암호화 WASM) 기반으로
> 만들기 시작한 첫 조각이다. 실제 가족 대화(실기기 100건) 게이트는 아직이다. 아래 "아직 하지 않은 것"을
> 함께 읽으시오.

## 목적과 범위

가족이 쓰는 화면을 Element 없이 직접 소유한다(결정 D). 첫 슬라이스는 다음을 담는다.

| 요구(1단계) | 이 슬라이스의 상태 |
|---|---|
| 로그인 기본값 | `dist/config.json`의 `homeserverUrl`(https)이 있으면 홈서버 칸을 미리 채우고 접어 둔다(마지막 로그인 주소·아이디도 미리 채움). 공개 저장소에는 예시만 |
| 한국어·휴대폰 우선 | 모든 문구는 `src/strings.js`에 한국어로 모아둔다. 휴대폰 세로는 단일 pane(목록 ↔ 대화), 휴대폰 가로(landscape, 폭 640~899px)는 왼쪽 목록 280px · 오른쪽 대화, 900px부터 2열(왼쪽 목록 340px · 오른쪽 대화), 1200px부터 3열(+보관함). 셸이 화면 높이를 고정하고 목록 pane과 타임라인만 스크롤한다. 방을 열면 하단, 하단 근처면 자동 하단 유지, 위로 올려 둔 채 새 메시지가 오면 위치 보존 + "새 메시지 ↓" 배지 |
| PWA 설치 | `manifest.webmanifest` + `sw.js`(앱 껍데기 캐시, `/_matrix` 우회). 홈 화면 추가로 앱처럼 실행 |
| 개인방·가족방 | `m.direct` 표시·참여자 수로 분류(`src/rooms.js`). 판단 불가 방은 보수적으로 "다른 방" |
| 텍스트·사진·영상·일반 파일 | `m.text`·`m.image`·`m.video`·`m.file` 작성·표시. 업로드는 홈서버 미디어 저장소 경유(mxc URL) |
| 기기 검증(이모지 비교) | SDK Rust crypto의 SAS를 이모지 시트로 진행(`src/verification.js` + `startEmojiVerification`). 이모지 한국어 라벨표 포함, 없는 항목은 SDK 영어 이름 표시 |
| 복구 키 생성·보관 안내 | 로컬 생성(base58, 32바이트) → 한 번만 표시 → 다시 입력 확인(`src/recovery.js`). **키는 어디로도 전송되지 않는다** |
| 사람과 AI 구별 표시 | 플릿 계약의 봇 사용자 ID 목록 또는 멤버 이벤트 표식(`us.familychat.kind: "agent"`)으로 AI 배지 표시(`src/participants.js`) |
| 보관함(첨부 + 파일보관함) | 오른쪽 pane(1200px부터 세 번째 열, 좁은 화면은 별도 화면). 첨부 탭은 참여한 모든 방의 사진·영상·파일을 최신순으로 모아 인증 미디어 엔드포인트로 받고(암호화 첨부는 `matrix-encrypt-attachment`로 복호화) 사진은 미리보기, 나머지는 다운로드. 파일보관함 탭은 `dist/config.json`의 `filebox.url`이 있을 때만 iframe으로 임베드(🔄 새로고침·새 창에서 열기, seo web bridge와 같은 방식) |
| 가족방 초대 수락 | 초대 목록·수락/거절(`src/invites.js` + 어댑터 `inviteSummaries`/`joinRoom`/`declineInvite`). AI 참여 방은 원칙 1 동의 확인 후에만 수락 활성화 |

화면 규칙(2026-09-17 재디자인):

- 스타일은 `styles.css`의 토큰(색·간격·글자 크기)만으로 조정한다. 본문 16px 이상, 터치 대상 44px 이상,
  시스템 다크 모드(`prefers-color-scheme`)와 움직임 줄이기(`prefers-reduced-motion`)를 따른다.
- 내 메시지는 오른쪽 브랜드색, 상대 메시지는 왼쪽 표면색에 보낸 사람·AI 배지를 붙인다. 첨부는 종류(사진·영상·파일)
  라벨과 용량·시각을 함께 보인다. 시트(기기 검증·복구 키)는 휴대폰에서 하단 시트, 데스크톱에서 중앙 대화상자다.
- 같은 방을 다시 그릴 때 `renderShell`은 목록·헤더·타임라인·보관함만 부분 교체하고 **작성창(`composer-wrap`)은 그대로 둔다** — 요소를 교체하고 값을 다시 넣으면 한글 IME 조합이 끊긴다(자모 분리·깜빡임, 2026-09-17). 방을 바꿀 때만 전체 재구성.
- 조건부 자식은 `el()`/`setChildren()`을 거쳐야 한다(맨 `replaceChildren(null)`은 "null" 글자를 그린다 — 정적 시험이 막는다).
- 번들·스타일·boot 스크립트는 빌드가 **내용 해시 파일명**(`main-XXXXXXXX.js`, `styles-xxxxxxxx.css`, `boot-xxxxxxxx.js`)으로 내보내고 `index.html`·`sw.js`(캐시 이름 = 빌드 해시)를 다시 쓴다. 소스에는 `?v=` 버전을 두지 않는다(정적 시험이 막는다). 문서·`config.json`·매니페스트는 네트워크 우선, 해시 자산·wasm은 캐시 우선.
- `serve.mjs`가 CSP(`default-src 'self'`, `script-src 'self' 'wasm-unsafe-eval'`, `connect-src https: wss:`, `frame-src https:`, `frame-ancestors 'none'`)·HSTS·nosniff·Referrer-Policy·Permissions-Policy를 붙인다. 인라인 `<script>`·`style=` 속성은 쓰지 않는다(`boot.js` 분리, 클래스 사용).

보안 경계(이 슬라이스에서 지킬 것):

- 접속 토큰은 `sessionStorage`에만 둔다. 창을 닫으면 다시 로그인한다. 토큰이 영속 저장소에
  들어가는 경로는 없고, 단위 시험이 이 규칙을 검증한다.
- 암호화가 확인되지 않는 방으로의 전송은 거부한다("평문 전환으로 숨기지 않는다", 결정 D).
- 복구 키는 서버로 수집하지 않는다.

## 구성

```
web/app/
├── index.html            # 앱 껍데기 (lang="ko")
├── styles.css            # 모바일 우선 스타일
├── manifest.webmanifest  # PWA
├── sw.js                 # 껍데기 캐시 서비스 워커
├── build.mjs             # esbuild 번들(스크립트: npm run build)
├── serve.mjs             # dist 정적 서버(스크립트: npm run serve)
├── package.json          # matrix-js-sdk 42.3.0 고정, esbuild 0.28.2
├── src/
│   ├── strings.js        # 사용자 문구(한국어) 단일 출처
│   ├── rooms.js          # 개인방·가족방 분류, 표시 이름
│   ├── participants.js   # 사람/AI 참여자 분리
│   ├── verification.js   # 기기 검증 상태기계 + 이모지 한국어 라벨
│   ├── recovery.js       # 복구 키 생성·입력 확인 (base58)
│   ├── messages.js       # msgtype 분류·용량 표시·첨부 본문
│   ├── session.js        # 토큰 휘발성 저장 경계
│   ├── ui.js             # 화면 렌더링(로직 없음)
│   ├── main.js           # 연결·화면 전환
│   └── matrix/client.js  # matrix-js-sdk 어댑터(지연 로딩)
└── tests/                # node --test 단위 시험 + SDK 스모크
```

의존성 원칙: 순수 로직 모듈(`src/*.js`)은 의존성 0으로 `node --test`에서 바로 돈다.
`matrix-js-sdk`는 `src/matrix/client.js`에서만 동적으로 불러오고, SDK 미설치 환경에서는
가짜 주입(테스트)으로 계약을 검증한다. 버전은 package.json에 정확히 고정하고(`^` 없음)
`package-lock.json`을 **커밋한다** — CI(`web.yml`)와 배포(`deploy/web/build.sh`)는 `npm ci`로 잠금 파일
그대로 설치한다(2026-09-17 정정: 이전 문서의 "락파일 미커밋"은 #102 이후 실제와 달랐다).

## 실행

Linux/macOS, Node 22 이상.

```bash
cd web/app
npm ci --no-audit --no-fund
npm test                 # 단위 시험 (의존성 설치 없이도 가능: node --test tests/)
node tests/transport_smoke.mjs   # SDK·Rust 암호화 WASM 스모크 (설치 후)
npm run build            # dist/ 번들 (matrix-js-sdk + Rust 암호화 WASM 자산 복사 포함)
npm run serve            # http://127.0.0.1:8080 에서 dist 서빙
```

빌드는 Rust crypto WASM(`@matrix-org/matrix-sdk-crypto-wasm`)의 `.wasm` 바이너리를
glue가 기대하는 상대 경로 `dist/pkg/`로 복사하고, 번들이 그 경로를 참조하는지 검사한다.
번들 결과(main.js 약 1.1 MB + wasm 약 7.8 MB)는 브라우저 캐시 관점에서 무겁지만
1단계에서는 정확성을 우선한다.

로컬 시험은 가족 데이터 없는 새 계정으로만 하고, 운영 홈서버는 쓰지 않는다.
홈서버 주소 예시는 `https://<homeserver>` 형태로만 문서에 적는다.

## 시험

| 시험 | 내용 |
|---|---|
| `npm run test:dom` (`tests/dom/*.test.mjs`, happy-dom 20.14.5 고정) | 로그인·셸(목록/대화/보관함)·시트 5종을 실제 DOM으로 그려 "null" 글자·초안 유실·작성창 교체(IME) 같은 화면 결함을 잡는다. 의존성이 필요해 설치 후 실행(CI는 `npm ci` 뒤) |
| `npm test` (`node --test tests/`) | strings·방 분류·참여자 분리·검증 상태기계·복구 키·메시지 본문·세션 경계·SDK 어댑터 계약(가짜 주입) |
| `tests/transport_smoke.mjs` | 고정 버전 matrix-js-sdk 로딩, `initRustCrypto`·`login`·`uploadContent`·WASM 패키지 존재 |
| `npm run build` | 브라우저 번들 성공(WASM 자산 포함) |
| CI (`.github/workflows/web.yml`) | 위 전부 + dist 서빙·껍데기 응답 검사, 번들 아티팩트 보존 |

실행 기록은 PR 본문에 붙인다. 브라우저에서의 실기기 검증(이모지 비교 양쪽 화면)은
1단계 후반 실가족 게이트에서 진행한다.

## 아직 하지 않은 것 (1단계 남은 일)

- 실제 홈서버(1단계 단일 바이너리)와의 종단간 E2EE 대화 검증 — 이 슬라이스는 로컬 시험까지만.
- 푸시 알림(2단계), 사진·영상 실기기 재생·용량 초과 안내(2단계).
- 복구 키를 SDK 비밀 저장소(secret storage)와 연결하고, "새 기기에서 이력 복구" 흐름 완성.
  현재 시트는 키 생성·확인 안내까지만 담당한다.
- ~~검증 요청이 도착했을 때 수신 쪽 시트 자동 연결~~ — 2026-09-17 완료: 내 다른 기기의 요청(`crypto.verificationRequestReceived`, 자기 기기 한정)이 오면 수락 시트가 열린다. 보내는 쪽은 상대 기기가 수락(phase Ready)할 때까지 기다린 뒤 SAS를 시작한다(요청 직후 시작하면 SDK가 "other device is unknown"으로 거부해 즉시 취소되던 결함 수정).
- 타임라인 페이지네이션(이전 대화 불러오기), 읽음 표시, 알림 뱃지.
- Element 전환(운영 클라이언트 교체) — 오너 승인 시점까지 병행 유지(#92, 2026-09-16).

## 배포 (운영)

루프백 서빙 + 터널 노출은 [`deploy/web/`](../deploy/web/README.md) 패키지: `build.sh`로 dist 번들 →
`family-chat-web.service`(127.0.0.1:8090) → 터널 hostname 라우팅. 홈서버 API는 CORS `*`로
직접 호출된다(2026-09-16 실측). Element(`chat.<도메인>`)와 병행 — 전환은 별도 승인.

## 관련 문서

- [개발 순서 1단계](ROADMAP.md) — 게이트: 가족 2명 + AI 1, 실제 대화 100건(E2EE, 두 기기).
- [결정 D](DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md) — 왜 Matrix 스택 + 직접 만드는 화면인가.
- [홈서버 평가](evidence/homeserver-eval-20260913.md) — 미디어 한도(100 MiB)·비인증 다운로드 403 등 이 화면이 따르는 서버 실측.
