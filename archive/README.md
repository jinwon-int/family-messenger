# archive/ — 독자 E2EE 병행 트리

2026-09-21 오너 결정([이슈 #92](https://github.com/jinwon-int/family-messenger/issues/92),
[PR #168](https://github.com/jinwon-int/family-messenger/pull/168) 결정 E)에 따라
보존 태그 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive)에서
`native-mls/`와 `experiments/`를 main으로 복원했다. **운영 전달층은 Matrix다.**
이 트리는 합성 실험·참고 구현이며 `server/`·`web/`·`deploy/tuwunel/` 빌드와
기본 CI(`verify`·`native`·`web`)에 들어가지 않는다.

| 경로 | 내용 | 이 PR에서 |
|---|---|---|
| `native-mls/` | Go MLS 전달·successor·합성 UI 드라이버 | 복원. 컴파일하지 않음 |
| `experiments/openmls-browser/` | OpenMLS WASM 브라우저 실험 | 복원. 기본 CI 없음 |
| `experiments/device-keystore/` | 기기 키 보관 프로브 | 복원. 기본 CI 없음 |
| `synapse-stack/` | 퇴역 Synapse/Element/Postgres | **복원하지 않음.** 태그에만 남김 |
| `.github/workflows/mls-experiment.yml` | 옛 16 job/535분 팬아웃 | **복원하지 않음.** 재가동 금지 |

내부 문서의 상대 경로·「동결」배너는 태그 시점 그대로인 곳이 있다. 상태의 정본은
이 파일과 결정 E다. 사람 키·실대화·운영 호스트는 범위가 아니다.

다음 구현 단위는 [NATIVE-E2EE.md](../docs/NATIVE-E2EE.md) 수용 순서에서 아직 안 끝난
사람 사용 게이트의 **한 단계**만 이슈로 연다. 스키마 13·컷오버는 여기 포함이 아니다.
