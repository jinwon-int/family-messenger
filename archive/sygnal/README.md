# archive/sygnal/ — 퇴역한 웹 푸시 게이트웨이 Sygnal

Matrix 웹앱(`web/app/`)의 웹 푸시를 맡던 Sygnal 배포 패키지와 런북이다.
[#787](https://github.com/jinwon-int/family-messenger/issues/787) 체크리스트에 따라 퇴역했다.

| 일시 (KST) | 단계 |
|---|---|
| 2026-11-13 10:49 | 운영 호스트에서 `sygnal` 중지·비활성화(§3), 웹앱 `config.json`에서 `push` 제거(§1) |
| 2026-11-20 11:00 | 7일 관찰 종료, 판정 PASS |
| 2026-11-20 | 이 디렉터리로 옮김(§6) |

## 구성

원래 상대 경로를 유지하도록 옮겼다. 문서 안 링크와 테스트의 경로 계산이 그대로 맞는다.

| 경로 | 원래 위치 |
|---|---|
| `deploy/sygnal/` | `deploy/sygnal/` |
| `docs/SYGNAL-DEPLOY.md` | `docs/SYGNAL-DEPLOY.md` |
| `tests/test_sygnal_deploy_package.py` | `tests/test_sygnal_deploy_package.py` |

## 규칙

- 운영 대상이 아니다. 기본 CI(`verify.yml`의 `unittest discover -s tests`)는 이 테스트를 더 이상 실행하지 않는다.
  필요하면 `python3 -m unittest discover -s archive/sygnal/tests`로 직접 돌린다.
- 웹앱의 push 코드(`web/app/src/push.js`, `sw.js` push 핸들러, 관련 테스트)는 #787 D1=①에 따라
  웹앱 퇴역 때 함께 정리한다. 그 코드의 주석에 남은 `SYGNAL-DEPLOY.md`·`deploy/sygnal/` 참조는 이 디렉터리를 가리킨다.
- 남은 운영 단계(Cloudflare `push.` 인그레스 제거 §4, VAPID 키 삭제 §5)는 #787에서 별도 승인으로 진행한다.
  웹 푸시를 되살리려면 이 패키지와 런북을 따른다. §5 이후에는 키 재생성과 모든 기기의 재구독이 필요하다.
