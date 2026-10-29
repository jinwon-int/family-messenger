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
  read-seq.js                                                    ← 방별 「어디까지 봤나」·안 읽음 판정(iOS readSeq·Unread.isUnread 이식, #541)
  drafts.js composer-files.js                                    ← 방별 초안 영속화 · 붙여넣기/끌어다 놓기 첨부 파일 고르기(#480 B)
  last-sent.js                                                   ← 대화창 상단 「내 마지막 말」 바 순수 로직(패밀리챗 이식, #480 C)
  sync-recovery.js preview-loader.js                             ← 탭·온라인 복귀 즉시 동기화 · 미리보기 실패 「다시 시도」(패밀리챗 이식, #544 A·B)
  attachments.js                                                 ← 보관함 「첨부」 탭 순수 로직(모든 방 첨부 최신순, 패밀리챗 collectAttachments 이식, #544 D)
  agent-consent.js                                               ← AI 참여 동의 판정·기록(참여 뒤 명단 기준, 이 기기 localStorage — #544 E 선택지 3)
  local-room.js                                                  ← 로컬 전용 방(릴레이에 없는 방) 판정 · 「이 기기에서 지우기」 키 정리
  self-service.js                                                ← 기기 셀프서비스 순수 판정(승인 자격·형제 판정·증거 조립·역할 버튼·초대 대기열, #574 PR 2b)
  sw.js sw-policy.js                                             ← 서비스 워커(PWA 설치·오프라인 셸, 네트워크 우선 — #480 D)
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
   대화 화면으로 넘어간다. 재시작 불필요. **셀프서비스(#574 PR 2b, 아래 절)**: 같은 사람의 기기가 이미 있으면 운영자 없이
   그 기기가 승인한다 — 이 화면은 자동으로 「다른 기기에서 승인해 주세요」(큰 지문) 모드가 된다.
3. **대화**(`.ready`): 목록 pane + 대화 pane(900px 부터 분할). 방 처리 순서는 `room.js` = relay-app.js `sync()`
   = 봇·iOS 와 같다(내 commit echo → merge_pending(+Welcome) · Welcome → join · 타인 commit → stage →
   정책 ①~④ → merge / discard + ⛔ 정지 · application → decrypt → 봉인 보관(#370) → ack).
   헤더: 🔔 알림·🗂 파일보관함·⚙ 설정(+순서 편집). 메뉴(⚙): 참여 요청(키 패키지 게시)·방 만들기·설정·초대·멤버 제거(#289)·내 기기(#574)·신뢰 기기 승인·지금 동기화·이 기기 지우기 — 참여 요청·방 만들기는 2026-10-27 헤더에서 메뉴로 옮김.
4. **정지**(`.halted`, #261/#289): 거부·제거는 durable 하고 새로고침 뒤에도 남는다. 다음 행동은 「이 기기 지우기」
   → 새 기기 ID(#290) → 운영자 등록 → 재초대뿐이다.

**다중 방(#431 4단계)**: 워커의 multi 모드(`device.js`, openmls-browser PERSISTENCE.md "다중 스토어")로 신원 스토어
(`-identity`, 서명키) 하나에서 방 스토어를 파생한다 — iOS `_identity`/`_lobby` 슬롯과 같다. 방 목록 = 릴레이 `GET /v2/rooms`
의 멤버 방 ∪ 여기서 만든/참여 요청한 방 ∪ 로비 Welcome 으로 열린 방. **로비 키**(#380): 등록 뒤 8초 틱마다 `GET /v2/lobby/status`
로 부족분을 `-lobby` 스토어에서 만들어 `POST /v2/lobby/keypackages`(소비분은 FIFO 로 로컬 비밀 삭제). `GET /v2/lobby/welcomes` 에
미참여 방이 있으면 — 오너 actor 는 자동 참여(`-lobby` 스토어를 먼저 열고 → 방 스토어 = 로비 사본 → 커서를 Welcome 앞으로 → join),
가족 기기는 목록 위 초대 카드(수락 1탭 / 무시). 헤더의 🔔(#521)는 받은 초대와 처리 상태(새 초대·수락 중·자동 수락 실패 n회)를
모아 보이고 수락/다시 시도/무시를 받는다 — 오너 기기의 자동 참여가 실패해도 로그가 아니라 여기와 목록 카드에 남는다.
수락은 같은 Welcome 에 대해 페이지 세션당 2회까지 시도하고(「다시 시도」는 횟수 초기화), 수락 안 된 Welcome 이
남아 있는 동안 그 Welcome 의 `key_package_ref` 에 해당하는 비밀은 지우지 않는다(ref 를 주지 않는 옛 릴레이면 소비분 삭제를 통째로 미룬다; 발행은 계속) — 탭이 닫힌 동안 온 초대가 첫 refresh 에서 거부된 뒤 비밀이 지워져
영구 「초대 대기」가 되던 결함(#517). 「초대」는 방별 키 패키지 → 없으면 상대의 로비 키를 그 방으로 소비한다(iOS RoomMembership 과 동일).
「멤버」 시트와 방 머리글의 「멤버 N」은 **사람 단위**다(2026-10-28 오너, `strings.js participantCount·groupParticipants`): 같은 사람의
PC·폰이 두 명으로 서지 않고 사람 행 아래에 기기 줄(종류 · ID · 「이 기기」 · 제거)이 붙는다. MLS 좌석·릴레이 명단·초대·제거는 그대로 기기 단위.
1차(방 1개) 설치는 첫 실행에서 기본 방 DB 의 서명키가 신원 스토어로 **이전**되므로 재등록이 필요 없다.

## 새 기기 셀프서비스 (#574 PR 2b — 릴레이 PR #578 의 `/v2/devices/*` · `/v2/me`)

운영자 없이 **내 기기가 내 새 기기를 승인**한다. 순수 판정은 `self-service.js`, 릴레이 호출은 `device.js`(`postCandidate` ·
`listCandidates` · `postApproval` · `postRoles` · `signRoles`), 화면 흐름은 `app.js`.

- **새 기기**(403 경로, `app.js enrollTick`): 8초 틱마다 `GET /v2/me` 를 보고, 체인에 없으면 `POST /v2/devices/candidates`
  `{device_id, actor, signing_key, fingerprint}`(subject 없음 — 릴레이가 JWT 에서 묶는다). 201 이면 등록 화면이 **sibling 모드**
  (큰 지문 + 「다른 기기에서 승인해 주세요」, 운영자 JSON 은 접힌 보조 경로), TTL 10분 중 5분 전에 다시 올린다. 409 `device_exists`
  → **id-taken** 모드(지우고 새 ID). 403 `first_device_out_of_band`(첫 기기)·404(옛 릴레이·접근 인증 꺼짐) → 기존 **operator** 모드,
  404 는 다시 묻지 않는다. `/v2/me` 의 내 기록이 `active` 가 되면 같은 틱에 방 목록을 다시 받아 대화 화면으로 넘어간다.
- **승인하는 기기**(`discoverCandidates`): 이 기기가 승인할 수 있을 때만(`canApprove` = 활성이고, registrar 이거나 같은 actor 에
  활성 registrar 가 없음 — 서버 `VerifyApproval` 과 같은 규칙) 틱마다 `GET /v2/devices/candidates` 를 보고 **내 actor 의 후보**를
  목록 위 「새 기기 승인」 카드와 🔔 에 띄운다(기기 이름·ID·지문·만료). 「지문 비교 후 승인」 → `policy_fingerprint` 로 지문을
  **로컬에서 다시 계산**해 릴레이가 전한 값과 다르면 거부 → 「신뢰 기기 승인」 시트의 비교 단계(relay 모드) → 「이 지문이 맞습니다」
  → `sign_approval`(base_revision = 목록의 `policy_revision`) → `POST /v2/devices/approvals`. 409 `stale_revision` 이면 응답의
  `revision` 으로 한 번 다시 서명, 403 `approval_rejected` 는 `detail` 을 카드에 보인다. 「무시」는 이 페이지 세션에서만 숨긴다.
- **형제 기기 자동 초대·수락**: 승인 직후 내가 참여한 방(정지·대기 commit·이미 멤버인 방 제외, `siblingInviteRooms`)을
  localStorage `hande:sibling-invites:<device>` 에 적고 매 refresh 끝에 `room.js invite()` 를 시도한다 — 새 기기는 활성이 된
  다음 틱에야 로비 키를 올리므로 처음엔 「키 패키지 없음」으로 실패하고 다음 틱에 다시 한다(내 commit 대기·방이 먼저 바뀜·네트워크도
  재시도). 30분이 지나면 포기하고 🔔 에 안내를 남긴다. 새 기기 쪽은 Welcome 의 `from` 이 **형제**(같은 actor 의 활성 체인 기록,
  `isSibling`)면 오너 기기처럼 **자동 수락**한다 — 가족 기기도 자기 기기가 보낸 초대는 묻지 않는다.
- **「내 기기」 시트**(⚙ 메뉴·설정, `/v2/me` 에 `devices` 가 있을 때만): 같은 subject 의 체인 기록 전부(활성/폐기·등록 기기 배지·지문).
  「등록 기기로 지정」/「지정 해제」 = `sign_roles` `{device_id, actor, roles(완전한 정렬 목록), base_revision}` →
  `POST /v2/devices/roles`(409 는 `/v2/me` 다시 읽고 한 번 재서명). 버튼 활성 규칙은 `rolesActions` = 서버 `VerifyRoles`:
  대상은 활성·같은 actor, 마지막 활성 registrar 는 해제 불가(다른 기기에 먼저 지정). **런타임에 Rust 파사드의 `sign_roles` 와
  durable-worker 허용 목록이 필요하다**(별도 PR) — 없으면 「서명을 만들지 못했습니다: sign_roles 거부…」로 보인다.
- 붙여넣기 승인 시트(운영자 흐름)는 그대로이되 등록 JSON 의 `base_revision` 이 없으면 `/v2/me` 의 `policy_revision` 을 쓴다.
  `room.js` 에 남아 있던 방별 `offerCandidate/approveCandidate/denyCandidate` 복제본은 지웠다(신원 스토어 경로만 산다).

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
- 행: 이름 옆 **N 배지**(안 읽은 방, 보조기기에는 "새 메시지" — 판정은 iOS 와 같은 readSeq: 마지막 글이 남의 글이고 이 기기가 본 seq 보다
  뒤일 때만. 본 위치는 localStorage `hande:readSeq:<device>:<room>` 라 새로고침 뒤 보관 이력이 다시 들어와도 배지가 켜지지 않는다, #541.
  **같은 사람의 다른 기기에서 읽은 것도 읽은 것**(#571 B): 방을 보면 `POST /v2/rooms/{room}/read {device, seq}` 로 릴레이에 알리고(`room.js markRead`,
  새 seq 마다 1회, 응답 무시, 옛 릴레이 404 포함), 4초 폴링 `GET /events` 의 `read_seq`(릴레이가 actor 단위로 보관하는 최댓값)가 이 기기 값보다 크면
  `app.js mergeRelayRead` 가 localStorage 값을 올려 배지를 끈다 — PC 에서 읽으면 폰의 N 배지도 다음 폴링에 꺼진다), 상대 시각(방금/N분 전/N시간 전/어제/M.D.), 미리보기는
  마크다운 기호를 걷어낸 한 줄 — 첨부는 `[사진]`(내용 판별) / `[파일]`.

## 작성창 (#480 B)

- 초안은 방별로 보존되고(패밀리챗과 같음) 이 기기 localStorage `hande:draft:<device>:<room>` 에도 남아 새로고침·재시작 뒤
  돌아온다(보내면 지움, 2만 자 상한). 「이 기기 지우기」가 `hande:*` 키를 지우므로 함께 사라진다.
- 붙여넣기(클립보드 파일, 스크린샷)·방 화면에 끌어다 놓기 → 첨부 전송(이미지 우선, 한 번에 하나, 5 MiB 한도는 기존 그대로).
  글자만 있는 붙여넣기·글자 선택 끌기는 브라우저 기본 동작.

## 「내 마지막 말」 바 (#480 C — 패밀리챗 #300 과 동일)

헤더 아래에 내 최근 말·답장 수·시각. 기본 접힘(방별 localStorage `hande:lastSent:collapsed:<room>`, 펼친 방만 `'0'`).
접힘에서 바를 누르면 펼치고, 펼친 뒤 누르면 그 말풍선으로 스크롤해 잠깐 밝힌다. 펼치면 오늘 내 말 목록(최대 50).
기준은 화면 타임라인(로컬 봉인 보관 ≤500건)뿐 — 패밀리챗의 서버 sender 인덱스는 한데 릴레이에 없다.

## 복귀 동기화 · 첨부 행 (#544 A·B·C — 패밀리챗 `web/app` 과 동일)

- **탭·온라인·bfcache 복귀 즉시 동기화(A)**: `sync-recovery.js` 가 `visibilitychange`(보이게 될 때만)·`online`·`pageshow` 에서
  ⚙ 「지금 동기화」와 같은 경로(기기 refresh → 방별 `sync({quiet})`)를 1회 부른다(1초 디바운스 — 탭 전환은 두 이벤트가 겹친다).
  백그라운드 탭에서 브라우저가 늦춘 4초/8초 타이머를 기다리지 않는다. `refreshing`·`S.busy` 가드로 폴링과 겹쳐도 안전.
- **미리보기 실패 시 「미리보기 다시 시도」(B)**: `preview-loader.js` — 첨부 본체를 받지 못하면(file-v2 blob 다운로드 실패 등)
  예전처럼 조용히 「파일」 행으로 남기지 않고 `entry.previewFailed` 로 표시해 말풍선에 안내 + 버튼을 둔다. 버튼은 같은 `load()` 를
  다시 부른다(file-v2 는 실패한 load 의 캐시를 비워 다시 받는다). 사진이 아닌 파일(내용 판별 null)은 실패가 아니다.
- **파일명(C)**: 파일 행은 이름이 있으면 「📎 이름 · 크기」. 이름은 **file-v2 수신분**(#499/#511, `safeFileName` 으로 줄인 것)에만 있다 —
  file-v1(현재 기본 송신, MLS 안에 바이트 직접)은 와이어에 이름이 없어 지금처럼 「📎 파일 · 크기」.

## 보관함 pane — 「첨부」 탭 + 파일보관함 (#544 D — 패밀리챗 `web/app` 과 동일)

헤더 🗂 로 여는 오른쪽 pane(좁은 화면에선 목록/대화 자리, 1280px 부터 세 번째 열). 탭 2개:
- **첨부**(항상): `attachments.js` `collectAttachments` — 모든 방의 화면 타임라인에서 첨부를 모아 최신순(시각 내림차순, 같은 시각은 seq
  내림차순). 행 = 🖼/📎 + 이름(file-v2 파일명, 없으면 `[사진]`/`[파일]`) + 「방 · 보낸 사람 · 시각 · 크기」. 행을 누르면 그 방을 열고
  그 말풍선으로 스크롤·강조(`jumpToEntry`, paint 뒤 `pendingJump`), 「다운로드」는 같은 `entry.load()`. **범위**: 이 브라우저에 보관된
  대화(방별 봉인 보관 ≤500건)에서 보이는 첨부뿐 — 릴레이에 첨부 인덱스가 없다(패밀리챗의 서버 인덱스에 해당하는 것 없음).
- **파일보관함**(config.json `filebox` 가 있을 때만): 기존 iframe(#462). 이 탭이 보일 때는 pane 서명에서 첨부 목록을 빼 새 첨부가
  와도 iframe 을 다시 로드하지 않는다.

## AI 참여 동의 (#544 E — 선택지 3, 오너 결정 2026-10-28)

패밀리챗은 초대 카드에서 「이해했으며 동의합니다」 체크 전 수락을 막는다(README "AI 초대 시 범위를 알리고 동의받는 것이 제품 요구").
한데는 **수락 전에 방 명단을 알 수 없다**(`GET /v2/lobby/welcomes`·`GET /v2/rooms` 에 roster 없음, 오너 actor 는 자동 참여) — 그래서
참여는 그대로 두고 **참여 뒤** 판정한다(`agent-consent.js`):
- 방 명단(`S.roster`)에 에이전트 기기(`isAgentDevice` — 서비스 봇 `card`/`fleet` 는 제외)가 있고 이 기기의 동의 기록이 없으면
  **방을 처음 열 때** 동의 시트(안내 + AI 참여자 이름 + 체크 → 「동의하고 대화하기」 / 「나중에」). 페이지 세션에서 방마다 한 번만 자동으로 뜬다.
- 동의 전에는 **작성창·첨부·붙여넣기·끌어다 놓기가 잠기고** 작성창 위 게이트(「안내 보기」)가 시트를 다시 연다. 읽기·내려받기는 그대로.
  명단에 에이전트가 **나중에** 들어와도 다음 paint 에서 같은 게이트가 선다.
- 기록은 이 기기 localStorage `hande:agent-consent:<device>:<room>`(값 `1`) — 「이 기기 지우기」(`hande:*`)로 함께 사라진다. 서버 변경 없음.

## 로컬 전용 방 「이 기기에서 지우기」 (2026-10-28 오너 요청)

「방 만들기」로 만들었거나 「참여 요청」만 한 방은 **릴레이에 없다**(릴레이에는 첫 초대 때 생긴다) — 이 기기만의 방이라 다른 기기와 무관하다.
그런 방(`GET /v2/rooms` 의 멤버 집합 `app.relayRooms` 에 없는 방, `local-room.js isLocalOnlyRoom`)을 열고 「멤버」 시트 맨 아래 **「이 기기에서 지우기」**
→ 확인 → 워커 방 스토어 `reset_room`·`close_room` → 이 방의 localStorage 키(상태·초안·readSeq·동의·내 마지막 말·첨부 보관함, `forgetRoomKeys`)·알려진 방 목록·순서
→ IndexedDB `family-mls-synthetic-hande-<room>`(+`-history`, 최선 노력) → 목록에서 사라진다. 릴레이가 멤버로 아는 방에는 버튼이 없다(지워도 다음 refresh 에 다시 열린다 —
명단에서 빠지는 건 「제거」·재초대의 일). 기본 방(`family`)도 릴레이에 없으면 지울 수 있지만 알려진 목록이 비면 다음 시작에 다시 열린다.

## 서비스 워커 (#480 D)

`main.js` 가 `sw.js` 를 모듈 워커로 등록한다(PC 크롬). 정책(`sw-policy.js`): **같은 origin 은 전부 네트워크 우선**, 캐시는
오프라인 폴백(탐색 요청은 캐시된 `index.html`)뿐 — 한데는 해시 없는 파일을 제자리 교체로 배포하므로 캐시 우선이면
핫픽스가 기기에 갇힌다. `/v2/*`(릴레이 API)와 다른 origin 은 가로채지 않는다. 설치 때 셸(`SHELL_ASSETS`)을 프리캐시하고
`skipWaiting`·`clients.claim` 으로 바로 넘어간다. 푸시 없음. 배포 뒤 새 코드는 다음 새로고침에서 네트워크로 바로 온다
(캐시는 응답 사본만 갱신).

## 검증

- 순수 모듈: `node --test archive/native-mls/web/hande/tests/*.test.mjs` — 방 세션(가짜 워커·대본 릴레이: 403
  대기, Welcome 참여, 해독→보관→ack, 전송 CAS 재시도, 초대 commit→echo→Welcome, 거부·제거 정지, #296 복구),
  문구·검증 헬퍼, 키보드 판정(`keyboard.test.mjs`), 목록 순서(`room-order.test.mjs`), 초안·첨부 파일 고르기(`drafts.test.mjs`·`composer-files.test.mjs`), 내 마지막 말(`last-sent.test.mjs`), 안 읽음 판정(`read-seq.test.mjs`), 복귀 동기화(`sync-recovery.test.mjs`), 미리보기 다시 시도(`preview-loader.test.mjs`), 보관함 첨부 목록(`attachments.test.mjs`), AI 참여 동의(`agent-consent.test.mjs`), 로컬 전용 방 지우기(`local-room.test.mjs`), 서비스 워커 정책(`sw-policy.test.mjs`),
  기기 셀프서비스 판정(`self-service.test.mjs`)·기기 셀프서비스 릴레이 호출과 `sign_roles` 프레임(`device.test.mjs`)·`/v2/me` 본문(`relay.test.mjs`).
- 브라우저: `archive/native-mls/tests/native_hande_web_smoke.py --bundle <mls-pkg> --relay-binary <relay>` —
  격리 릴레이(`-access-mode disabled`, `-hande-host`)가 이 디렉터리를 서빙하고 두 Chromium 컨텍스트가 **화면만
  으로** 이름 선택 → 방 만들기 → 참여 요청 → 초대 → 참여 → 양방향 메시지 → 새로고침 뒤 보관 이력 복원, 이어서 둘째 방을
  **로비 키로** 초대(가족 기기: 초대 카드 수락 / 오너 기기: 자동 참여)하고 두 방이 서로 섞이지 않음, 그리고
  키보드(PageDown/PageUp 방 전환·Esc/Enter 포커스·Home 목록)를 거친다. 끝으로 창을 낮춰 목록에 스크롤을 만들고
  동기화 줄이 두 번 바뀌는 동안 목록 pane·스크롤 위치·헤더 버튼 포커스가 그대로인지 본다(#502/#507 회귀).
- Go: `hande_test.go`(호스트 라우팅·가둠·헤더), `me_test.go`.

## 증명하지 않는 것

실제 CF Access 엣지 경유(합성 릴레이는 JWT 없음) · 푸시 알림(webpush 게이트웨이 없음) · 기기 간 이력 이전 · 모바일 브라우저 ·
오너 두 기기의 실사용(인수검사 #243 계열은 사람이 한다).
