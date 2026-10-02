# 네이티브 기기 정책 v4 — 계약 (#177 §3.1·§3.2, M3a+M3b)

**상태:** 구현됨 (M3a 정책 체인·CLI, M3b 릴레이 강제). 이 문서는 `archive/native-mls/server`의
정책 체인, 오너 CLI와 릴레이가 무엇을 보장하고 무엇을 증명하지 않는지 묶는다.
**M3c**(지문 비교 UI, 클라이언트의 정책 등록 연동, v2 릴레이 smoke의 등록 전환)는 별도 PR이다.
서버는 아래 다섯 연산을 위해 **라우트를 추가하지 않는다**(#177 §3.2).

## 파일과 저장 커널

한 릴레이 데이터 디렉터리에 정책 체인 하나:

```
<device-state>/policy-%06d.json   불변 레코드 {revision, previous_sha256, policy_sha256, policy}
<device-state>/lock               0바이트 flock 앵커 (디렉터리 내용 아님)
<device-state>/pending-<hex>      쓰기 불확정 잔재 — 존재하면 읽기 fail-closed
```

- 디렉터리: 절대경로, 0700, 소유자=euid, 경로 구성요소에 symlink 금지.
- 파일: 0600, 정규 파일, nlink=1, `O_NOFOLLOW`. 쓰기 경로는 pending 생성 → fsync →
  close → 대상 부재 확인 → `renameat` → 디렉터리 fsync (v1 `server/internal/access`
  정책 저장소와 같은 커널; 의존성 없이 미러링 — 결정 E 규칙 1).
- 체인 링크 = 직전 레코드 **원본 파일 바이트**의 sha256. 최대 64 revision — 컴팩션은
  미구현이고 소진 시 `ErrDevicePolicyState`로 멈춘다(상태 보존).
- 디코더는 엄격(K6): unknown·duplicate·null 필드 거부, `version`은 4만.

## v4 스키마

v1 `devices` 배열과의 차이는 #177 §3.1의 그것 하나: **actor당 기기 N개(활성 상한 4)
+ `approved_by` 증거 객체**. v2/v3(successor·activation)는 폐기된다.

| 필드 | 값 |
|---|---|
| `device_id` | 식별자, 전역 유일, 재사용 금지(tombstone 영구) |
| `actor` | 사람 또는 봇 식별자 |
| `subject` | **필수.** CF Access 호출자 아이덴티티(`[A-Za-z0-9_.@-]{1,128}` — `devicepolicy.IsSubject`; 사람 `sub`와 서비스 토큰 `common_name`(Client-Id, `<id>.access` 형태)을 모두 담을 문자셋). 릴레이가 이 기기로 행동하는 모든 요청의 클레임 아이덴티티를 여기에 묶는다(아래 "릴레이 호출자 인증"). `-enroll-first`/`-add-device` 후보 JSON에 없으면 CLI가 이름을 대고 거부한다 |
| `signing_key` | Ed25519 공개 키 32바이트 lowercase hex |
| `fingerprint` | sha256(signing_key 원본 바이트) — 사람이 대역외로 비교하는 값 |
| `status` | `active`(\|`device_revision`=1) 또는 `revoked`(=2). 되돌리기 없음 |
| `acceptance` | `out-of-band-fingerprint`(E1) 또는 `trusted-device-fingerprint`(E2) |
| `approved_by` | 최대 1회: `{device_id, revision}` — 승인 기기 + 그 승인이 허가한 revision |

불변식(전부 체인 재생 시 강제): 총 ≤32기기, actor당 active ≤4, id·키 전역 유일,
fingerprint=key 해시 일치, `trusted` acceptance에는 `approved_by` 필수, 삭제·재활성
불가, 불변 필드(id·actor·subject·key·fingerprint·acceptance) 변경 불가.

## 다섯 연산 ↔ 오너 CLI (`cmd/native-devices`)

| 연산 | CLI | 정책 변화 |
|---|---|---|
| 초기화 | `-init` | 빈 디렉터리에 revision 1(공 집합) 생성 |
| **E1 enroll-first** | `-enroll-first -input 후보` | 그 actor의 활성 기기가 0대일 때만. `active`, `out-of-band-fingerprint`, `approved_by` 없음 |
| **E2 add-device** | `-add-device -input 증거` | 새 기기 `active`, `trusted-device-fingerprint`, `approved_by={승인기기, 새 revision}` |
| **E3 revoke** | `-revoke <id> [-input 증거]` | `active`→`revoked` tombstone. 승인 증거는 선택적이며 `approved_by`가 아직 없는 기기의 tombstone에 1회 기록 |
| **E4 recover-all-lost** | `-revoke-all <actor>` | 그 actor의 모든 활성 기기를 tombstone으로. 새 방/새 그룹은 클라이언트 측(ReInit/PSK 아님) |

모든 변이는 `-expected-revision`로 현재 revision과의 정확한 CAS다. E1의 대역외 의식에서
비교할 값은 CLI 출력의 `fingerprint`다. `-inspect`와 모든 출력에 서명 키는 절대
포함되지 않는다. E5(restore-history)는 이 계약 밖의 읽기전용 아카이브 기능이다.

## 승인 증거 (B6 수정)

- canonical payload = 고정 필드 순서의 JSON(`ApprovalPayloadWire`) — Rust 파사드가
  동일 바이트를 만들어야 한다.
- 서명 입력 = `"family-mls-v2/<action>\0" ‖ sha256(canonical payload)`
  (#177 §3.6 도메인 분리; 서명자는 임의 바이트에 서명하는 oracle이 아니다).
- 승인자 = 정책에 기록된 공개 키로 식별되는 **활성·동일 actor·다른 기기**. E1로 들어온
  out-of-band 첫 기기도 활성 신뢰 기기다(대역외 의식으로 신뢰 획득 — §3.2 "활성 신뢰
  기기"의 범위). 자기 승인·타 actor 승인·폐기된 승인자는 거부.
- `approved_by.revision`은 그 승인이 허가한 정책 revision(등록이면 새 기기가 추가되는
  revision, 폐기면 tombstone revision)에 묶인다. 한 번 쓰인 `approved_by`는 불변.
- `approved_by`는 **관리 선언**이다. 사람이 실제로 지문을 비교했다는 암호학적 증명이
  아니다(`server/DEVICES.md` 원칙 유지).
- 폐기 서명(`-revoke` + `-input` 증거)은 대상에 아직 `approved_by`가 없을 때(E1 등록)
  만 받는다. E2로 등록된 기기는 등록 시 증거를 이미 썼으므로 plain revoke만 허용된다 —
  증거는 정책당 정확히 한 번 쓰인다.

## 릴레이 호출자 인증 (#177 §3 "CF Access JWT → actor", 리뷰 C1)

릴레이는 기본값 **`-access-mode required`**로 뜬다. 이 모드는 `-access-issuer`,
`-access-audience`, `-access-jwks`(로컬 파일 경로 또는 `https://` URL — CF Access는
`<issuer>/cdn-cgi/access/certs`)와 `-device-state`가 **모두** 있어야 하며 하나라도
없으면 시작을 거부한다(fail-closed). `-access-mode disabled`는 로컬 개발 전용이고 기동
로그에 큰 경고를 남긴다 — 그 모드에서는 어떤 클라이언트든 어떤 device로도 행동할 수 있다.
v2 smoke는 required 모드로 돈다(ES256 키를 만들어 JWKS 파일로 넘기고 기기별 토큰을 민팅).

- **토큰 위치**: `Cf-Access-Jwt-Assertion` 헤더. 없으면 `Authorization: Bearer <jwt>`
  (도구용 fallback). 둘 다 없거나 검증 실패 → **401 `{"error":"unauthorized"}`** — 본문에
  이유 없음, 로그에만 경로+이유. 토큰 검사는 **본문을 읽기 전에** 끝난다.
- **검증**(표준 라이브러리 `crypto/ecdsa`·`crypto/rsa`만): 헤더 `alg`는 ES256 또는
  RS256이어야 하고 `kid`로 JWKS 키를 고른다(키 종류와 alg 불일치 거부; P-256·RSA ≥2048만
  적재). `iss` 정확 일치, `aud`(문자열 또는 배열)가 설정값 포함, `exp` 필수·`nbf` 선택을
  **60초 leeway**로. 클레임 아이덴티티는 `sub`가 기본이고, 서비스 토큰(기계 레인 —
  `CF-Access-Client-Id/Secret`)은 `sub`가 비어 있고 `common_name`(Client-Id)에
  아이덴티티를 실으므로 그 값으로 폴백한다(G-M6); 둘 다 비어 있으면 그대로 401. 서명·
  `iss`·`aud`·시간 검사는 폴백과 무관하게 먼저 통과해야 한다 — `common_name`은 이미
  JWKS 검증을 지난 토큰 안에서만 신뢰한다. JWKS는 메모리에 캐시하고 모르는 `kid`가 오면
  **분당 최대 1회** 소스를 다시 읽는다(회전 대응; 재적재 실패 시 기존 키 유지).
- **아이덴티티 바인딩**: 요청이 행동한다고 주장하는 device(`events` POST의 `device`,
  `events` GET의 `?device=`, `keypackages` POST의 `device`, `keypackages` GET의
  `?consumer=` — `?device=`는 대상이지 호출자가 아니다 —, `/close`의 `?device=`)가
  정책상 **active이고 `subject ==` 클레임 아이덴티티(`sub`, 서비스 토큰은 폴백된
  `common_name`)**여야 한다. 모르는 device·revoked·타인의
  subject 전부 같은 **403 `{"error":"device_subject_mismatch"}`** — 어느 검사가 실패했는지
  드러내지 않는다(로그에는 device id와 이유만). 체인을 못 읽으면 500
  `device_policy_unavailable`. 트랜잭션 안의 M3b 정책 검사는 그대로 두 번째 선이다.
- **결과**: 인증이 켜지면 revoked 기기는 **GET도 403**이다(아래 M3b의 "POST-only 거부"는
  `disabled` 모드의 잔존 계약). 기기당 subject 하나·사람당 기기 N개이므로 같은 사람의
  토큰은 그 사람의 어느 active 기기로도 행동할 수 있다 — 기기 간 분리는 MLS 키가 한다.
- **`/close`**(§3.4 삭제 경로, B1): `POST /v2/rooms/{room}/close?device=<id>`. 바인딩된
  device가 그 방의 **추적 멤버**(`mls_members`)여야 한다 — 아니면 **403 `not_a_member`**,
  모르는 방은 **404 `no_such_room`**, 이미 닫힌 방을 멤버가 다시 닫으면 200(멱등).
  멤버가 하나도 시드되지 않은 방은 아무도 닫지 못한다(부트스트랩 전 방 이름 선점 DoS를
  막는 쪽을 택함; 파일 삭제는 운영자 몫). `disabled` 모드에서는 `?device=`만 요구한다.

## 릴레이 멤버십 강제 (M3b)

릴레이는 `-device-state <dir>`로 정책 체인에 붙는다. 기동 시 체인을 재생하지 못하면
**시작을 거부**하고(운영 중 손상은 쓰기 전부 500 `device_policy_unavailable` — fail-closed),
플래그가 없으면 강제 없이 구 동작을 유지하며 경고를 남긴다(`-access-mode required`는
이 플래그를 요구한다). 체인 읽기는 모든 쓰기 경로에서 커밋 트랜잭션 안에서 다시
이뤄진다(revoke와 POST의 경쟁 창을 트랜잭션으로 닫음).

- **모든 POST**(events, keypackages): 게시 device가 정책상 active여야 한다. 모르는
  device든 revoked든 **403 `device_not_allowed`**. 이 검사만으로는 GET을 막지 않는다
  (`disabled` 모드의 거부는 POST-only — 과거 로그는 읽히되 MLS 에포크가 해독 불가로
  만든다). required 모드에서는 위 아이덴티티 바인딩이 먼저 걸려 GET도 403이다.
- **application·welcome은 추적 멤버만**(리뷰 2차 G-H1, #231): 멤버십이 시드된 방에서
  추적 멤버가 아닌 active 기기(외부인, commit으로 제거된 기기)의 application/welcome
  POST는 **403 `not_a_member`**이고 아무것도 저장하지 않으며 커서를 만들지 않는다
  (판정은 K4·CAS보다 먼저 — 외부인에게 epoch 오라클 없음). 이전에는 통과시키고 게시자
  커서(0)를 만들어, 영원히 ack하지 않는 프루닝 게이트가 생겼다. 창립 commit 전에는
  구 동작(active면 게시 가능)이고, **창립 commit은 창립 목록에 없는 기기의 커서를
  삭제**한다 — 창립 전 게시자가 비멤버로 남아 게이트가 되지 않도록. `-device-state`
  없는 릴레이는 그대로다.
- **keypackage 소비·`/close`도 트랜잭션 안 재검사**(G-M3): `GET /keypackages`의
  `?consumer=`와 `/close`의 `?device=`는 핸들러 바인딩 뒤 **트랜잭션 안에서** 다시
  정책 active(403 `device_not_allowed`·500 `device_policy_unavailable`)여야 하고,
  멤버십이 시드된 방에서는 추적 멤버(403 `not_a_member`)여야 한다. 이전에는 아무
  active 기기나 모든 방의 타인 KeyPackage(기기당 4개)를 소진시켜 초대를 막을 수 있었다.
  창립 전 방은 창립자가 초대 대상의 KeyPackage를 가져와야 하므로 active면 소비 가능.
- **commit 외부 멤버 목록**: 릴레이는 MLS commit을 해석하지 않으므로, 클라이언트가
  post-commit 멤버 목록(`members: [{device, actor}...]`)을 outer JSON에 복제해 보낸다
  (§3.3). 강제 on 시 commit에 필수이고 sender가 목록에 있어야 하며 중복 device 금지 —
  구조 위반은 400. (클라이언트는 MLS 처리 후 outer와 내부 일치를 검증한다.)
- **승인 순서**: 인가는 K4 재생·CAS 읽기보다 **먼저**다. revoked/비멤버 sender는 현재
  epoch/revision을 409에서 훔쳐볼 수 없고, 허용된 sender의 바이트 동일 재시도는 그대로
  200 duplicate다.
- **부트스트랩**: 방의 첫 commit이 창립 멤버 목록을 시드한다. 시드되는 모든 device가
  정책상 active여야 하고, **인증된 sender 자신이 목록에 있어야 한다**(핸들러 400
  `commit_sender_not_listed` + 저장소 403 `commit_sender_not_member`의 이중선 — H3b).
  commit 본문 자체는 클라이언트가 검증한다(릴레이는 MLS를 해석하지 않는다, by design).
- **이후 commit**: sender는 추적 멤버여야 하고(403 `commit_sender_not_member`),
  추가되는 device는 정책상 active(403 `commit_member_not_active`)이며 그 actor가 방
  로스터에 있어야 한다(403 `commit_actor_not_in_roster`) — 새 기기는 기존 actor에,
  새 actor는 방 생성 클라이언트 쪽으로.
- **복제 actor = 정책 actor**(G-H3): 부트스트랩이든 추가든, 새로 좌석을 받는 모든
  `members[]` 항목의 `actor`는 그 device의 정책 `actor`와 같아야 한다 — 아니면 **403
  `commit_actor_mismatch`**. 이전에는 클라이언트가 적은 actor만 로스터와 대조해서,
  멤버가 다른 사람의 기기를 로스터 actor 이름으로 끼워 넣을 수 있었고 창립 로그·
  `mls_members`가 거짓이 됐다.
- **제거된 멤버의 커서 유예(H3a)**: commit으로 제거된 device의 멤버 행은 같은
  트랜잭션에서 지워지지만 읽기 커서(`mls_cursors`)는 **지우지 않고** `removed_at`·
  `removed_seq`(제거 commit의 seq)로 표시한다. 그 커서는 (a) 그 기기가 자기 제거
  commit까지 읽어 ack하거나(`seq ≥ removed_seq`) (b) 유예
  `-removed-cursor-grace-seconds`(기본 7일)가 지날 때까지 프루닝 MIN에 계속 들어간다 —
  오프라인 중에 제거된 기기도 거기까지의 이벤트는 받을 수 있다. 추적 멤버가 아닌
  active 기기는 읽을 수는 있지만 **ack하면 403 `not_a_member`**이고 커서를 만들지
  않는다(프루닝 게이트가 되지 않음; 제거된 기기의 기존 커서는 유예 동안 ack로 전진만
  한다). 재추가되면 커서가 일반 reader로 되살아난다.
- **커서 = ack (M2, 후속 5)**: `GET /v2/rooms/{r}/events?device=&after=&limit=`는
  **커서를 움직이지 않는다** — `after`는 순수 읽기 오프셋이라, 응답이 유실돼도 같은
  `after`로 다시 받을 수 있다. 커서(application 이벤트 프루닝 게이트)는 같은 GET의
  **`?ack=<seq>`**로만 전진한다: 기기가 seq까지 **영속 처리했음**을 선언하면
  `cursor = max(현재, ack)`. `ack > last_seq`는 400 `bad_ack`, 음수·비숫자도 400
  `bad_ack`, 멤버십 추적 중 방에서 커서도 없고 추적 멤버도 아닌 기기는 403
  `not_a_member`(판정 순서: 멤버십 → 범위, 외부인에게 last_seq 오라클 없음). 응답의
  `cursor`는 요청 후의 ack 값(없으면 0). 프루닝 MIN은 ack 커서 기준이라 **읽고 ack하지
  않은 기기는 계속 보존을 막는다**. 클라이언트 규칙: 이벤트를 처리·영속한 뒤 그
  seq로 ack(브라우저 세션 저장소는 메시지마다 영속하므로 durable cursor = ack 값).
- **프루닝**: 정책을 떠난(revoke/소멸) device의 커서는 프루닝 계산에서 먼저 삭제된다.
  tombstone 기기가 application 이벤트를 영구 점유하지 않는다.

## 서버 안전성 (리뷰 1차, #177)

- **H1 JSON 깊이**: 엄격 디코더가 중첩 32 초과를 400 `json_too_deep`으로 거부한다
  (1 MiB `[[[[…` 본문도 재귀 폭주 없이 400).
- **H2 캡 전 프루닝**: events POST는 같은 트랜잭션에서 **프루닝 → 바이트 캡 측정 →
  insert** 순서다. stale application 이벤트로 가득 찬 방이 commit을 413으로 막지 않는다.
  events GET도 `?ack=`로 요청 기기의 커서가 전진하면 같은 트랜잭션에서 프루닝한다
  (ack가 보존 해제를 끌어낸다; 읽기만으로는 아님 — M2). **commit은 캡에서 면제**(리뷰
  2차 G-H2): ack하지 않는 reader가 방을 캡에 묶어 두면 그 reader를 내보내는 commit마저
  413이라 `-reset-room`밖에 남지 않았다. commit은 epoch를 올리므로 epoch 보존 창이
  개수를 묶고, welcome·application은 그대로 캡을 받는다. seq는 `mls_rooms.last_seq` 카운터에서 나온다 —
  `MAX(seq)`는 프루닝으로 비워진 테이블에서 되감길 수 있으므로 쓰지 않는다
  (구 파일은 열 때 열을 추가하고 backfill).
- **M4 한도**: POST 본문 ≤ 1 MiB(413 `body_too_large`; 방 캡은 총량에 별도 적용),
  `ReadHeaderTimeout 10s`·`ReadTimeout 30s`·`WriteTimeout 60s`·`IdleTimeout 120s`.
  events GET은 `?limit=`(기본 500, 최대 2000으로 클램프, 0 이하·비숫자는 400 `bad_limit`)
  페이지와 응답 `next_after`(스캔한 최고 seq — 필터된 Welcome 포함 — 를 다음 `?after=`로)를
  갖는다.
- **M5 keypackage 멱등성**: 같은 `(room, device, ref)`에 바이트 동일 재게시는 200
  `{"stored":0,"duplicates":n}`(라이브 상한에 안 셈), 다른 바이트는 409
  `key_package_ref_conflict`. 소비된 ref도 정체성을 유지한다.
- **M6 SQLite**: DSN에 `_txlock=immediate`를 더해 모든 `db.Begin()`이 실제로
  BEGIN IMMEDIATE다(이전 주석은 그렇다고 했지만 deferred였다); `busy_timeout 5000` 유지.
- **L1 K4 재생 epoch**: commit의 바이트 동일 재시도(200 duplicate)는 201이 돌려준
  **post-commit epoch**를 돌려준다(저장된 epoch+1로 계산).
- **L8 식별자**: `device`, `targets[]`, `members[].device/actor`, `?device=`, `?consumer=`,
  그리고 **경로의 `{room}`과 `client_id`**(리뷰 2차 G-M2·G-H4) 전부 정책과 같은
  `[A-Za-z0-9_-]{1,64}`(`devicepolicy.IsIdentifier`). 위반은 400 `bad_identifier`(필드명만,
  값은 본문에 싣지 않음). mux가 디코딩한 경로 세그먼트를 그대로 넘기므로 방 이름
  검사 없이는 개행이 창립 로그 줄에, 유니코드 동형 문자가 선착순 방 이름 공간에 들어갔다.
- **열 형태 상한**(G-H4): 방 캡은 `bytes`만 세므로 그 밖의 저장 열은 형태로 묶는다 —
  `group_id`는 identifier 문자집합 ≤256(MLS group id 128바이트 hex), `targets` ≤32개,
  `members` ≤64개(400 `too_many_targets`/`too_many_members`). 이전에는 `client_id`·
  `group_id`가 비어 있지만 않으면 돼서 1 MiB 본문 한도 안에서 캡을 우회해 디스크를
  채울 수 있었다.
- **JWKS 재적재**(G-M5·L1): 모르는 `kid`의 재적재는 **마지막 시도 시각 기준**으로 분당
  1회(실패해도 센다 — kid는 서명 검증 전 값이라 공격자가 고른다), fetch는 verifier 락
  밖에서 돌아 아는 kid의 검증을 막지 않으며, 사용 가능한 키가 0개인 응답은 캐시를
  교체하지 않는다.

### 리뷰 2차 Low 묶음 (#231 배치 f)

- **JWKS 리다이렉트**: https URL 소스의 fetch는 리다이렉트를 최대 3회 따르고 **https가
  아닌 hop은 요청 전에 거부**한다(키 집합을 평문으로 요청하지 않음). 거부된 재적재는
  캐시를 바꾸지 않는다.
- **JWT 수명 상한**: `exp`는 `now + 31일(+leeway)`를, `iat`가 있으면 `now + leeway`와
  `exp − iat ≤ 31일`를 넘을 수 없다(401 `lifetime too long` / `issued in the future`,
  사유는 로그에만). 31일은 CF Access가 발급할 수 있는 가장 긴 세션 — 이 계정의 앱은
  전부 730h 세션(2026-10-02 실측, #243 G-M6)이라 24h 기본값이면 실토큰이 전부 401이었다.
  `-access-max-lifetime-seconds`는 **조이는** 용도(기본값보다 넓힐 수 없는 것은 아니지만
  제품 상한을 넘길 이유가 없다).
- **commit/welcome 보존**: `-commit-welcome-keep-epochs`(기본 8) 밖의 commit/welcome은
  application과 같은 게이트 — **모든 known reader의 ack 커서가 지난 것만** — 로 지운다.
  오프라인 멤버가 돌아와서 자기 epoch부터 따라잡을 수 있게 하기 위해서다.
  `-commit-welcome-hard-max-epochs`(기본 256)는 커서와 무관한 백스톱: 그만큼 뒤처진
  reader는 어차피 새 Welcome이 필요하다(commit은 캡 면제라 백스톱 없이는 ack 안 하는
  reader가 영구 점유). GET 응답의 **`first_seq`**(방에 남은 최소 seq, 비면 0)로
  reader는 `after < first_seq − 1`이면 자기가 못 본 역사가 지워졌음을 안다 —
  연속인 척하지 말고 재참여해야 한다.
- **미시드 방 ack**: 커서 행이 없는 기기는 **로스터에 앉은 멤버일 때만** ack로 커서를
  만든다. 미시드 방(창립 commit 전·로스터 없음)의 정당한 reader(게시자·Welcome 대상)는
  이미 `registerCursor` 행을 가지므로, 그 밖의 기기의 ack는 멤버십 추적 중 시드된
  방이면 403 `not_a_member`, 아니면 **무시되고 `cursor: 0`**(행 없음, 프루닝 게이트
  아님). 새로 만든 커서가 0이면 전진으로 치지 않아 프루닝을 돌리지 않는다.
- **GET 페이지 바이트 예산**: 한 페이지의 `bytes` 합은 8 MiB를 넘지 않는다(`limit`
  2000 × 64 MiB 방 = base64 ~86 MiB가 60 s write timeout 안에 나가던 문제). 예산을
  넘길 행 **앞에서** 끊고 `next_after`는 끊기 전 마지막 스캔 행이라 다음 요청이 정확히
  거기서 이어진다(빠짐·중복 없음). 첫 행은 항상 돌려준다.
- **`-reset-room` 드라이런은 읽기 전용**: 도구는 `openStore`(CREATE TABLE/ALTER TABLE)를
  거치지 않고 파일을 **있는 그대로** 연다 — 드라이런은 `mode=ro`, `-yes`도 스키마
  초기화 없이 쓰기 연결만. M3 이전 파일에 없는 테이블은 0으로 센다. 드라이런 뒤
  파일 sha256이 같다(테스트).
- **`-access-mode disabled`는 loopback 전용**: `-addr`가 127.0.0.0/8·`::1`·`localhost`가
  아니면(``""``·`0.0.0.0`·`::`·LAN 주소) 기동을 거부한다. 인증 없는 릴레이가 네트워크에
  노출될 조합은 로컬 개발이 아니다.
- 테스트 공백 메움: JWKS 소스가 멈춘 동안 모르는 kid N건 동시 요청 → fetch 1회,
  아는 kid 검증은 막히지 않음, 500 뒤 전부 401, 간격 안 재fetch 없음(`-race`); ack 안
  하는 reader가 방을 캡에 묶음 → 제거 commit 수용 → 유예 뒤 커서 삭제·프루닝 → 게시
  재개·제거된 기기는 403(복구 전 과정).

멤버십은 `mls_members(room, device, actor, added_seq)`에 커밋 insert와 같은
BEGIN IMMEDIATE 트랜잭션으로 기록된다(B2/B3 규율 유지). v2 릴레이 smoke
(`native_v2_relay_smoke.py`)은 M3c에서 `-device-state` 강제 모드로 전환됐다 —
정책 체인은 실제 owner CLI(native-devices)로 만들고, E2 승인 증거는 브라우저
파사드가 서명하며, commit은 post-commit 멤버 목록을 outer JSON에 복제한다.

## 구 바이너리 거부 (검증됨)

운영 v1 정책은 v4 모양을 구조적으로 거부해야 하고, 그렇다:
`server/internal/access`의 `TestPolicyRejectsNativeV4Shape` — `version:4`, `approved_by`
필드, `trusted-device-fingerprint` acceptance, actor당 2번째 기기를 전부 `ErrConfig`
거부(엄격 디코더 미허용 키 + `config()` 버전 1–3 한정). 이 PR은 v1–v3 수용 경로를
의도적으로 건드리지 않았다. `successors.go`·`activation.go` 관리 CLI 정리는 별도 범위.

## fail-closed와 CAS

- 조작된 policy 바이트, 깨진 백링크, 위조된 다음 revision, nlink>1·symlink 상태 파일,
  남은 `pending-*`, 이물 파일 → 체인 읽기가 `ErrDevicePolicyState`로 거절하고 **어떤
  쓰기도 하지 않는다**(상태는 점검용으로 보존; 복구는 수동).
- CAS 불일치는 `ErrDevicePolicyConflict`. 직전 결과와 **바이트 동일**한 재시도만 기존
  revision을 그대로 반환한다(K4) — 체인이 더 진행됐으면 충돌이다.
- 동시 커밋에서 정확히 하나가 이긴다(`-race` 테스트).

## 증명하지 않는 것

- 릴레이가 revoke 이후 그 device의 요청을 거부하는 것 — **M3b + C1에서 증명**(위
  섹션, Go HTTP·단위 테스트), v2 smoke이 등록된 기기로 종단 재확인(required 모드:
  event·keypackage POST와 GET 전부 403 `device_subject_mismatch`, 새 에포크는 해독
  불가; 토큰 없음 401, 타인 subject 403, `/close` 비멤버 403·멤버 200·이후 410).
- CF Access 자체(실제 발급자·실제 `sub`) — smoke는 ES256 키 하나로 CF Access를
  대역한다. 검증 코드는 발급자를 모르고 JWKS·iss·aud만 안다.
- MLS `Add`/`Remove` commit과 Welcome — 클라이언트(M3c 파사드). 릴레이는 outer
  복제 목록만 검증하며 outer·내부 불일치 검증은 클라이언트 몫이다.
- v2 릴레이 smoke의 등록된 기기 전환 — M3c PR에서 완료: E1·E2 등록(두 지문 화면
  일치 확인), E2·E3 폐기 증거(브라우저 서명 → Go CLI 검증), E4 revoke-all과 대체 기기의
  새 방. 남는 것은 지문 비교 UI의 **실제 대역외 비교 수행** — 사람.
- 64 revision 소진 후 컴팩션, E5 restore-history, 파일·봇(M5).
- 브라우저/실기기 동작 — 이 유닛은 순수 서버 측 Go다.
- 쿠키 기반 CF Access 세션에서의 교차 사이트 요청(G-M8): `GET /events?ack=`·`GET
  /keypackages`는 상태를 바꾸는 GET이고 `/close`는 본문 없는 POST다. 호출자 인증은
  헤더 토큰(`Cf-Access-Jwt-Assertion`/`Bearer`) 전제이며, 브라우저 쿠키 세션으로
  릴레이를 직접 노출하는 배치는 이 계약 밖이다.

## 운영자 복구: 방 초기화 (`-reset-room`, 리뷰 H3)

방 이름은 인증된 기기 사이에서 **선착순**이다(창립 commit이 로스터를 정함). 프로토콜(라우트·방 id
규칙)은 바꾸지 않고, 이름 선점·창립 실수는 오프라인 운영자 도구로 복구한다.

- 창립 commit은 info 로그로 남는다: `room <r> founded: sender=<device> actor=<actor> seq=<n> members=<device(actor),…>` — 선점 감사.
- 릴레이는 데이터 디렉터리에 **배타 잠금**(`native-mls-v2.lock`, flock)을 수명 동안 잡는다. 같은 디렉터리로
  두 번째 릴레이나 아래 도구를 열면 `data dir is locked by another process`로 거부된다.
- 절차: 릴레이 정지 → `<v2 릴레이 바이너리(archive/native-mls/server 빌드)> -data-dir <dir> -reset-room <room>`(dry run: 테이블별 삭제 예정 행 수 출력,
  종료 코드 2) → 확인 후 `-yes`를 붙여 재실행(한 트랜잭션으로 `mls_events`·`mls_keypackages`·`mls_members`·
  `mls_cursors`·`mls_rooms`의 그 방 행만 삭제, 종료 코드 0) → 릴레이 재기동. DB 파일이 없으면 만들지 않고 거부.
- 효과: 그 방의 순서·epoch·멤버·커서를 릴레이가 완전히 잊는다 → 클라이언트는 **새 MLS 그룹**으로 다시 창립해야
  한다(옛 방 기록은 클라이언트 쪽 읽기전용 보관). 접근 플래그(`-access-*`)는 필요 없다(리스너를 열지 않음).
- DB 변경이므로 운영 노드에서는 **사전 백업 + 오너 승인** 후 실행한다.

