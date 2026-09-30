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
| `subject` | CF Access `sub` 등 |
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

## 릴레이 멤버십 강제 (M3b)

릴레이는 `-device-state <dir>`로 정책 체인에 붙는다. 기동 시 체인을 재생하지 못하면
**시작을 거부**하고(운영 중 손상은 쓰기 전부 500 `device_policy_unavailable` — fail-closed),
플래그가 없으면 강제 없이 구 동작을 유지하며 경고를 남긴다. 체인 읽기는 모든 쓰기
경로에서 커밋 트랜잭션 안에서 다시 이뤄진다(revoke와 POST의 경쟁 창을 트랜잭션으로 닫음).

- **모든 POST**(events, keypackages): 게시 device가 정책상 active여야 한다. 모르는
  device든 revoked든 **403 `device_not_allowed`**. GET은 막지 않는다(거부는 POST-only —
  과거 로그는 읽히되 MLS 에포크가 해독 불가로 만든다).
- **commit 외부 멤버 목록**: 릴레이는 MLS commit을 해석하지 않으므로, 클라이언트가
  post-commit 멤버 목록(`members: [{device, actor}...]`)을 outer JSON에 복제해 보낸다
  (§3.3). 강제 on 시 commit에 필수이고 sender가 목록에 있어야 하며 중복 device 금지 —
  구조 위반은 400. (클라이언트는 MLS 처리 후 outer와 내부 일치를 검증한다.)
- **승인 순서**: 인가는 K4 재생·CAS 읽기보다 **먼저**다. revoked/비멤버 sender는 현재
  epoch/revision을 409에서 훔쳐볼 수 없고, 허용된 sender의 바이트 동일 재시도는 그대로
  200 duplicate다.
- **부트스트랩**: 방의 첫 commit이 창립 멤버 목록을 시드한다. 시드되는 모든 device가
  정책상 active여야 한다.
- **이후 commit**: sender는 추적 멤버여야 하고(403 `commit_sender_not_member`),
  추가되는 device는 정책상 active(403 `commit_member_not_active`)이며 그 actor가 방
  로스터에 있어야 한다(403 `commit_actor_not_in_roster`) — 새 기기는 기존 actor에,
  새 actor는 방 생성 클라이언트 쪽으로. 제거된 device는 멤버 행과 읽기 커서가 같은
  트랜잭션에서 삭제된다(제거된 기기가 프루닝을 막지 않는다 — M1 후속).
- **프루닝**: 정책을 떠난(revoke/소멸) device의 커서는 프루닝 계산에서 먼저 삭제된다.
  tombstone 기기가 application 이벤트를 영구 점유하지 않는다.

멤버십은 `mls_members(room, device, actor, added_seq)`에 커밋 insert와 같은
BEGIN IMMEDIATE 트랜잭션으로 기록된다(B2/B3 규율 유지). v2 릴레이 smoke
(`native_v2_relay_smoke.py`)은 아직 등록 없이 구 모드로 도는데, 클라이언트 정책 등록과
함께 M3c에서 전환된다.

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

- 릴레이가 revoke 이후 그 device의 POST를 거부하는 것 — **M3b에서 증명**(위 섹션,
  Go HTTP·단위 테스트). 단, GET은 열려 있다(POST-only 거부).
- MLS `Add`/`Remove` commit과 Welcome — 클라이언트(M3c 파사드). 릴레이는 outer
  복제 목록만 검증하며 outer·내부 불일치 검증은 클라이언트 몫이다.
- v2 릴레이 smoke의 등록된 기기 전환, 지문 비교 UI와 실제 대역외 비교 수행 — M3c·사람.
- 64 revision 소진 후 컴팩션, E5 restore-history, 파일·봇(M5).
- 브라우저/실기기 동작 — 이 유닛은 순수 서버 측 Go다.
