# 오픈소스 비교 및 선정 — 2026-09-08

**후속 방향 변경:** 운영자가 의존성을 줄인 자체 서버/화면을 요청했다.
현재 방향과 Tinode·ntfy·Gotify의 설계 비교는 [OWN-SYSTEM.md](OWN-SYSTEM.md)에 기록했다.
아래 Matrix 채택은 기존 운영 구성을 설명하는 이력이다.

공식 GitHub의 프로젝트 설명·라이선스·최신 릴리스·Docker/설정 문서를 `gh` CLI로 확인했습니다.
GitHub 별 개수나 화면 유사성보다 가족용 대화, 독립 운영, 기기 동기화, 관리 복잡도를 기준으로 비교했습니다.

| 후보 | 가져올 점 | 이번 선택 |
|---|---|---|
| [Matrix Synapse](https://github.com/element-hq/synapse) + [Element Web](https://github.com/element-hq/element-web) | 표준 메시징 프로토콜, 개인/그룹 대화, E2EE, 멀티기기, 완성된 클라이언트 | 채택. 서버와 UI를 재사용하고 가족용 비공개 설정·브랜딩·운영 도구를 추가 |
| [Zulip](https://github.com/zulip/zulip) | 주제별 정리, 비동기 대화, 검색 | 가족 채팅보다 업무·주제별 협업에 적합. 추후 가족 공지/주제 정리 참고 |
| [Mattermost](https://github.com/mattermost/mattermost) | 채널·관리자 운영·통합 | 업무 플랫폼 성격과 구성요소별 라이선스를 고려하여 이번에는 미채택 |
| 기존 `family-os/chat_rt_server.py` | 가족용 간단한 UI, 기존 운영 경험 | Telegram Bot 연동과 자체 인증/동기화 코드를 확인. 새 메신저의 기반으로 그대로 복사하지 않음 |

## 채택한 구현

- Synapse `v1.160.0` ([릴리스](https://github.com/element-hq/synapse/releases/tag/v1.160.0))
- Element Web `v1.12.27` ([릴리스](https://github.com/element-hq/element-web/releases/tag/v1.12.27))
- PostgreSQL 17: 공식 이미지의 조회 당시 digest 고정
- 세 이미지 모두 `compose.yaml`에 tag와 digest를 함께 기록합니다. 자동 `latest` 갱신은 하지 않습니다.

## 참고한 계약·운영 지침

- [Synapse Docker 운영](https://github.com/element-hq/synapse/blob/v1.160.0/docker/README.md): 운영 PostgreSQL 사용, 데이터·서명키 보존.
- [Element Docker/설치](https://github.com/element-hq/element-web/blob/v1.12.27/apps/web/README.md): 웹과 Matrix API 도메인 분리.
- [Element 설정](https://github.com/element-hq/element-web/blob/v1.12.27/docs/config.md): 브랜드, 시작 화면, 외부 integration 비활성화, 모바일 안내.
- [Mattermost 라이선스](https://github.com/mattermost/mattermost/blob/master/LICENSE.txt): 소스·공식 배포물·구성요소의 조건이 달라 단일 MIT 제품으로 표기하지 않음.

## 기대효과와 한계

메시지는 Telegram 서버를 경유하지 않으며 Telegram의 FloodWait와 독립됩니다.
우리 Matrix 서버에도 계정 보호용 제한이 있고 서버·네트워크 장애는 가능하므로, 무제한 폴링 대신 표준 `/sync` 클라이언트를 사용하고 백업·복구를 운영해야 합니다.
Matrix 표준 채택만으로 모든 모바일 클라이언트, 푸시, 사진·영상 첨부가 자동 검증되는 것은 아닙니다. 실제 가족 기기에서 송수신·열람·재생을 별도 확인합니다. 음성·영상 통화는 개발 범위에서 제외합니다.
