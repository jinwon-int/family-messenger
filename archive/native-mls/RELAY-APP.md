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
  history-store.js(#370, durable-worker 가 import)  relay-attachments.js  commit-policy.js(relay-app 이 import)
  pkg/family_mls_browser_experiment.js  pkg/family_mls_browser_experiment_bg.wasm  pkg/custody.js
                                                                                  ← build.sh 번들(bundle-sha256.txt 일치본)
```

## 흐름 (페이지가 하는 일 = 스모크 `Device.sync`)

1. **워커 시작**: 기기 ID(`[A-Za-z0-9_-]`, 예 `owner-pc`·`owner-iphone`·`bot-1` — 첫 `-` 앞이 **actor**),
   방(`[a-z0-9-]`), DB(`family-mls-synthetic-…`), 암호 32자+. 모바일에선 암호 키 유도(scrypt logN 18)에
   1~3분(#246; 모바일은 그동안 앱 전환 금지). 재시작은 같은 DB·암호. **등록 순서는 403 → 등록 → 수락**이다:
   체인에 없는 기기는 릴레이가 403 `device_subject_mismatch`를 돌려주고, 화면 상태줄에
   "릴레이가 이 기기를 받지 않는다(403 device_subject_mismatch) — 운영자 등록 대기 → 아래 '운영자 등록
   정보'를 펼쳐 JSON을 운영자에게 전달"이 뜨며 §1의 "운영자 등록 정보"가 자동으로 펼쳐진다. 그
   JSON(device_id·actor·signing_key·지문)을 운영자가 `native-devices -enroll-first`(첫 기기) /
   `-add-device`(둘째 기기, §4)로 체인에 올리면 다음 폴링(4초)부터 200으로 수락되어 상태줄의 403 문구가
   사라진다 — 재시작은 필요 없다.
   상태줄에는 마지막 동기화 시각(`동기화 HH:MM:SS`)이 따라붙고, fetch 자체가 실패하면(릴레이 다운·터널
   끊김·Access 쿠키 만료) `연결 끊김 (HH:MM)` 한 줄이 추가됐다가 다음 성공 시 지워진다. 버튼 동작이 그
   상태에서 실패하면 "연결 실패 — 페이지를 새로고침하고(필요하면 Cloudflare Access 로그인) 같은 암호로
   워커 시작 후 다시 시도"를 알림으로 보여 주고, `보내기`의 입력창 내용은 비우지 않는다(#251).
2. **방**: 첫 기기 `방 만들기`(로컬 그룹 생성). 다른 기기는 `키 패키지 게시`(릴레이 `/keypackages`,
   ref = sha256). 초대하는 쪽이 `초대`: 상대 패키지 소비 → `invite_with_commit` → **commit POST**
   (members = `members_after_pending`, actor = ID 접두) → 201이면 pending → 다음 동기화에서 **내 echo를
   만나야 `merge_pending`** → 그제야 **타깃 Welcome POST**. 409 `cas_mismatch`면 `clear_pending` 후 동기화·재시도.
3. **동기화**(4초 폴링 + 버튼): `GET /events?after=` → 내 commit echo(merge) / Welcome(참여 전) →
   `join` / 타인 commit → **`stage_commit` → 검사 → `merge_staged`**(#261, 아래) / application →
   `decrypt`(워커가 방 바인딩) → 표시(발신 기기·client).
   타인 commit 검사(`web/commit-policy.js`, 순수 함수 — `node --test web/commit-policy.test.mjs`): stage
   보고서(adds ‖ removes ‖ update 제안 ‖ 커미터 path)에서 ① 커미터 path leaf가 정확히 1개이고 그 신원이
   릴레이 행의 `device`(JWT에 묶인 게시자)와 같다 ② 커미터가 현재 멤버다 ③ removes ⊆ 현재 멤버, adds ∩
   현재 멤버 = ∅, 중복·겹침 없음, update 제안 0 ④ 그 commit이 응답의 최신 epoch(`ev.epoch + 1 == epoch`)
   이면 `현재 멤버 − removes + adds` == 릴레이 `members`(같은 트랜잭션의 추적 로스터, outer == inner).
   통과 → `merge_staged`(stage+merge가 한 번의 durable step). 위반 → `discard_staged`(epoch 그대로) +
   **⛔ 정지**: 상태줄·메시지 영역·로그에 이유, 폴링 중단·보내기 비활성, localStorage에 남아 새로고침
   뒤에도 유지 — 운영자가 재초대/재등록하거나 커미터·릴레이를 조사한다. 무음으로 넘어가지 않는다.
   stage는 **transient**다(워커 ledger·IDB에 아무것도 남기지 않음): 탭 전환·재시작으로 워커 세션이
   재구성되면 stage가 사라지므로 merge 실패 시 같은 seq를 한 번 다시 가져와 재시도한다.
   참여 뒤에는 처리한 seq까지 `?ack=`(읽기는 커서를 안 움직인다, M2). `first_seq`가 내 커서보다 앞서면
   잘린 역사 경고.
4. **둘째 기기 승인(E2)**: 신뢰 기기 화면에 새 기기의 등록 정보 JSON(+ `subject`, `base_revision`)을 붙여
   넣고 `지문 보기`(`policy_fingerprint`) → 두 화면 지문을 사람이 비교 → `이 지문이 맞습니다` →
   `sign_approval`(durable 신원의 키로 서명) → 증거 JSON(signature 포함)을 운영자에게 → `-add-device -input`.
5. **저장소 삭제**: 축출 재연습. 재시작하면 새 기기(새 지문)이고 정책 체인은 같은 ID를 다시 받지 않으므로 **기기 ID를
   새 이름으로**(화면이 `owner-pc` → `owner-pc-2`처럼 채워 둔다, #290) → 운영자가 옛 ID revoke + 새 ID 등록(E2) → 상대 재초대.
   화면 상태는 `relay-app:<room>:<device>:<db>`에 저장되며(#296; 옛 `room:device` 키는 1회 이전), 이어하기 때 워커가 그룹을
   들고 있는데 상태가 없으면 릴레이의 ack 커서부터 참여 상태를 복구한다("참여 상태 복구" 로그).
6. **멤버 제거(#289)**: 운영자의 `-revoke`는 정책 체인만 바꾸고 MLS leaf는 남는다. 신뢰 기기가 `제거할 기기` ID로
   `멤버 제거` → `remove_pending`(그 멤버의 서명 키로 지정, 맨 commit) → commit POST(members =
   `members_after_pending`) → 내 echo에서 `merge_pending` → epoch 전진. 제거된 기기가 아직 살아 있으면 그
   commit을 stage→검사→merge한 뒤 "이 기기는 방에서 제거되었다"로 **정지**(⛔ 거부와 같은 durable 정지, 문구만
   다름; `저장소 삭제`만 활성). 나를 제거하는 commit도 **outer 로스터와 비교한다**(#295): 릴레이는 GET 응답마다
   추적 로스터를 싣는다(`store.go` `readMembers` → `members`, 독자가 멤버인지와 무관). 비교를 생략하는 경우는
   릴레이가 멤버십을 아예 추적하지 않아 `members`가 `[]`일 때뿐이다 — `-device-state` 없이 뜬 스모크 릴레이
   (`enforceDevicePolicy`가 nil → `active == nil` → 추적 안 함). #294 는 이것을 "비멤버에게 로스터를 안 보여 준다"로
   잘못 진단해 운영 릴레이에서도 생략했었다(판정 `commit-policy.js` `outerForCommit`, `node --test`). 운영 모드
   (`-device-state`, 멤버십 강제)의 릴레이는 제거된 기기의 application/ack를 403 `not_a_member`로 거부한다(Go 테스트로
   증명; 스모크 범위 밖).
   **제거 권한(#295 F3)**: 추적 멤버이면서 정책상 active인 기기는 누구나(봇 포함) 살아 있는 다른 active 기기도
   제거할 수 있다 — 대상이 revoked인지 확인하는 장치는 클라이언트·릴레이 어디에도 없다. 운영 절차("운영자 revoke 뒤
   신뢰 기기에서 제거")가 유일한 제한이다.
   **결과 불명 게시(#295 F4)**: 초대·제거 commit POST가 예외로 끝나면(네트워크 끊김·응답 유실) commit을 "결과 불명
   pending"으로 남긴다(저장됨). 다음 동기화에서 내 echo가 오면 `merge_pending`, 다른 commit이 먼저면 그 병합이 내
   pending을 소모하므로 상태만 정리, 방 epoch가 그대로면 릴레이에 없던 것이라 `clear_pending`(`resolveUncertainPending`).
7. **입력 중 표시(#562, 한데 웹)**: 작성창에 글이 있으면 `POST /v2/rooms/{room}/typing` `{device, clear:false}`를
   3초에 한 번(`room.js typing()`, 릴레이 TTL 6초), 비우면 `clear:true`. 응답은 모두 무시한다(옛 릴레이의 404 포함,
   fire-and-forget) — 메시지가 저장되면 릴레이가 그 기기의 신호를 스스로 지우므로 전송 뒤 해제 요청은 없다. 같은
   4초 폴링의 `GET /events`가 `typing: [기기…]`(나를 뺀 미만료 기기, 키가 없으면 `[]`)를 실어 오고, 화면은 내 다른
   기기를 빼고 사람 단위로 묶어 방 머리글에 「{이름} 입력중…」(1:1 방은 「입력중…」)을 보인다. 별도 틱 없음, 저장 없음.
8. **읽음 위치 공유(#571 B, 한데 웹)**: 방을 보고 있으면(열기·보는 중 새 글·전송 뒤) `POST /v2/rooms/{room}/read`
   `{device, seq}`를 새 seq 마다 1회 보낸다(`room.js markRead()`, 릴레이가 이미 그 이상을 알면 생략). 응답은 200의
   `read_seq`로 상태만 올리고 나머지는 무시한다(옛 릴레이 404 포함, fire-and-forget). 릴레이는 값을 **actor 단위**로
   보관하므로 같은 4초 폴링 `GET /events`의 `read_seq`(키가 없으면 0)가 이 기기 값보다 크면 `app.js mergeRelayRead`가
   localStorage `hande:readSeq:<device>:<room>`를 올린다 — PC 에서 읽은 방의 N 배지가 폰에서도 다음 폴링에 꺼진다.
   MLS 좌석·커서(`mls_cursors`, 전달 ack)는 그대로 기기 단위다. Android(한데)는 같은 규칙을 Rust 코어로 쓴다
   (`host-core api::Client::post_read` · `EventsResponse.read_seq` → `MlsRoom.markRead(seq)`/`readSeq()`, #571 후속);
   iOS 는 아직 로컬 readSeq 만 쓴다(후속).

durable 워커 허용 메서드에 이번에 더해진 것: `invite_with_commit` `merge_pending` `clear_pending`
`remove_pending` `members` `members_after_pending` `fingerprint` `policy_fingerprint` `sign_approval`
(파사드 `Session.dispatch`에 읽기 전용/서명 arm 추가; store 변경 0). #261로 더해진 것: `stage_commit`
`merge_staged` `discard_staged` — durable lane에서 stage는 handshake 래칫 소비를 in-flight로 들고 있고
`commit()`을 거부한다(맨 stage는 영속 불가); `merge_staged`가 stage+merge를 한 step으로 영속하고,
`discard_staged`는 durable 기준선으로 롤백해 같은 릴레이 이벤트를 다시 stage할 수 있다(PERSISTENCE.md M1).

## 검증

### 첨부 (#256)

> 분리 첨부 **file-v2**(파일은 blob 저장소, MLS에는 설명자만 — #499)는 [FILE-V2.md](FILE-V2.md)가 정본이다. 아래는 v1(`file-v1-`) 형식이며 수신은 계속 유지된다.

파일 선택 후 **첨부 보내기**로 0~5,242,880바이트(5 MiB)를 단일 MLS application 메시지에 담는다.
원본 바이트를 그대로 암호화해 **5 MiB** 상한(#364, 2026-10-15 이전 256 KiB)을 전부 쓴다. 파일명·MIME 메타데이터나 별도 봉투를
추가하지 않는다. 수신 화면에서는 생성된 `attachment-<seq>.bin` 이름으로 다운로드한다.
`client_id`의 `file-v1-` 접두는 릴레이가 보는 **표시 힌트**이며 MLS 인증 정보가 아니다.
발신자 표시는 복호화 결과의 인증된 발신자를 사용한다. 다운로드는 항상 `application/octet-stream`이고
파일 본문을 HTML로 삽입하거나 미리보기로 실행하지 않는다.

POST 전에 DB/방/기기별 outbox에 **암호문·전송 ID·epoch·크기만** 저장한다. 응답이 끊기면 입력을
보존하고 **같은 첨부 다시 보내기**로 동일 바이트·동일 client_id를 재전송한다. 페이지 재시작 후에도
같은 DB/기기로 이어하기하면 재시도할 수 있다. 릴레이의 200 duplicate를 성공으로 처리한다.
명시적 epoch CAS 거부는 릴레이가 저장하지 않았다는 증거이므로 outbox를 지우고 동기화 후 다시 보낸다.
불확실한 실패에서 새 ID를 발급하거나 재암호화하지 않는다. 받은 첨부는 아래 「로컬 이력」으로 봉인 보관돼
새로고침 뒤에도 다운로드할 수 있다(보낸 첨부는 화면에 그리지 않는다). 원래 파일명·미리보기·청킹은 지원하지 않는다.

순수 outbox 시험은 `node --test web/relay-attachments.test.mjs`, 브라우저 합성 스모크는 아래 명령이다.
합성 왕복은 오너 두 기기의 실사용 증거를 대체하지 않는다. 그 인수검사는 #256에서 계속 추적한다.

- `archive/native-mls/tests/native_relay_app_smoke.py --bundle … --relay-binary …`: 두 Chromium 컨텍스트가
  이 페이지만으로(파이썬 측 릴레이 호출 0) 생성 → 키 패키지 → 초대(commit 201 → echo merge → Welcome) →
  참여 → 양방향 메시지(발신자 표시) → 릴레이 커서 ack → **릴레이 중단**(상태줄 `연결 끊김`, `보내기`가
  "연결 실패" 알림 + 입력 보존) → 같은 포트·데이터 디렉터리로 재시작 → 같은 입력 재전송 성공 → 재시작 시
  틀린 암호 거부 → 맞는 암호로 이어하기(지문 복원, 이전 행 없이 "다시 표시되지 않는다" 자리표시만, #258). 릴레이는 `-access-mode disabled`(loopback, 정책 체인 없음). 수신증
  `archive/artifacts/native-relay-app-*/`.
- Go: `TestStaticClientServing`(헤더·점 파일·traversal·메서드·`/v2` 불변), `TestStaticRootRequiresIndex`.
- 파사드: `durable_lane_roster_fingerprint_and_sign_approval`.

## 증명하지 않는 것

- 들어오는 commit의 검사(§흐름 3, #261)는 **릴레이와 커미터가 함께 속이는 경우**(outer == inner를 둘 다
  위조)를 잡지 못한다 — 그것은 정책 체인(E2 승인·M3b 강제)의 몫이다. 또 검사는 신원(기기 ID) 수준이다:
  같은 ID로 서명 키가 바뀌는 커미터 path 회전은 보고만 되고(섹션 4) 키 핀 비교는 하지 않는다.
  봇(`bot/src/session.rs`)도 같은 규칙으로 stage→검사→merge 한다(#263, `bot/src/policy.rs`; 위반 시
  `commit_refused` + 상태 파일 옆 `.refused` 마커로 재시작 뒤에도 정지). 두 구현은
  `tests/fixtures/commit-policy-vectors.json`을 함께 돌린다.
- **이력 gap(#268)**: 릴레이 GET의 `first_seq`(#242)가 참여한 봇의 커서+1보다 크면, 봇이 읽지 못한 seq가
  이미 지워진 것이다. 이는 커서가 프루닝 게이트에서 빠졌거나(revoke·제거 grace) commit이 hard max epoch 창을
  넘긴 경우다. 봇은 그 페이지를 **처리하지 않고** `history_gap` 이벤트(after·first_seq·missing_from/to)를 낸다.
  그다음 같은 `.refused` 마커(`reason: "history_gap"`)로 방을 정지한다. 재시작해도 `halted`(reason 포함) 상태로
  남고, 운영자가 마커를 지우고 기기를 다시 추가해야(새 Welcome) 복구된다. 지운 이력을 조용히 건너뛰거나 다음
  epoch 복호화 실패를 반복하지 않는다. 한계: `first_seq`는 가장 오래된 보존 seq만 알려 준다. 그래서 그 위의
  중간 구멍(hard max로 commit만 지워진 경우)은 이 신호로 잡히지 않고, 그때는 `rejected`/`undecryptable`로
  드러난다. 기본 보존 정책(앱 30일 ∧ MIN 커서, commit keep 8 / hard 256 epoch)에서는 커서가 기록된 오프라인
  봇에게 이 경로가 열리지 않는다.
- 제거(remove_pending)·방 닫기 UI 없음(운영자 CLI/릴레이 도구). 첨부는 위의 5 MiB 단일 메시지만 지원(#364).
- **로컬 이력(#370, B안)**: 받은 메시지·첨부와 보낸 텍스트를 이 브라우저의 별도 IndexedDB
  `<DB>-history`(스토어 `rows`·`blobs`, 키 = relay seq)에 **봉인 보관**한다 — MLS 저장소와 같은 custody 키,
  AD `family-mls-aux-history-v1/<row|blob>\0기기\0방\0seq`(다른 seq·방·기기로 옮기면 열리지 않음). MLS 저장소의
  스키마(v2, `meta`+`entries`)는 그대로다. 순서: 복호화 → 화면 → `history_put` 완료 → ledger ack(그 사이에 죽으면
  그 1건만 기록에서 빠진다 — MLS 는 같은 메시지를 두 번 풀 수 없다). 이어하기 때 최근 500행을 먼저 그리고(첨부는
  다운로드를 누를 때 `history_get`) 자리표시에 보관 건수를 알린다. 상한 2,000행·200 MiB(오래된 seq부터 삭제).
  「저장소 삭제」는 history DB 도 지운다. 릴레이는 여전히 평문을 보관하지 않고, 다른 기기는 과거를 볼 수 없다(MLS).
  history DB 를 열지 못하면(보관 꺼짐) 동기화는 그대로이고 이어하기 안내는 #258 문구다.
- Access 쿠키 만료(730h) 뒤의 재로그인 UX: 401이면 "새로고침해 로그인" 안내만. Access 로그인 페이지로의
  리다이렉트가 CORS/opaque로 끝나 fetch 자체가 실패하는 경우도 같은 "연결 실패" 안내로 합쳐진다 —
  원인(릴레이 다운 vs 쿠키 만료)은 구분하지 않는다.
- 403 → 등록 → 수락 전환은 스모크에 없다(릴레이가 `-access-mode disabled`라 403 경로가 안 나온다);
  문구·details 자동 펼침은 코드 검토와 실기기 세션으로 확인한다.


Attachment sends require the browser Web Locks API. Tabs sharing an outbox key
acquire an exclusive lock before re-reading, encrypting, posting or removing its
record. An already open tab never replaces an uncertain delivery. If another tab
changes or confirms its pending record, a stale retry stops and asks the user to
reopen the page; a newly selected file is not silently replaced by the other tab's
file. Browsers without Web Locks refuse sending.
