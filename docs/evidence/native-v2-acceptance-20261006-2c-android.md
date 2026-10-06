# 인수검사 2-c — Android Chrome(실 릴레이, 원격 조작) + 2-d 전체 번들 재배포 (2026-10-06 13:5x~14:39 KST, #243 조건 ①·③)

기기: 공융 **SM-G781N(Galaxy S20 FE, Android 13) 물리 기기**, 오너 계정 폰(사용자 "Seo Jin on"), **Chrome 154.0.8037.126**, 기기 `owner-android`
(DB `family-mls-synthetic-acc-android`, 암호는 운영자 생성·bangtong 로컬 0600 보관). 조작 = 공융 Termux ssh → adb 셀프루프(`127.0.0.1:5555`) →
`adb forward tcp:9222 localabstract:chrome_devtools_remote` → bangtong `ssh -L 9222` → Playwright `connect_over_cdp`(M4 10-02와 같은 경로). 사람 손이 아닌
**원격 자동화 조작**이며 headless·에뮬레이터·UA 변조 없음(REAL-DEVICE §5 진술 — 운영자 bangtong). 승인·초대는 오너 PC `owner-pc`가 손으로. 봇 = 공명.
릴레이 = 서서 `native-relay`(`d47fd52a`, PID 1941712, 무재시작). **클라이언트 번들 = main `04190a3` 전체**(아래 2-d).

