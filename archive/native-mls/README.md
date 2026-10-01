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
Welcome 타깃 필터링, 바이트 기준 보존/프루닝, `BEGIN IMMEDIATE`(`_txlock=immediate`) 안의 CAS.

호출자 인증은 기본 **켜짐**(`-access-mode required`): 모든 계약 라우트가 CF Access JWT
(`Cf-Access-Jwt-Assertion`, fallback `Authorization: Bearer`)를 요구하고, 요청이 행동하는 device의
정책 `subject`에 `sub`를 묶는다(401 / 403 `device_subject_mismatch`). 기동 플래그
`-access-issuer`·`-access-audience`·`-access-jwks`(파일 또는 https URL)·`-device-state`가 전부
필요하고, `-access-mode disabled`는 로컬 개발 전용이다. 계약 전문은
[`server/DEVICES-V4.md`](server/DEVICES-V4.md)(인증·멤버십·커서 유예·서버 안전성 섹션).

## tests/

| 파일 | 대상 | 서버 필요 |
|---|---|---|
| `native_mls_browser_smoke.py` | 메모리 전용 워커 2 컨텍스트 왕복·변조·재생·잘못된 그룹·제거 | 없음 |
| `native_mls_persistence_smoke.py` | `durable-worker.js` IDB 단일 tx·결함 주입·손상 거부 | 없음 |
| `native_trusted_state_smoke.py` | `trusted-state-worker.js` 핀 + 서명 디렉터리 | 라이브 `family-dev`/`family-policy` |
| `native_device_browser_smoke.py` | `trust-worker.js` 첫 기기 디렉터리 게이트 | 라이브 `family-dev`/`family-policy` |
| `native_v2_relay_smoke.py` | v2 릴레이 종단(등록 기기, 결함 주입 a–j, CF Access 대역 JWT) | `native-mls-relay`/`native-devices` (`cryptography`로 ES256 토큰 민팅) |
