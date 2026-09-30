# 네이티브 기기 정책 v4 — 계약 (#177 §3.1·§3.2, M3a)

**상태:** 구현됨 (M3a). 이 문서는 `archive/native-mls/server`의 정책 체인과 오너 CLI가
무엇을 보장하고 무엇을 증명하지 않는지 묶는다. **M3b**(릴레이 멤버십 강제 — commit
sender active 검사, revoke 이후 POST 403)와 **M3c**(지문 비교 UI)는 별도 PR이다.
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

- 릴레이가 revoke 이후 그 device의 POST를 거부하는 것 — M3b.
- MLS `Add`/`Remove` commit과 Welcome — M3b·클라이언트.
- 지문 비교 UI와 실제 대역외 비교 수행 — M3c·사람.
- 64 revision 소진 후 컴팩션, E5 restore-history, 파일·봇(M5).
- 브라우저/실기기 동작 — 이 유닛은 순수 서버 측 Go다.