## 2-c Android — 수행·관측

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| CF Access 로그인 | 13:54 | ✓ | Chrome이 `/app/`에서 Access 로그인 페이지로 → CDP로 "Google" 클릭 → 폰의 Google 세션으로 **자동 통과**(비밀번호 입력 없음) → `/app/` |
| 워커 시작 → 등록 전 403 | 13:55:57 | ✓ | `owner-android @ family-mls-synthetic-acc-android (relay seq 0, joined=false)`; 릴레이 `auth bind device=owner-android: not an active policy device` 13:56:09~ |
| E2(승인자 PC) | 14:2x | ✓ | 운영자 fp 재계산 일치 `2f3d7e12…`(폰 화면 캡처로도 대조); 오너 PC §4 서명(`approved_by: owner-pc`) → **14:28:16 `-add-device -expected-revision 11` → rev 12** `4cbb159b…`(owner 활성 3: pc·iphone-2·android) → 거부 0 |
| 키 패키지 → PC 초대 → 참여 | 14:28:47 → 14:29:18 → 14:29:21 | ✓ | Android "키 패키지 게시(저장)" → PC 초대 commit seq **53**(epoch 6→7) + welcome 54 → Android "참여 완료(seq 54) — 멤버 bot-gongmyoung, owner-android, owner-iphone-2, owner-pc"; 봇 `commit_applied adds=[owner-android] outer_checked:true` |
| 송수신 | 14:3x | ✓ | Android seq **55** `android-hello`(235 B) → 봇 echo seq **56** → Android 화면 `[56] bot-gongmyoung: android-hello`(복호화) |
| **백그라운드 복귀 해독** | 14:32:06 → 14:38:55 | ✓ | HOME + `KEYCODE_SLEEP`(화면 OFF, `mWakefulness=Dozing`, 포커스 NotificationShade) → 이탈 중 PC seq **57** `bg-test` 14:38:05 도착 + 봇 echo 58; Android 릴레이 커서 **56 고정**(잠든 동안 폴링 없음) → 14:38:55 `KEYCODE_WAKEUP` + Chrome 전면 → **14:39:06 `[57] owner-pc: bg-test` `[58] bot-gongmyoung: bg-test` 복호화 표시**, 커서 58. 이탈 **6분 49초**(≥60 s) |
| **잠금화면 노출 없음** | 14:32~14:38 | ✓ | 화면 꺼진 동안 `dumpsys notification --noredact`의 relay/seoyoon/Chrome 항목 기준선 대비 **차이 0** — 이 클라이언트는 알림을 만들지 않는다 |
| 저장소 축출 rejoin | — | 미수행 | iOS 실 릴레이 실측(`…2c-rejoin.md` #288)과 M4 킷 Android 합성(10-02)으로 갈음 |
| 릴레이 | 14:39 | ✓ | 등록 후 Android 거부 0, 오류 0, 무재시작 |

## 2-d 전체 번들 재배포 (조건 ①, 14:01:12 KST)

- **재현 빌드(곽가)**: clean 클론 `/root/fm-deploy-4e75aca`(main `4e75aca`), 핀 툴체인(rustc 1.91.1 · wasm-bindgen 0.2.126 musl sha 고정 · esbuild 0.27.2, `npm ci --ignore-scripts`) `build.sh` → `sha256sum -c --strict bundle-sha256.txt` **3/3** — wasm `0d27d28f…` · js `d9a05287…` · custody `b94b2180…` = 커밋 매니페스트 = CI → **재현 ✓**.
- **배포(서서, 무재시작)**: 스테이징 20파일 검증 → 서빙본 대비 차이 2파일(wasm·매니페스트)만 교체 + #298 머지분 `relay-app.html`·`relay-app.js` 동시 설치(오너 "번들 배포 승인") → 루프백 서빙 해시 **18/18 == main `04190a3`**(web 15 + pkg 3) · `GET /app/pkg/bundle-sha256.txt` == 커밋본 **IDENTICAL** · MainPID 1941712 · `/v2/health` 200. 백업 `/root/native-relay-staging/static-pre-full-20261006T140112.tgz`. Android 세션은 이 번들로 수행(13:54 로드).

## 판정 제안(#243)

- 2-c **Android Chrome: 동일 3항목** → ✓(백그라운드 복귀 해독·잠금화면 노출 없음은 실 릴레이·물리 기기 실측; 축출 rejoin은 갈음 명시).
- 2-d **서빙 번들 == 매니페스트·재현 빌드** → ✓(혼합 상태 해소). 릴레이 바이너리 독립 재빌드 대조는 그대로 미수행.

## 발견

- 가로 모드에서 `#send` 버튼이 `#sync`와 겹쳐 Playwright 히트테스트 클릭이 막혔다(`subtree intercepts pointer events`) — DOM `click()`으로 우회. 사람 손가락으로도 겹칠 수 있는지 세로 모드 확인 필요(UX 후보).
- 암호 입력 때 Google 비밀번호 관리자 자동완성 시트(다른 사이트 저장 로그인)가 떴다 — BACK으로 닫음, 선택·저장 없음. `autocomplete="off"`는 Android Chrome에서 무시되는 듯 → `autocomplete="new-password"` 후보.
- CF Access는 폰의 Google 세션으로 무입력 통과 — 오너 계정이 로그인된 기기라면 Access 게이트는 사실상 기기 소유에 묶인다(설계 메모).

## 증명하지 않는 것

- 사람 손 조작(원격 자동화·운영자 진술). 세로 모드 레이아웃. Android 축출 rejoin(갈음). 알림 검사는 `dumpsys` 텍스트 비교(화면 캡처 아님).
- 이탈 중 Chrome이 완전히 정지됐는지(커서 고정으로 간접). 릴레이 바이너리 독립 재빌드.

## 재현(운영자)

```sh
ssh gongyung 'adb -s 127.0.0.1:5555 forward tcp:9222 localabstract:chrome_devtools_remote'
ssh -f -N -L 9222:127.0.0.1:9222 gongyung
python -c "from playwright.sync_api import sync_playwright as s; ..."   # connect_over_cdp('http://127.0.0.1:9222')
ssh gongyung 'adb -s 127.0.0.1:5555 shell input keyevent KEYCODE_HOME; adb -s 127.0.0.1:5555 shell input keyevent KEYCODE_SLEEP'   # 이탈
ssh gongyung 'adb -s 127.0.0.1:5555 shell "dumpsys notification --noredact" | grep -i -E "relay|seoyoon"'                             # 잠금화면 알림
```
