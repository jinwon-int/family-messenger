# 인수검사 2-c — iOS 홈 화면 PWA (실 릴레이, 오너 손, 2026-10-06 14:48~14:59 KST, #243 조건 ③)

기기: 오너 iPhone 15 Pro·iOS 18.7, Safari "홈 화면에 추가"로 설치한 PWA(standalone). 릴레이 = 서서 `native-relay`(`d47fd52a`), 클라이언트 = main `04190a3` 번들.
운영자 = bangtong(체인 CLI), 승인·초대 = 오너 PC `owner-pc`. 판정 = 오너 + 방통.

## 핵심 발견 — PWA는 Safari와 **다른 기기**다

| 시각 | 시도 | 결과 |
|---|---|---|
| 14:48:12 | PWA에서 Safari와 같은 값(`owner-iphone-2` · DB `…-acc-1` · 같은 암호)으로 `워커 시작 · 이어하기` | **새 지문·`joined=false`** — PWA의 IndexedDB·localStorage가 Safari 탭과 분리돼 빈 저장소에 새 키가 만들어졌다(`relay seq 0`). Access 쿠키도 따로(재로그인) |
| 14:50:57~14:51:49 | 같은 DB에서 기기 ID만 `owner-iphone-pwa`로 바꿔 시작 | `실패: Error: init 거부` ×3 — DB 1개 = 신원 1개(이미 `owner-iphone-2` 키가 들어 있음) |
| 14:53:07 | **새 DB `family-mls-synthetic-acc-pwa` + `owner-iphone-pwa` + 새 암호** | 워커 시작 → 403 `device_subject_mismatch` "운영자 등록 대기"(릴레이 14:53:51) |

→ iPhone에서 Safari 탭과 PWA를 둘 다 쓰면 **기기 2대로 등록**해야 하고, 같은 DB 이름을 재사용하면 `init 거부`가 난다. 사용자 안내(#290 계열)와 런북에 적을 사항.

## 등록·왕복·백그라운드

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| E2(승인자 PC) | 14:5x | ✓ | 운영자 fp 재계산 일치 `264d31e3…`; PC §4 서명(`approved_by: owner-pc`) → **14:56:19 `-add-device -expected-revision 12` → rev 13** `0e6c50b5…`. owner 활성 **4대**(pc·iphone-2·android·iphone-pwa) = actor 상한 |
| 키 패키지 → PC 초대 → 참여 | 14:56:48 → 14:57:08 → 14:57:10 | ✓ | PWA "키 패키지 게시(저장)"(중복 클릭 1회는 `중복`) → PC 초대 commit seq **59**(epoch 7→**8**) + welcome 60 → PWA "참여 완료(seq 60) — 멤버 5"; 봇 `commit_applied adds=[owner-iphone-pwa] outer_checked:true` |
| 송수신 | 14:57:38 | ✓ | PWA seq **61**(2 B) → 봇 echo 62 |
| **백그라운드 복귀 해독** | 14:58:03 → 14:59 | ✓ | PWA를 홈으로 내보낸 뒤 PC seq **63** `pwa-bg`(14:58:03) 도착 → 복귀 후 오너 진술 **"뜬다 `[63] owner-pc: pwa-bg`"** (+ echo 64) |
| 릴레이 | 14:59 | ✓ | 등록 후 PWA 거부 0, 오류 0, 무재시작 |

## 판정 제안(#243 2-c iOS "PWA 포함")

- PWA 동작 ✓ — 단, **별도 기기**로서. 체크박스 괄호 "PWA 미수행" → "PWA = 별도 기기 등록 뒤 동작 ✓(`…2c-pwa.md`)".

## 증명하지 않는 것

- PWA 화면 캡처(오너 진술·서버 이벤트로). 이탈 시간은 ≥ 수십 초(정확 측정 없음). 잠금화면 알림은 iOS Safari 2-c(10-03)와 동일 조건(클라이언트가 알림을 만들지 않음)으로 재검사 생략.
- PWA 저장소의 iOS 7일 미사용 축출(별도 장기 관측).
- 처음 PWA에서 만들어진 미등록 `owner-iphone-2`(PWA 저장소, DB `…-acc-1`) 키는 체인에 없어 무해하나 정리(PWA `저장소 삭제`)는 미수행.
