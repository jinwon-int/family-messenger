# 파일럿 F — iOS 네이티브 앱 「한데」 1차 실사용 검증 (2026-10-13 16:3x ~ 10-14 11:33 KST, #271 §12-F · #243)

파일럿: 오너 iPhone **한데 앱**(TestFlight 0.1.0 build 9/10, 기기 `owner-iphone-27a879`, aps-environment=production)
↔ 오너 PC 브라우저 relay-app(`owner-pc`, CF Access 로그인) ↔ 공명 봇(`bot-gongmyoung`). 릴레이 = 서서 `native-relay`
(`-access-mode required`, 정책 rev 16, 정적 클라이언트 `/app/`, APNs 직접 전송). 운영자 = **seoseo**(릴레이·DB·로그 관측,
PR·배포), 판정 = 오너. 이 문서는 #271 §12 **D(푸시)·E(화면 일부)·F(파일럿)** 의 첫 실기기 증거다.

## 전제 변경(10-13, 이 검증 중 발견·수정)

| 블로커 | 원인 | 수정 |
|---|---|---|
| build 7 에서 방에 들어갈 수 없음 | 앱에 키 패키지 게시 화면이 없음(`requestJoin` API만) → relay-app `초대`가 소비할 패키지가 없음 | [#347](https://github.com/jinwon-int/family-messenger/pull/347) 대화 목록 `+` 참여 요청 화면 |
| 등록 JSON `subject` 공란 | 앱이 CF Access `sub`를 채우지 않음 | #347 `AccessJWT`(검증 아님; 릴레이 403이 권한 경계) |
| build 8 업로드 거부 `bundle version must be higher than … '1'` | `project.yml` info.properties 에 버전 키 없음 → xcodegen 이 `CFBundleVersion "1"` 리터럴 | [#348](https://github.com/jinwon-int/family-messenger/pull/348) `$(CURRENT_PROJECT_VERSION)` 연결 + 아카이브 검증 단계 |
| ASC `MISSING_EXPORT_COMPLIANCE` 로 그룹 미배포 | 수출 규정 미답변 | API `usesNonExemptEncryption=false`(build 9) → [#349](https://github.com/jinwon-int/family-messenger/pull/349) `ITSAppUsesNonExemptEncryption=false`(build 10부터 자동) |
| CLI 가 relay-app 증거 JSON 거부(`unknown field fingerprint`) | `addDeviceCandidate` 6필드 strict | [#350](https://github.com/jinwon-int/family-messenger/pull/350) `fingerprint`·`approved_by` 수락+교차검증, 서서 CLI 교체(sha256 `21463909…`) |

## 수행·관측 (10-14)

| 단계 | 시각(KST) | 결과 | 관측(릴레이 DB `native-mls-v2.db` 읽기 전용 · `journalctl -u native-relay`) |
|---|---|---|---|
| 기준선 | 10:00 | — | `family-acc` epoch 10 / last_seq 66 / 멤버 `bot-gongmyoung`·`owner-pc`·`owner-iphone-2`; `push_devices`에 `owner-iphone-27a879` 토큰(10-13 16:33 등록); 키 패키지 `3b7ad903…`(10-13 19:41 게시, 미소비, 만료 10-20) |
| ③ PC `초대 → owner-iphone-27a879` | **10:51:33** | ✓ | seq **67** `commit`(owner-pc, epoch 10→11) · seq **68** `welcome` targets=`owner-iphone-27a879`; `mls_members` 4대; 키 패키지 `consumed_by=owner-pc`. 오너 안내 오류 1건: 정적 경로는 `/app/relay-app.html`(루트 404) |
| ④ 앱 참여·왕복 | 11:01:44 | ✓ | 앱이 Welcome 처리(커서 67→70) 후 **iPhone 발신** seq **69** application → 봇 echo seq 70(1초). 11:11:30 seq 71(iPhone)·72(봇) 반복. PC→iPhone 수신 표시는 ⑤에서 확인 |
| 푸시 결함 발견 | 10:51:34 · 11:01:45 | ✗→수정 | 릴레이 APNs: seq 68·70 → **`403 BadEnvironmentKeyInToken`**. 포털: 키 `275SUYQ6WJ` = `Team scoped (All topics) [Sandbox]`. 진단 전송(오너 승인, 같은 키·빈 페이로드): sandbox 호스트 `400 BadDeviceToken`(토큰은 production) / production `403 BadEnvironmentKeyInToken` → **키가 Sandbox 전용** 확정 |
| 키 교체·릴레이 재시작 | **11:10:13** | ✓ | 새 키 `4DGQ2672TA`(Sandbox & Production, 오너 생성 → 보관함 → 서서 `/etc/native-relay/apns/`, native-relay 0600, 사본 shred) · drop-in `-apns-key`/`-apns-key-id`만 교체(백업 `20-apns.conf.sandboxkey-bak-20261014T1108`) · 오너 "릴레이 재시작 승인" → `apns push on (host https://api.push.apple.com)`, health 200, rev 16. 앱은 11:01:19 토큰 재등록 |
| ⑤ 백그라운드 푸시 | **11:27:10 · :22** | ✓ | PC 발신 seq **73**·**75** + 봇 echo 74·76. 릴레이 APNs 오류 **0건**(성공은 무로그 → 4건 Apple 200). 오너: 알림 배너 수신("PC에서 보내니까 알림 다 나온다"). ※ 앞선 11:11 시도는 iPhone 자신이 발신(릴레이는 발신 기기에 푸시하지 않음)+포그라운드라 배너 없음이 정상 |
| ⑥ 앱 종료 후 푸시 | **11:31:42** | ✓ | PC seq **77** + 봇 78, APNs 오류 0. 오너: 알림 도착, **탭 → 앱 열리며 메시지 표시**. iPhone 커서 72→**78**(앱 복귀 시 ack) |
| ⑦ 잠금화면 | **11:33:08** | ✓ | PC seq **79** + 봇 80, APNs 오류 0. 오너: **잠금화면에 복호화 본문 표시**, 알림은 1개로 보임(푸시 2건 → `thread-id` 그룹핑 추정). 커서 78 유지(잠금 중 ack 없음 — NSE는 ack 하지 않는 설계) |
| ⑧ iPhone 발신 | 11:01:44 · 11:11:30 | ✓ | seq 69·71(앱 → 릴레이 201 → 봇 복호화·echo) — ④에 포함 |

## 판정 제안(#271 §12 수용 기준 대비)

- **D 푸시**: "앱 종료 상태 10건 중 10건 도착·≥9건 본문" — 이번 실측은 종료 1건·백그라운드 2건·잠금 1건(PC 발신 기준) 모두 도착·본문 복호화(잠금화면 본문 확인). **표본 4건으로 통과 방향, 10건 표본은 후속 세션**. 실패 대체 알림(`NEW_MESSAGE` 문구)은 관측되지 않았다(NSE 실패 0).
- **E 화면**: 참여 요청(`+`)·방 목록·방 화면·송신 동작. 방 만들기/초대 화면은 여전히 없음(relay-app 의존) — §12-E 후속.
- **F 파일럿**: 등록(E2, 10-13) → 초대 → 왕복 → 푸시 3종 ✓. **#243 2-c의 네이티브 앱 열**(백그라운드 복귀 해독 ✓ / 잠금화면 노출 = 본문 표시[미리보기 설정 의존, 확인 필요] / 축출 rejoin 미수행)로 기록 제안.

## 발견·후속

- APNs 키 환경은 포털에서 생성 시 선택이며 `[Sandbox]`로 만들어진 키는 production 에서 `BadEnvironmentKeyInToken`. 운영 메모: 키 생성 시 **Sandbox & Production** 확인, 릴레이 로그의 403 reason 을 그대로 읽을 것. 옛 키 `275SUYQ6WJ` 는 오너 Revoke 예정(서버 사본 `AuthKey_275SUYQ6WJ.p8` 는 Revoke 뒤 삭제).
- 릴레이는 **발신 기기에는 푸시하지 않는다**(`pushTargets p.device <> sender`) — 자기 기기에서 보내고 알림을 기대하면 "안 온다"로 보인다. 안내 문구에 반영.
- NSE 는 ack 를 보내지 않아 릴레이 커서는 앱이 열릴 때까지 뒤처져 보인다(설계). 커서를 "읽음"으로 해석하지 말 것.
- 푸시 2건(PC+봇 echo)이 알림 1개로 보임 — `thread-id` 그룹핑인지 봇 echo 알림 억제인지 확인 필요(iOS 알림 센터 펼침 확인).
- 미착수: 앱 `joinDefaultRoom="family-acc"` 하드코딩(가족 투입 전 설정값으로), 방 만들기/초대 화면(§12-E), WKWebView 로그인(§12-C), 가족 Apple ID 내부 그룹 추가(오너 결정), D 10건 표본.

## 증명하지 않는 것

- 앱·NSE 측 로그(복호화 경로·`decryptedBy`)는 수집하지 않았다 — 오너 진술(배너 본문·잠금화면 본문·탭 복귀)과 릴레이 측 "APNs 오류 0 + 이벤트 생성 시각"으로 판정. Apple 200 응답은 **배달 시도 수락**이며 단말 표시의 증명은 오너 관측이다.
- 2-c 저장소 축출 rejoin(앱 삭제 → 재설치 → 새 기기 등록)은 수행하지 않았다.
- 10건 표본·장시간(≥5 min) 백그라운드 복귀 해독은 측정하지 않았다(이번 백그라운드 구간은 수 분).
- 봇 echo 가 푸시로도 왔는지(2건→1 알림)는 확정하지 않았다.
