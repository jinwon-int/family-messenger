# archive/ — 독자 E2EE 병행 트리

2026-09-21 오너 결정([이슈 #92](https://github.com/jinwon-int/family-messenger/issues/92),
[PR #168](https://github.com/jinwon-int/family-messenger/pull/168) 결정 E)에 따라
보존 태그 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive)에서
복원한 뒤, 같은 날 재설계 [#177](https://github.com/jinwon-int/family-messenger/issues/177)
**M0 정리**를 거친 트리다. **운영 전달층은 Matrix다.** 이 트리는 `server/`·`web/`·`deploy/tuwunel/`
빌드와 기본 CI(`verify`·`native`·`web`)에 들어가지 않는다.

## M0 이후 구성

| 경로 | 내용 | 상태 |
|---|---|---|
| `experiments/openmls-browser/` | OpenMLS 0.9 WASM 파사드(`src/`), 브라우저 워커(`web/`), 핀 빌드 스크립트 `build.sh` | **개발 중.** #177 M1 대상 |
| `native-mls/tests/` | 브라우저 스모크 드라이버(왕복·지속·신뢰 상태·기기 디렉터리·v2 릴레이) | `native-mls.yml`이 실행 |
| `native-mls/README.md` | v1 Go 전송 서버 이력과 v2 계획 | — |

## M0에서 제거한 것 (#177 §1.3 D1–D8)

successor 9단계 Go 서버·테이블·라우트(`native-mls/server/` 전부 — 라이브 `chat` 패키지에 의존해 단독
컴파일이 불가했고, v2 서버는 M1에서 별도 Go 모듈로 새로 만든다), candidate/peer 미러 워커, `*-wire.js`,
의식 UI 4벌, aggregate vault, 히스토리 복구 UI(vault 스택 의존), 합성 자산 임베드 프로필, 4-신원
allowlist, 2인 고정 `LeafNodeIndex(1)`. 전부 태그 `archive-frozen-20260917`과 `docs/evidence/`에 남아 있다.

## M2b-3c에서 제거한 것 (2026-09-26)

커스터디가 `experiments/openmls-browser/custody/` 단일 스택으로 흡수된 뒤 남은 CI 밖 잔재: `experiments/device-keystore/` 전부(password-worker·probe·세션 레코드 워커와 로컬 번들 고정 증거), 스모크 3종(`device_keystore_smoke.py`·`password_worker_smoke.py`·`session_record_smoke.py`)과 그 파일 검사, 스모크 없던 `web/native-worker.js`·합성 채팅 페이지(`chat.*`·`native.html`)와 해시 증거 3편. 설계 문서 6편은 [`docs/history/native-mls/`](../docs/history/native-mls/)에 이력으로 옮겼다.

## 규칙

- CI는 `.github/workflows/native-mls.yml` **1 job ≤25분** (`workflow_dispatch` + `archive/**` 경로 필터). 옛 `mls-experiment.yml`(16 job/535분)은 되돌리지 않는다.
- CodeQL은 `.github/codeql/codeql-config.yml`의 `paths-ignore`로 `archive/`를 제외한다.
- 사람 키·실대화·운영 호스트는 범위가 아니다. 다음 단위는 #177 M1.
