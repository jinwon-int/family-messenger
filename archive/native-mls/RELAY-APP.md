# 사람용 릴레이 클라이언트 (`web/relay-app.html`, #243 2-a)

v2 릴레이에 사람이 직접 붙는 최소 클라이언트. 스모크가 프로그램으로 구동하는 **같은 durable
워커**(`web/durable-worker.js`: IndexedDB + 암호 커스터디)를 쓰고, 스모크(`native_v2_relay_smoke.py`)가
Python에서 하던 릴레이 호출을 브라우저로 옮긴 것이다. 합성 전용·인수검사용이며 제품 UI가 아니다.

## 왜 릴레이가 직접 서빙하나

브라우저가 말을 거는 origin은 릴레이 하나여야 한다: 같은 origin의 `fetch('/v2/…')`에 Cloudflare Access
쿠키가 자동으로 실리고, 엣지가 `Cf-Access-Jwt-Assertion`을 넣어 준다(사용자 토큰 = 로그인한 사람의
`sub`). 그래서 릴레이는 `-static-dir <dir>`로 `/app/*`를 **무인증** 서빙한다(정적 코드에 비밀 없음);
`/v2/*`는 그대로 JWT 뒤에 있다. 경로는 `os.Root`로 디렉터리 안에 가두고, 점 파일·디렉터리·GET/HEAD 외
메서드는 404/405, 헤더는 킷 서버와 같은 CSP(`'wasm-unsafe-eval'`, self만) + `no-store` + `nosniff`.

```text
<static-dir>/
  relay-app.html  relay-app.js  main.js  durable-worker.js  session-store.js   ← web/ 원본 그대로
  pkg/family_mls_browser_experiment.js  pkg/family_mls_browser_experiment_bg.wasm  pkg/custody.js
                                                                                  ← build.sh 번들(bundle-sha256.txt 일치본)
```

## 흐름 (페이지가 하는 일 = 스모크 `Device.sync`)

1. **워커 시작**: 기기 ID(`[A-Za-z0-9_-]`, 예 `owner-pc`·`owner-iphone`·`bot-1` — 첫 `-` 앞이 **actor**),
   방(`[a-z0-9-]`), DB(`family-mls-synthetic-…`), 암호 32자+. 모바일에선 암호 키 유도(scrypt logN 18)에
   1~3분(#246). 재시작은 같은 DB·암호. "운영자 등록 정보"(device_id·actor·signing_key·지문)를
   운영자에게 넘기면 `native-devices -enroll-first`(첫 기기) / `-add-device`(둘째 기기, §4)로 체인에 올린다.
   체인에 없는 기기는 릴레이가 403 `device_subject_mismatch` — 화면에 "운영자 등록 대기".
2. **방**: 첫 기기 `방 만들기`(로컬 그룹 생성). 다른 기기는 `키 패키지 게시`(릴레이 `/keypackages`,
   ref = sha256). 초대하는 쪽이 `초대`: 상대 패키지 소비 → `invite_with_commit` → **commit POST**
   (members = `members_after_pending`, actor = ID 접두) → 201이면 pending → 다음 동기화에서 **내 echo를
   만나야 `merge_pending`** → 그제야 **타깃 Welcome POST**. 409 `cas_mismatch`면 `clear_pending` 후 동기화·재시도.
3. **동기화**(4초 폴링 + 버튼): `GET /events?after=` → 내 commit echo(merge) / Welcome(참여 전) →
   `join` / commit → `commit` 적용 / application → `decrypt`(워커가 방 바인딩) → 표시(발신 기기·client).
   참여 뒤에는 처리한 seq까지 `?ack=`(읽기는 커서를 안 움직인다, M2). `first_seq`가 내 커서보다 앞서면
   잘린 역사 경고.
4. **둘째 기기 승인(E2)**: 신뢰 기기 화면에 새 기기의 등록 정보 JSON(+ `subject`, `base_revision`)을 붙여
   넣고 `지문 보기`(`policy_fingerprint`) → 두 화면 지문을 사람이 비교 → `이 지문이 맞습니다` →
   `sign_approval`(durable 신원의 키로 서명) → 증거 JSON(signature 포함)을 운영자에게 → `-add-device -input`.
5. **저장소 삭제**: 축출 재연습. 재시작하면 새 기기(새 지문) → 운영자 재등록 + 상대 재초대.

durable 워커 허용 메서드에 이번에 더해진 것: `invite_with_commit` `merge_pending` `clear_pending`
`remove_pending` `members` `members_after_pending` `fingerprint` `policy_fingerprint` `sign_approval`
(파사드 `Session.dispatch`에 읽기 전용/서명 arm 추가; store 변경 0).

## 검증

- `archive/native-mls/tests/native_relay_app_smoke.py --bundle … --relay-binary …`: 두 Chromium 컨텍스트가
  이 페이지만으로(파이썬 측 릴레이 호출 0) 생성 → 키 패키지 → 초대(commit 201 → echo merge → Welcome) →
  참여 → 양방향 메시지(발신자 표시) → 릴레이 커서 ack → 재시작 시 틀린 암호 거부. 릴레이는
  `-access-mode disabled`(loopback, 정책 체인 없음). 수신증 `archive/artifacts/native-relay-app-*/`.
- Go: `TestStaticClientServing`(헤더·점 파일·traversal·메서드·`/v2` 불변), `TestStaticRootRequiresIndex`.
- 파사드: `durable_lane_roster_fingerprint_and_sign_approval`.

## 증명하지 않는 것

- 들어오는 commit의 정책 검사(stage_commit/merge_staged)는 이 페이지에 없다 — `commit`으로 바로 머지한다.
  멤버십 정책은 릴레이가 commit 수락 전에 강제하므로(M3b) 파일럿 범위(오너+봇)에서는 서버 정책이 경계다.
- 제거(remove_pending)·방 닫기 UI 없음(운영자 CLI/릴레이 도구). 첨부 UI 없음(텍스트만).
- Access 쿠키 만료(730h) 뒤의 재로그인 UX: 401이면 "새로고침해 로그인" 안내만.
