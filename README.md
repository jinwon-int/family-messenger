# 패밀리챗 · Family Chat

**가족과 AI 에이전트가 함께 이야기하고, 기억하고, 일상을 챙기는 채팅.**

가족이 여행을 의논하면 함께 일정을 정리하고, 궁금한 것을 물으면 쉽게 설명하고,
함께 결정한 일은 기억했다가 필요한 때 돕는 공간을 만듭니다.
사람과 AI가 같은 대화에 참여하되, 가족이 참여자·기억·실행 권한을 관리합니다.

## 우리가 만들 경험

- 가족 대화방과 개인 대화에서 사람과 AI 에이전트가 각자의 신원으로 참여합니다.
- AI는 명시적으로 부를 때 응답합니다. 먼저 알리는 기능은 가족이 허용한 범위에서 설계합니다.
- 기억할 내용은 확인받고, 저장한 기억을 보고 수정하거나 지울 수 있게 합니다.
- 개인 대화의 내용을 가족방으로 공유할 때는 당사자의 허락을 받습니다.
- 일정·할 일·자료 찾기를 돕고, 메시지 발송·결제 등 외부 행동은 실행 전에 확인받습니다.

이 목록은 **제품 비전과 개발 목표**입니다. 현재 기능의 완료 목록이 아닙니다.
첫 목표는 가족방 하나에 가족과 AI 한 명이 함께 참여해 대화하고 작은 일을 끝내는 경험입니다.
[제품 비전](docs/VISION.md) · [개발 순서](docs/ROADMAP.md)

## 현재 개발 상태

**2026-09-13 방향 결정:** 전달·암호화는 Matrix 스택(단일 바이너리 홈서버 + `matrix-sdk-crypto`)을 채택하고,
가족이 보는 화면과 AI 참여 층을 직접 만듭니다. 근거와 대가는 [결정 기록](docs/DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md)에 있습니다.

| 구성 | 상태와 사용 범위 |
|---|---|
| AI 참여 서비스 (`server/`) | Go·SQLite 기반. 인증(`internal/access`)·정책 스토어·저장·이벤트를 유지하고 역할을 "채팅 서버"에서 "신원·기억·승인·에이전트 레지스트리"로 바꿉니다. 현재는 루프백·합성 데이터 시험판입니다. 실제 가족 대화를 넣거나 인터넷에 노출하지 마세요. |
| 네이티브 MLS 전송·successor 세레모니·실험 (보존 브랜치 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive)의 `archive/native-mls/`, `archive/experiments/`) | **동결·보관됨(2026-09-17 main에서 분리, 빌드·CI 제외).** 결정 D로 전달층에서는 폐기했으며, 위협 모델·기기 정책은 수용 기준으로 남깁니다. |
| Matrix 홈서버 (`deploy/tuwunel/`) | 단일 바이너리 홈서버 Tuwunel(고정 핀) 배포 패키지. 이전 Synapse/Element/Postgres 구성은 `archive/synapse-stack/`에 보관됐으며, 운영 호스트 전환은 별도 운영 작업(1단계 배포)입니다. |
| 에이전트 연결 (`scripts/fleet_*.py`) | 운영자↔봇 1:1 개인방 계약(권한·작업·승인·취소·재연결)이 검증됐습니다. 가족방·mention 모드는 1단계 작업입니다. |

AI가 참여한 방에서는 해당 에이전트가 대화를 읽을 수 있으며, 답변에 필요한 내용이
설정된 AI 제공업체에 전달될 수 있습니다. 호출 여부와 열람 권한은 다릅니다.
AI 초대 시 이 범위를 알리고 동의받는 것이 제품 요구입니다.
공개 저장소는 코드와 합성 검증 자료를 위한 공간입니다. 실제 계정·대화·첨부·키·배포 설정은 넣지 않습니다.

## 개발 시작

문서 전체 목록과 각 문서의 현행/이력/보관 상태는 [문서 색인](docs/README.md)에 있습니다.
자체 서버의 요구사항·실행법·제한은 [서버 README](server/README.md)를 따릅니다.
암호화 연구 범위는 [네이티브 E2EE](docs/NATIVE-E2EE.md), 구현 계약은
[자체 시스템 설계](docs/OWN-SYSTEM.md)를 참고하세요.

홈서버는 단일 바이너리 Tuwunel입니다. 로컬·CI에서는 루프백으로만 기동하며,
`.github/workflows/verify.yml` 통합 구간이 다음 흐름을 그대로 수행합니다:
`deploy/tuwunel/fetch-tuwunel.sh`(고정 핀 검증) → `scripts/tuwunel_config.py` 루프백 구성 검증 →
`scripts/admin.py` 계정 생성 → `tests/tuwunel_smoke.py` E2EE 암호화 왕복.
절차·검증 체크리스트는 [Tuwunel 배포 런북](docs/TUWUNEL-DEPLOY.md)을, 운영 기준은
[운영 안내](docs/OPERATIONS.md)와 [Tuwunel 운영](docs/TUWUNEL-OPERATIONS.md)을 따릅니다.
이전 Synapse/Element/Postgres 구성은 보존 브랜치 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive/synapse-stack)의 `archive/synapse-stack/`에 있으며 런타임·CI에서 쓰지 않습니다(2026-09-17 main에서 분리).

```bash
python3 -m unittest discover -s tests -v
```

## 기여와 공개 범위

재현 가능한 버그·작은 PR·제품 사용성 의견을 환영합니다. 재현 자료에는 합성 데이터를 사용하세요.
[기여 안내](CONTRIBUTING.md)와 [보안 제보](SECURITY.md)를 먼저 확인해 주세요.
음성·영상 통화는 현재 개발 범위에서 제외합니다.

직접 작성한 코드는 [MIT License](LICENSE)를 따릅니다. 외부 구성요소의 라이선스와 고지는
별도로 유지합니다: [구성요소·출처](THIRD_PARTY.md), [의존성·자원 기록](docs/DEPENDENCIES-AND-RESOURCES.md).
