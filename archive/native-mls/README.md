# archive/native-mls — 독자 MLS 전달층 (v1 제거, v2는 #177 M1)

**상태:** 병행 개발(2026-09-21 결정 E → 재설계 [#177](https://github.com/jinwon-int/family-messenger/issues/177)).
운영 전달층은 Matrix다. 트리 개요는 [archive/README.md](../README.md).

## 무엇이 있었나 (v1, M0에서 제거)

우리 Go 서버(`server/`)가 직접 E2EE 전달층이 되려던 v1 코드: `/v1/mls/*` 16 라우트, 스키마 3→12의
`mls_*` 13 테이블, successor 9단계(context·reservation·custody·handshake·confirmation·lease·retirement·
enrollment·closure), `-tags synthetic_*` UI 번들 12종. 약 8,100줄 Go + 12,400줄 테스트로 "2인 방 기기
1대 교체" 하나를 만들었지만 그 교체를 완성하지 못했다(#177 §1.1·§1.4). 이 코드는 라이브 `chat` 패키지의
`Store`·스키마에 의존해 단독 컴파일이 불가했다.

전부 태그 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive/native-mls)에
남아 있다. v1에서 v2로 가져갈 계약(#177 §1.2): 방당 단일 전순서 로그, epoch/revision CAS,
`UNIQUE(room,device,client_id)` + 바이트 동일 재시도(200/201), 엄격 JSON 디코더 `decodeMLS`.

## 운영 서버에 남은 것

- `server/internal/chat/schema_frozen.go`의 스키마 3~12 마이그레이션과 `mls_*` 테이블은 **그대로**다. 기존
  스키마-12 DB는 이전처럼 열린다. 테이블 삭제·변경·스키마 13 추가는 하지 않는다.
- `/v1/mls/*`는 404. `internal/access`의 `successors.go`·`activation.go`(정책 v2·v3)는 M3 정책 v4에서 정리한다.

## v2 (#177 §3.4, M1)

`archive/native-mls/server/`에 **별도 Go 모듈·별도 SQLite 파일**로 새로 만든다: 라우트 4개
(`keypackages` POST/GET, `events` POST/GET) + `close`, 테이블 5개(`mls_rooms`·`mls_events`·
`mls_keypackages`·`mls_cursors`·`mls_members`), 서버 측 MLS 상태기계 없음, 멤버 누구나 commit,
iOS 확장(#275, CONTRACTS §2.3): `GET /v2/rooms?device=`(기기의 방 목록, 공개 필드만),
`POST`/`DELETE /v2/push/devices` + 테이블 `push_devices`, 새 application/welcome 이벤트 뒤
APNs 알림(`-apns-key`·`-apns-team-id`·`-apns-key-id`, 선택 `-apns-host`·`-apns-topics`),
Welcome 타깃 필터링, 바이트 기준 보존/프루닝, `BEGIN IMMEDIATE`(`_txlock=immediate`) 안의 CAS.
타이핑 표시(#562 PR A, `server/typing.go`): `POST /v2/rooms/{room}/typing` 본문 `{"device","clear"}` → 204, 결과는
같은 방 멤버의 `GET /v2/rooms/{room}/events` 응답 `typing`(요청 기기 제외, 정렬된 device 목록)에만 실린다 —
메모리 전용·TTL 6초·테이블·푸시 없음(한도는 `server/DEVICES-V4.md` 서버 안전성).
status-v1(#560, `STATUS-V1.md`, `server/status.go`): 에이전트의 작업 상태 한 줄은 바깥 `client_id` 가
`status-<uuid>` 인 application 이벤트다 — 저장·커서·보존은 다른 이벤트와 같지만 **APNs 푸시는 보내지 않는다**
(몇 초마다 바뀌는 임시 글; 정규형 `^status-[a-f0-9-]{36}$` 만 예외, 그 밖의 `status-…` 는 일반 글).

호출자 인증은 기본 **켜짐**(`-access-mode required`): 모든 계약 라우트가 CF Access JWT
(`Cf-Access-Jwt-Assertion`, fallback `Authorization: Bearer`)를 요구하고, 요청이 행동하는 device의
정책 `subject`에 `sub`를 묶는다(401 / 403 `device_subject_mismatch`). 기동 플래그
`-access-issuer`·`-access-audience`·`-access-jwks`(파일 또는 https URL)·`-device-state`가 전부
필요하고, `-access-mode disabled`는 로컬 개발 전용이다. 계약 전문은
[`server/DEVICES-V4.md`](server/DEVICES-V4.md)(인증·멤버십·커서 유예·서버 안전성 섹션).
인증이 켜져 있을 때만 데이터가 아닌 보조 라우트 하나가 더 있다: `GET /v2/app-login?state=`(#271 §12-C A,
`server/applogin.go`) — 엣지가 주입한 JWT 를 검증한 뒤 iOS 앱의 고정 스킴 `hande://auth#jwt=…&state=…` 로
302 한다(앱 로그인 시트용, 플래그·테이블 없음).
한데 웹(#431 1단계, `server/hande.go`·`server/me.go`): `-hande-host`·`-hande-dir`(둘 다 함께)를 주면 Host 헤더가
그 이름(대소문자 무시, `:port` 무시)인 요청은 `/v2/*` 를 제외한 모든 경로를 `-hande-dir` 의 파일로 응답한다
(`/` = `index.html`, 점파일·`..`·디렉터리·없는 파일 404, GET/HEAD 외 405, 기동 시 `index.html` 필수). 다른 Host 의
동작(`/app/*` 포함)은 그대로이고 한데 호스트는 `-static-dir` 의 relay-app 파일을 내지 않는다. 인증이 켜져 있을 때만
`GET /v2/me` 가 엣지 JWT 를 검증해 `{"subject":"…"}` 를 돌려준다(웹앱 기기 등록 JSON 의 `subject` 용, 플래그·테이블
없음; `-access-mode disabled` 에서는 app-login 처럼 라우트가 없어 404). `-device-state` 가 있으면 같은 응답에 `policy_revision` 과
호출자 subject 의 `devices`(서명 키 없음)가 붙는다(#574).
기기 셀프서비스(#574 D1, `server/devices.go`, 인증 + `-device-state` 둘 다 있을 때만): `POST`/`GET /v2/devices/candidates`(새 기기의 공개
기록 우편함, 테이블 `device_candidates`, TTL 10분) · `POST /v2/devices/approvals`(E2, CLI `-add-device` 와 같은 증거) ·
`POST /v2/devices/roles`(E5 registrar 역할) — 검증은 CLI 와 같은 `internal/devicepolicy`, 호출자 subject 바인딩 추가. 계약은
`server/DEVICES-V4.md` 「등록 기기」·「셀프서비스 라우트」, 운영은 `docs/NATIVE-RELAY-OPERATIONS.md` 「기기 셀프서비스 운영」.

### 로비 key package (P5, #380)

방별 `mls_keypackages`는 기기가 먼저 그 방에 패키지를 올려야 초대가 가능해, 스튜어드 봇이 **아직 없는 방**으로
사람 기기를 초대할 수 없었다. 방과 무관한 로비 풀(테이블 `mls_lobby_keypackages`, `server/lobby.go`)과
초대받은 방을 기기가 스스로 찾는 목록을 추가한다. 라우트 4개(모두 JWT 인증 + 행동 device를 `sub`에 묶음,
본문 한도·엄격 JSON·식별자 규칙은 방 라우트와 동일):

- `POST /v2/lobby/keypackages` — 본문 `{"device","packages":[{"ref","bytes"}]}` (방 라우트와 같은 모양).
  기기당 라이브 **8개**, TTL **30일**(`LobbyKeyPackagesMaxPerDevice`/`LobbyKeyPackageTTLSeconds`,
  플래그 `-lobby-key-packages-max`·`-lobby-key-package-ttl-seconds`). 바이트 동일 재시도는 200(`duplicates`),
  같은 ref 다른 바이트 409 `key_package_ref_conflict`, 초과 409 `key_package_limit {live,max}`.
  응답 `{"stored","duplicates","live"}` — `live`는 쓰기 뒤 라이브 수(방 라우트 응답에도 같이 붙는다).
- `GET /v2/lobby/keypackages?device=<대상>&consumer=<호출자>&room=<방>` — 대상 기기의 가장 오래된 라이브
  패키지 하나를 원자적으로 소비(`consumed_by`·`consumed_room` 기록, 만료까지 행 보존). **방 규칙:** 방이 없으면
  허용(호출자가 첫 commit으로 방을 세운다; 여기서 방 행을 만들지 않음), 멤버가 추적되는 방이면 호출자가 멤버여야
  함(403 `not_a_member`), 닫힌 방 410 `room_closed`, 남은 패키지 없음 404 `no_live_key_package`.
  응답은 방 소비와 같은 `{"ref","bytes","expires_at"}`.
- `GET /v2/lobby/status?device=` — `{"device","live","max","ttl_seconds"}` (만료 행 정리 뒤). 앱의 보충 판단용.
- `DELETE /v2/lobby/keypackages?device=` — 이 기기의 **미소비** 로비 키를 모두 거둔다(소비된 행은 Welcome 추적용으로 만료까지 남음).
  `{"device","deleted"}`, 멱등(남은 게 없으면 200 `deleted=0`), 정책 게이트 없음(자기 키 회수). 앱 「이 기기 지우기」가 신원을 버리기 전에 부른다(#389).
- `GET /v2/lobby/welcomes?device=` — 이 기기를 `targets`로 하는 `welcome` 이벤트 중 기기의 커서가 아직 지나지
  않은 것(커서 없음 또는 `cursor.seq < seq`)이 있는 **열린** 방 목록. 각 항목의 `key_package_ref` = 그 방으로 가장 최근에
  소비된 이 기기의 로비 key package ref(방 key package 로 만든 Welcome 이면 없음) — 클라이언트는 그 비밀을 Welcome 을 받아들일 때까지 지우지 않는다(#517). 기기의 현재 자리(`mls_members.added_seq`) 이전의 Welcome(제거 후 재초대 전 것)은 목록에 싣지 않는다(#530)
  `{"welcomes":[{"room","seq","epoch","created_at"}]}`(오래된 순, 최대 100). 읽기 전용 — 커서는 기존
  `GET /v2/rooms/{room}/events?device=…&ack=`로만 움직이고, Welcome 본문도 그 라우트로 받는다.

같은 결정으로 기기당 방 생성 상한 `RoomsMaxPerDevice`는 16 → **32**.

### 첨부 blob 저장소 (file-v2 1단계, #499)

지금까지 첨부는 파일 원본 바이트를 MLS application 메시지 하나에 통째로 실었다(#364, ≤ 5 MiB) — 릴레이 이벤트·전
기기 동기화·브라우저 워커 장부·iOS NSE가 모두 원본 크기를 지나갔다(#371·#495·#496). file-v2는 Matrix의
"Sending encrypted attachments"처럼 파일을 MLS 경로 밖으로 뺀다: 보내는 기기가 파일마다 새 키로 암호화
(AES-256-GCM, 클라이언트)해 **암호문만** 여기 올리고, MLS 메시지(`client_id = file-v2-<uuid>`, 2단계)에는 blob id·키·
nonce·sha256만 담는다. **릴레이는 키를 보지 않는다** — blob 단독으로는 불투명한 암호문이고, 릴레이가 아는 것은 이벤트와
같은 크기·시각·게시 기기뿐이다. 라우트 2개(`server/blobs.go`, 테이블 `mls_blobs`, 파일 `<data-dir>/blobs/<room>/<id>`):

- `POST /v2/rooms/{room}/blobs?device=` — 본문 = **원시 암호문 바이트**(JSON·base64 아님). 상한 **50 MiB + 64 KiB**
  (`maxBlobBytes`, 초과 413 `blob_too_large`; JSON 본문 한도 `maxBodyBytes`와 별개), 빈 본문 400 `empty_body`.
  id = 받은 바이트의 소문자 hex sha256(내용 주소). 응답 `{"id","size"}` — 새로 저장 201, 같은 방에 이미 있으면 200(재시도 멱등).
- `GET /v2/rooms/{room}/blobs/{id}?device=` — 같은 바이트(`application/octet-stream`, `Cache-Control: no-store`,
  `nosniff`, Range 지원). id 형식 위반 400 `bad_blob_id`, 없음 404 `no_such_blob`.
- **공통 게이트**(이벤트 라우트와 동일): JWT 인증 + `device`를 `sub`에 묶음(403 `device_subject_mismatch`, 본문을 읽기 전),
  application 이벤트와 같은 멤버십(정책 활성 + 시드된 방이면 추적 멤버, 403 `not_a_member`/`device_not_allowed`, 트랜잭션
  안에서 재확인). **이미 있는 방만**(404 `no_such_room`, 방 행을 만들지 않음), 닫힌 방 410 `room_closed`.
- **상한**: blob 바이트는 이벤트 바이트와 **같은** `RoomBytesCap`(방 1 GiB)·`DeviceBytesCap`(기기 4 GiB)으로 센다
  (413 `room_bytes_cap`/`device_bytes_cap`).
- **보존**: `AppEventTTLSeconds`(30일)가 지나고 방의 모든 리더 커서가 업로드 시점의 방 seq(`after_seq`)를 지나면 삭제
  (참조하는 file-v2 메시지는 업로드 뒤에만 올 수 있다), 리더가 ack하지 않아도 **2×TTL**에는 무조건 삭제. 방을 닫으면 즉시 삭제.
  행은 쓰기 트랜잭션(prune·close)에서 지우고, 파일은 행 없는 파일·1시간 넘은 업로드 임시 파일을 지우는 스윕
  (기동 시·10분마다·close 직후)이 지운다. `-reset-room`도 방의 blob 행·파일을 지운다(출력에 `blobs=N`).
- 전송 시간: 두 라우트만 서버 Read/WriteTimeout 대신 10분 기한을 쓴다(휴대폰 회선의 50 MiB).
- **와이어 형식 정본**: [FILE-V2.md](FILE-V2.md) — `file-v2-<uuid>` MLS 메시지의 설명자(blob id·키·nonce·크기), AES-256-GCM, 수신·검증 규칙.

## tests/

| 파일 | 대상 | 서버 필요 |
|---|---|---|
| `native_mls_browser_smoke.py` | 메모리 전용 워커 2 컨텍스트 왕복·변조·재생·잘못된 그룹·제거 | 없음 |
| `native_mls_persistence_smoke.py` | `durable-worker.js` IDB 단일 tx·결함 주입·손상 거부 | 없음 |
| `native_trusted_state_smoke.py` | `trusted-state-worker.js` 핀 + 서명 디렉터리 | 라이브 `family-dev`/`family-policy` |
| `native_device_browser_smoke.py` | `trust-worker.js` 첫 기기 디렉터리 게이트 | 라이브 `family-dev`/`family-policy` |
| `native_v2_relay_smoke.py` | v2 릴레이 종단(등록 기기, 결함 주입 a–j, CF Access 대역 JWT) | `native-mls-relay`/`native-devices` (`cryptography`로 ES256 토큰 민팅) |
