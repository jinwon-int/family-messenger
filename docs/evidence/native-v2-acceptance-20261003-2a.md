# 인수검사 2-a — 실제 CF 게이트 + 등록 (2026-10-03 01:3x~01:5x KST, #243)

파일럿: 오너 iPhone 15 Pro·iOS 18.7 Safari(`owner-iphone`) ↔ 공명 봇(`bot-gongmyoung`). 릴레이 = 서서 `native-relay`
(main `d54ee66`, `-access-mode required`, 정적 클라이언트 `/app/`), 전달 경로 = Cloudflare Access 앱 `native-relay`
(`relay.seoyoon-family.com`, 세션 730h) → 서서 터널 → 릴레이. 운영자 = gwakga. 판정 = 오너 + 방통.

## 수행·관측

| 항목(#243 2-a) | 결과 | 관측 |
|---|---|---|
| 브라우저: CF Access 로그인 → 릴레이 contract 라우트 200 | ✓ | Access 로그 `allowed=true action=login conn=google`(00:08·이후), 릴레이 `room family-acc founded: sender=owner-iphone actor=owner` 01:53:19 — 로그인한 사람의 JWT로 `/v2/rooms/family-acc/events` POST 201 |
| 로그아웃/만료 → 401, 건강 라우트만 비인증 | 부분 | 무토큰 401·건강 200은 서버 테스트·실측(10-02)으로 확인; 사람 세션 만료(730h)는 창 안에서 관측 불가 |
| 봇: 서비스 토큰 파일 회전 중 `auth_wait` → 복귀 | 미수행 | 타이머 12h 갱신은 가동 중(공명); 회전 중 빈 파일 시나리오는 미시도 |
| 기기 바인딩: `claims.sub ≠ 기기 subject` → 403 `device_subject_mismatch` | ✓ | 등록 전 iPhone 화면 "릴레이가 이 기기를 받지 않는다(403 device_subject_mismatch)" + 릴레이 `auth bind device=owner-iphone: not an active policy device` 반복 → `-enroll-first`(subject = Access user id) 직후 0건 |
| 등록 의식: 첫 기기 = 대역외 지문(관리 선언) | ✓ | 오너가 화면의 "운영자 등록 정보"(공개키·지문 `3b64cd4d…`)를 채팅으로 전달 → CLI 등록 revision 5, CLI가 재계산한 fingerprint `3b64cd4d`와 일치 |
| 추가 기기 = 신뢰 기기 승인 서명(E2) | 미수행 | PC(`owner-pc`)는 다음 주 — `relay-app.html` §4 승인 화면으로 수행 예정 |

**왕복(2-a 통과 판정 근거)**: 오너 iPhone이 방 생성 → `bot-gongmyoung` 초대(commit seq 1 → 봇 `joined` seq 2 epoch 1 → Welcome)
→ 메시지 3건(7 B·2 B·16 B)을 봇이 복호화·echo(seq 4·6·8, `duplicate:false`), 봇 상태 `acked 7, cursor 8, echoes 3,
joined true`. 오너 채팅 진술 "통과"(01:5x KST). 릴레이 저널에 오류 없음(등록 전 403만).

## 발견

- 등록 전 403은 설계대로이나, 화면 문구만으로는 "무엇을 보내야 하는지" 오너가 바로 알지 못했다(JSON을 펼쳐 복사하는 단계 안내가 더 필요). → 클라이언트 UX 메모.
- 봇 레인은 서서가 아닌 공명(오너 지시)에서 tailnet 경유로 동작 — 봇의 평문 HTTP 제약은 WireGuard로 흡수.

## 증명하지 않는 것

- 사람 세션 만료·재로그인 UX(730h), E2 승인(PC 등록 뒤). 서비스 토큰 회전 중 `auth_wait`는 아래 추가 절에서 실측.
- 봇이 받은 평문의 내용(봇 로그는 길이만) — echo가 돌아왔다는 사실은 iPhone 화면(오너 진술)과 봇 `echo` 이벤트로만.

## 추가 — 봇 서비스 토큰 회전 중 `auth_wait` → 복귀, 재시작 없음 (2026-10-03 20:21 KST)

봇 바이너리 `cdddcfc3…`(main `6ba941cb`), 운영자 yukson, 오너 지시 "아이폰 등록한 걸로 계속 진행"(PC 등록은 뒤로).
회전 경로는 실제 운영 경로 그대로다: 토큰 파일 `/var/lib/native-relay-bot/bot/jwt`(0600, 값 비기록)를 비우고 →
`native-relay-jwt-refresh.service`(12h 타이머가 부르는 같은 유닛)로 새 JWT를 쓴다.

| 시각 | 동작 | 관측 |
|---|---|---|
| 20:21:52 | 토큰 파일 비움(0 B) | 2초 안에 `{"event":"auth_wait","room":"family-acc","device":"bot-gongmyoung"}` |
| 20:21:54 | `systemctl start native-relay-jwt-refresh.service` | 파일 864 B·0600·`native-relay-bot` 소유로 재생성 |
| 20:22~ | — | MainPID **1653637 그대로**, NRestarts 0, status `acked 19 cursor 20 echoes 9 epoch 1 halted:false` 유지 |
| 20:23 | 공명에서 릴레이 응답 상태줄만 8초 캡처(tailnet 평문 HTTP, 요청 헤더는 출력하지 않음) | `HTTP/1.1 200` **20건**, 그 외 0 |

릴레이는 요청 단위 로그를 남기지 않으므로(저널은 인증 바인딩 실패·시작·방 생성뿐), 복귀 증거는 봇 쪽 응답 코드 캡처로 대신했다.

**발견**: 봇은 `auth_wait`를 프로세스 수명 동안 **한 번만** 알린다(`auth_wait_announced`가 다시 꺼지지 않음). 복귀 이벤트도 없다.
그래서 같은 프로세스에서 두 번째 토큰 공백이 생기면 로그에 남지 않고, status 줄만으로는 인증 대기와 정상 폴링을 구분할 수 없다.
→ 후속 개선 후보: 복귀 시 `auth_ok` 이벤트를 내고 플래그를 다시 끄기.

재현(운영자, 공명):

```sh
J=/var/lib/native-relay-bot/bot/jwt; T0=$(date '+%F %T'); : > "$J"
journalctl -u native-relay-bot --since "$T0" -o cat | grep auth_wait
systemctl start native-relay-jwt-refresh.service
systemctl show native-relay-bot -p MainPID -p NRestarts
timeout 8 tcpdump -l -i any -A -s 256 'tcp src port 18921 and src host <relay tailnet ip>' | grep -aoE 'HTTP/1\.[01] [0-9]{3}' | sort | uniq -c
```
