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
  room.js relay.js identity.js worker-bridge.js                  ← 방 세션(relay-app.js sync 이식)·릴레이·신원
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

**1차 범위는 방 1개**(기본 가족방). 파사드 `export_identity` 가 브라우저 표면에 없어(#177 M2b-3c) durable 워커는
DB 1개 = 방 1개 = 서명키 1개다. 신원 공유(iOS 의 `_identity` 슬롯)는 #431 4단계.

## 검증

- 순수 모듈: `node --test archive/native-mls/web/hande/tests/*.test.mjs` — 방 세션(가짜 워커·대본 릴레이: 403
  대기, Welcome 참여, 해독→보관→ack, 전송 CAS 재시도, 초대 commit→echo→Welcome, 거부·제거 정지, #296 복구),
  문구·검증 헬퍼.
- 브라우저: `archive/native-mls/tests/native_hande_web_smoke.py --bundle <mls-pkg> --relay-binary <relay>` —
  격리 릴레이(`-access-mode disabled`, `-hande-host`)가 이 디렉터리를 서빙하고 두 Chromium 컨텍스트가 **화면만
  으로** 이름 선택 → 방 만들기 → 참여 요청 → 초대 → 참여 → 양방향 메시지 → 새로고침 뒤 보관 이력 복원을 거친다.
- Go: `hande_test.go`(호스트 라우팅·가둠·헤더), `me_test.go`.

## 증명하지 않는 것

실제 CF Access 엣지 경유(합성 릴레이는 JWT 없음) · 푸시 알림(webpush 게이트웨이 없음) · 다중 방 · 모바일 브라우저 ·
오너 두 기기의 실사용(인수검사 #243 계열은 사람이 한다).
