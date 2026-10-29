# 심사용 데모 서버 설계 — `native-relay-demo` on seoseo (#584 PR 4)

> **설계 문서. 아무것도 실행하지 않았다.** 실행은 오너 승인(서서 배포·CF Access 변경·DNS = 「Fresh approval required」 항목) 뒤 별도 작업이며, 그때 이 문서를 런북으로 쓴다. 실제 호스트명·터널 ID·계정·비밀번호는 저장소에 적지 않는다(Family Wiki + 콘솔). 아래 `<domain>` 은 오너가 고르는 데모 도메인(예: `rnmaru.com` 의 하위), `<team>` 은 CF Access 팀 도메인.
>
> 결정(2026-10-29, #584): 데모 서버 = **가족 릴레이와 분리된 별도 릴레이 인스턴스**(같은 호스트 seoseo, 다른 유닛·데이터·정책 체인·포트·호스트명·Access 앱). 가족 데이터와 섞이지 않고, 심사 뒤 통째로 지운다.

## 1. 왜 별도 인스턴스인가
- 심사관 계정을 가족 릴레이의 Access 정책·정책 체인에 넣으면 가족 방 목록·기기 체인에 심사관 흔적(tombstone, 불변)이 영구히 남는다.
- 데모 릴레이는 `-reset-room`·디렉터리 삭제로 **완전 초기화**할 수 있어야 한다(가족 릴레이에서는 금지된 조작).
- 가족 릴레이의 펜스(DNS TXT)·스냅샷·전환 체계(`docs/NATIVE-RELAY-OPERATIONS.md`)와 **무관**해야 한다 — 데모는 스냅샷·펜스 대상이 아니다.

## 2. 구성 요소

| 항목 | 가족 릴레이(기존) | 데모 릴레이(신규) |
|---|---|---|
| systemd 유닛 | `native-relay.service` | **`native-relay-demo.service`** |
| 실행 계정 | `native-relay` | 같은 계정(바이너리 공유) 또는 `native-relay-demo`(권장 — `ReadWritePaths` 분리) |
| 바이너리 | `/opt/native-relay/bin/native-mls-relay` | **같은 파일**(스테이징 sha 정본, 별도 빌드 없음) |
| 데이터 | `/var/lib/native-relay/data` | `/var/lib/native-relay-demo/data` |
| 정책 체인 | `/var/lib/native-relay/policy` | `/var/lib/native-relay-demo/policy`(`native-devices -init` 으로 새 genesis) |
| 환경 파일 | `/etc/native-relay/relay.env` | `/etc/native-relay-demo/relay.env`(0600: issuer/**데모 Access 앱의 aud**/jwks) |
| 포트 | `127.0.0.1:18921` | **`127.0.0.1:18922`**(18920 = dev, 18921 = 가족) |
| 공개 호스트 | `relay.<family-domain>` · `hande.<family-domain>` | **`relay-demo.<domain>`**(API) · 선택 `hande-demo.<domain>`(웹 — 심사에는 불필요, 생략 가능) |
| `.well-known/hande` | 이름 「서윤가족」 | `-well-known-public-url https://relay-demo.<domain> -well-known-name "한데 데모"` |
| CF 터널 ingress | 기존 터널 | **기존 seoseo 터널에 ingress 규칙 추가**(`relay-demo.<domain>` → `http://127.0.0.1:18922`) — 새 터널 불필요(펜스·전환 대상이 아니므로 토큰 복제 문제도 없음) |
| CF Access 앱 | `native-relay`(가족 정책) | **새 self-hosted 앱 `native-relay-demo`**(도메인 `relay-demo.<domain>`, 정책 = 심사 계정만) + `/.well-known/hande` 전용 Bypass 앱(가족과 같은 패턴, #584 배포 코멘트) |
| APNs | `.p8` 키(가족) | **같은 `.p8`·Team ID·Key ID 재사용 가능**(토픽 = 같은 번들 ID). 푸시가 심사 노트에 적혀 있으므로 켠다. 샌드박스가 아닌 production 호스트(App Store 심사 빌드 = production aps-environment) |
| 봇 | `native-relay-bot`(공명) | **데모 봇**: 같은 `native-mls-bot` 바이너리를 데모 릴레이 URL·데모 Access 서비스 토큰으로 1개 더(유닛 `native-relay-demo-bot.service`, 공명 또는 서서) — 샘플 메시지·자동 응답·§5 자동 승인용 |

### 2-1. 유닛 파일(초안 — `deploy/native-relay/native-relay-demo.service.example` 로 올리는 것은 실행 PR 에서)
```ini
[Unit]
Description=Hande demo relay for store review (#584) — loopback 18922, CF Access required, isolated data
After=network-online.target
Wants=network-online.target

[Service]
User=native-relay-demo
Group=native-relay-demo
EnvironmentFile=/etc/native-relay-demo/relay.env
ExecStart=/opt/native-relay/bin/native-mls-relay -addr 127.0.0.1:18922 \
  -data-dir /var/lib/native-relay-demo/data -device-state /var/lib/native-relay-demo/policy \
  -access-mode required -access-issuer ${NATIVE_RELAY_ISSUER} -access-audience ${NATIVE_RELAY_DEMO_AUD} -access-jwks ${NATIVE_RELAY_JWKS} \
  -well-known-public-url https://relay-demo.<domain> -well-known-name "한데 데모" \
  -apns-key /etc/native-relay/apns/AuthKey.p8 -apns-team-id ${APNS_TEAM_ID} -apns-key-id ${APNS_KEY_ID} \
  -apns-topics com.seoyoon-family.hande \
  -app-event-ttl-seconds 604800
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/native-relay-demo
# 가족 릴레이의 fence/snapshot drop-in 을 넣지 않는다.

[Install]
WantedBy=multi-user.target
```
- `-static-dir`/`-hande-host`/`-hande-dir` 는 **주지 않는다**(relay-app·한데 웹 불필요 → 공격면 축소). `-app-event-ttl-seconds 604800`(7일)로 데모 메시지 보존을 짧게.
- APNs `.p8` 를 데모 계정이 읽을 수 있어야 한다 — 그룹 읽기 권한 또는 사본(0600). 사본은 심사 종료 시 삭제.
- `relay.env` 의 `NATIVE_RELAY_DEMO_AUD` 는 **데모 Access 앱의 aud** — 가족 앱 aud 를 쓰면 가족 로그인 세션으로 데모에 접근 가능해지므로 금지.

## 3. 심사관 로그인 방식 — 선택지와 권고

| 안 | 내용 | 장점 | 단점/리스크 |
|---|---|---|---|
| **A. Google IdP(CF Access) + 전용 심사관 Google 계정** | `reviewer@rnmaru.com` 류 Workspace 계정을 만들고 비밀번호를 심사 노트에 적는다. Access 정책 = 그 계정 1개 허용 | 앱 변경 없음, 실제 사용자 흐름 그대로 심사(2.1 충족), 가족 릴레이와 완전 분리 | **Google 새 기기 로그인 도전**(새 위치·기기에서 로그인하면 2단계 인증·전화 확인·「의심스러운 로그인」 차단 가능) → 심사관이 로그인 못 하면 거절. Workspace 비밀번호가 노트에 노출(권한 최소 계정이어야) |
| B. CF Access One-time PIN | 이메일 OTP 로그인 | 계정 비밀번호 불필요 | **심사관이 그 메일함을 못 본다** — 우리가 PIN 을 실시간으로 전달해야 해 심사 시간대(미국)에 사람이 붙어야 함. 사실상 불가 |
| C. `-access-mode disabled` 데모 릴레이 + 앱 「데모 모드」 | 인증 없는 릴레이, 앱이 로그인을 건너뜀 | 로그인 리스크 0 | **앱 코드 변경**(`/v2/me`·app-login·셀프서비스 라우트가 disabled 에서 404 → 앱이 그 경로를 우회해야 함) + **인증 없는 공개 릴레이 노출**(누구나 기기 등록·방 생성, 스팸·남용), 심사가 실제 로그인 흐름을 보지 못함(2.1 의 취지 미충족) |

**권고: A**, 다음 완화와 함께.
1. 심사관 계정은 **Google Workspace(rnmaru.com) 의 전용 사용자**로 만들고(개인 Gmail 금지 — 조직 관리 콘솔에서 보안 설정 제어 가능) **2단계 인증을 조직 정책으로 「시행 안 함」(해당 조직 단위만)**, 「덜 안전한 앱」 무관(브라우저 로그인). 관리 콘솔 → 보안 → 로그인 도전(Login challenges) 을 해당 OU 에서 **끈다**(「Employee ID 로그인 도전 사용 안 함」·비밀번호 외 추가 확인 없음). Apple 심사는 미국 IP 에서 들어오므로 로그인 도전이 가장 큰 리스크다 — 이 설정이 핵심.
2. 계정 생성 뒤 **다른 네트워크·브라우저(시크릿 창)에서 1회 로그인 테스트** — 도전 없이 로그인되는지, Access 로그인 → 앱 콜백(`hande://auth`)까지 되는지.
3. 비밀번호는 심사 노트에만(ASC 「Sign-in required」 필드). Wiki 에는 **위치만** 적는다. 계정에는 다른 Workspace 권한·메일 접근을 주지 않는다(메일은 필요 없음 — 로그인만).
4. 심사 노트에 **종료 일시**와 연락처를 적고, 심사가 끝나면 비밀번호 변경·Access 정책 제거·계정 정지(§7).
5. 플랜 B: 심사관이 Google 로그인에 실패해 거절되면 Resolution Center 에 **세션 값(JWT) 붙여넣기** 경로를 안내할 수 있다 — 앱 로그인 화면의 접힌 「운영자용」 세션 입력(Android/iOS 모두 있음). 우리가 심사관 계정으로 로그인해 받은 CF Access JWT(수명 ≤ 31일, 데모 Access 앱 세션 길이로 제한)를 Resolution Center 에 올린다. 노출 범위 = 데모 릴레이 1개, 심사 종료 시 Access 앱 삭제로 무효화. 이것은 **예비**이지 기본 경로가 아니다.

## 4. 운영자 단계(순서대로 — 실행 PR/작업에서 그대로 쓴다)

승인 범위: ①~③ 서서 호스트 변경(배포 승인) · ④⑤ Cloudflare 변경(DNS·Access = 비밀/설정 변경 승인) · ⑥ Google Workspace(오너) · ⑦⑧ 데이터 준비.

1. **디렉터리·계정**(seoseo, root): `useradd -r -s /usr/sbin/nologin native-relay-demo`; `install -d -o native-relay-demo -g native-relay-demo -m 0700 /var/lib/native-relay-demo/{data,policy}`; `/etc/native-relay-demo/relay.env`(0600, root): `NATIVE_RELAY_ISSUER=https://<team>.cloudflareaccess.com`, `NATIVE_RELAY_JWKS=https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`, `NATIVE_RELAY_DEMO_AUD=<⑤에서 받은 aud>`, `APNS_TEAM_ID`, `APNS_KEY_ID`.
2. **정책 체인 genesis**: `runuser -u native-relay-demo -- native-devices -device-state /var/lib/native-relay-demo/policy -init` → `-inspect` 로 revision 0 확인.
3. **유닛**: §2-1 을 `/etc/systemd/system/native-relay-demo.service` 로 → `systemctl daemon-reload && systemctl enable --now native-relay-demo` → `curl -s http://127.0.0.1:18922/v2/health` = `{"ok":true}` → `curl -s http://127.0.0.1:18922/.well-known/hande` 에 `relay-demo.<domain>`·「한데 데모」.
4. **CF 터널 ingress + DNS**: seoseo 터널 설정에 `relay-demo.<domain>` → `http://127.0.0.1:18922` 추가(대시보드 또는 `cfut` 래퍼, 변경 전 백업), DNS CNAME `relay-demo.<domain>` → `<tunnel-id>.cfargotunnel.com`(proxied). 확인: 외부에서 `https://relay-demo.<domain>/v2/health` 가 **302(Access 로그인)**.
5. **CF Access 앱 2개**(변경 전 앱 목록 백업 — 가족 배포와 같은 절차): (a) self-hosted `native-relay-demo`, 도메인 `relay-demo.<domain>`, 세션 길이 **24h**(심사 중 재로그인 최소화 — 가족 앱의 730h 보다 짧게), IdP = Google 만, 정책 Allow: `Emails = reviewer@rnmaru.com` + 운영자 1명(준비·확인용), 앱 런치/ App Launcher 비표시. **aud 를 `relay.env` 에** → `systemctl restart native-relay-demo`. (b) `native-relay-demo-well-known`: 경로 `relay-demo.<domain>/.well-known/hande` 정확히, 정책 Bypass Everyone(가족과 동일 패턴, 앱 `770ea51c…` 참고). 확인: 익명 `GET /.well-known/hande` 200, `/v2/health` 302.
6. **심사관 Google 계정**(오너, Workspace 관리 콘솔): `reviewer@rnmaru.com` 생성, 전용 OU → 2단계 인증 시행 안 함·로그인 도전 끔, 비밀번호 설정(ASC 노트에만). 시크릿 창에서 `https://relay-demo.<domain>/v2/me` 로 Access 로그인 → `{"subject":"reviewer@rnmaru.com", …}` 확인(subject 형식이 이메일인지 — 체인 등록에 그대로 쓴다).
7. **심사관 첫 기기 등록(E1)** — 심사관 기기 ID 는 심사관이 앱을 설치해 로그인하기 전에는 알 수 없고, 첫 기기(`first_device_out_of_band`)는 셀프서비스 대상이 아니다. **봇에 의한 자동 승인은 현 바이너리로 불가능하다**: 릴레이는 모든 요청의 JWT `sub` 를 기기의 정책 `subject` 에 묶으므로(`device_subject_mismatch`), 서비스 토큰으로 호출하는 봇은 심사관 이메일 subject 의 기기(registrar)가 될 수 없다 — 이것은 #574 의 설계 원칙이지 버그가 아니다. 따라서:
   - **7-a(기본) 운영자 수동 E1 + 알림**: 심사 노트에 「첫 로그인 뒤 앱이 지문(fingerprint)을 보여 주면 그대로 두세요. 우리가 10분 안에 승인합니다(연락처·시간대 명시)」 를 적는다. 심사관 폰이 올린 **후보 우편함**(`GET /v2/devices/candidates`, 운영자 세션 — Access 정책에 운영자 포함; 10분 TTL, 앱이 5분 전에 재게시)을 운영자가 보고 **`native-devices -device-state /var/lib/native-relay-demo/policy -enroll-first -input <후보 JSON>`**(E1, 체인에 `reviewer` 첫 기기 = registrar)로 등록한다. 후보 JSON 은 등록 화면의 운영자 JSON(`actor`·`device_id`·`fingerprint`·`signing_key`·`subject`)과 같은 모양. 심사관이 기기를 바꾸면(두 번째 폰) 같은 절차 1회 더. **ASC 심사는 통상 KST 새벽**이라 알림을 붙인다 — 데모 릴레이 로그의 후보 게시(`POST /v2/devices/candidates` 201) 또는 5분 폴링 cron → Telegram 알림; 구체 방식은 실행 작업에서 결정.
   - 7-b(대안, 릴레이 코드 변경) 「데모 서버가 특정 subject 의 첫 기기를 자동 등록」 플래그(예: `-auto-enroll-first-subject reviewer@…`, `-access-mode required` + 데모 전용) — **이 PR 범위 밖**. 심사 일정상 새벽 대응이 어렵다고 판단되면 #584 후속 이슈로 먼저 구현한다. 가족 릴레이에서는 절대 켜지 않는다.
8. **샘플 데이터**: 데모 봇(actor `bot`)을 E1 으로 등록(서비스 토큰 subject) → 봇이 방 「가족」·「사진」 2개를 만들고(로비 키 패키지 초대 흐름, `native_mls_bot_rooms_smoke.py` 와 같은 경로) 각 방에 한국어/영어 샘플 메시지 10여 개(봇이 생성, 개인정보 없음) → 심사관 기기가 등록되면 봇이 로비 키로 두 방에 **초대**(steward 흐름) → 심사관이 글을 쓰면 봇이 「네, 받았습니다 / Got it」 자동 응답(기존 responder 를 고정 답장 모드로). 봇 유닛은 데모 릴레이 URL·데모 Access 서비스 토큰(새로 발급, 데모 앱 정책에 Service Auth 허용)만 가진다.
9. **리허설**: 오너가 **새 테스트 기기**(가족 기기 아님)로 App Store 심사 빌드(TestFlight external 또는 Ad Hoc)로 §2 심사 노트 1~5 를 그대로 따라 해 본다 — 서버 찾기 → Google 로그인(도전 없음) → 등록 대기 → 운영자 E1 → 방 2개·샘플 메시지 → 전송·봇 답장 → 푸시 수신. 걸린 시간을 기록해 노트의 「10분 안에」 문구를 맞춘다.
10. **Android 심사(Play App access)**: 같은 서버·계정을 Play Console 「App access」 에 적는다(최대 5세트 — 1세트). Play 는 자동 심사 비중이 커서 사람이 로그인 안 할 수도 있다 — 그래도 유효 기간 내 유지.

## 5. 시한 — 종료 일시를 절대시각(KST)으로

플릿 규칙(「시한부 테스트 종료일시」 2026-09-11): 데모 서버·심사관 계정은 **사람이 판정해야 끝나는 날짜 단위 관측**이므로 추적 이슈(#584 또는 후속 「데모 서버 운영」 이슈)에 다음 4항목을 코멘트한다.
- 시작 일시(KST): 데모 서버 기동 시각
- **종료 일시(KST 절대시각)**: 예) `2026-11-30 23:59 KST` — iOS·Android 양쪽 심사 승인 뒤 +7일을 상한으로 잡고, 심사가 길어지면 **새 종료일시로 재코멘트**(상대 기간 금지)
- 종료 시 확인할 지표·명령: `systemctl is-active native-relay-demo` = inactive, CF Access 앱 `native-relay-demo`·`…-well-known` 삭제 확인(`cfut` 목록), DNS CNAME 삭제, Workspace 계정 정지, ASC 심사 노트의 비밀번호 제거, `/var/lib/native-relay-demo` 부재
- 판정 주체: 오너(스토어 승인 확인) + 실행 노드(teardown 수행·증거)

심사 노트 「Demo credentials valid until」 에 같은 날짜를 적는다.

## 6. 안전 경계
- 데모 릴레이는 가족 릴레이의 **데이터·정책 체인·Access 앱·aud·봇 토큰을 하나도 공유하지 않는다**. 공유하는 것은 바이너리·APNs 키·CF 터널·호스트뿐.
- 가족 릴레이 유닛·drop-in·fence·snapshot 설정은 건드리지 않는다. `gwakga-broker-public-tunnel.service` 등 A2A 인프라와 무관.
- 데모 릴레이에 가족 구성원 계정을 Access 정책에 넣지 않는다(운영자 1명 예외, 확인용).
- 심사관 계정은 데모 릴레이 외 어떤 Access 앱 정책에도 넣지 않는다.
- 로그에 심사관 이메일이 남는다(subject) — 정상, 종료 시 데이터 디렉터리와 함께 삭제.

## 7. 철거(teardown)
1. 양쪽 스토어 승인 확인 + §5 종료 일시 도달(또는 오너 지시).
2. `systemctl disable --now native-relay-demo native-relay-demo-bot` → `rm -rf /var/lib/native-relay-demo /etc/native-relay-demo` → `userdel native-relay-demo` → APNs 키 사본 삭제(사본을 만든 경우).
3. CF: Access 앱 2개 삭제(변경 전 백업), 서비스 토큰(봇) 폐기, 터널 ingress 규칙 제거, DNS CNAME 삭제.
4. Google Workspace: `reviewer@` 비밀번호 변경 → 정지(또는 삭제). ASC 심사 노트에서 비밀번호 제거(「Sign-in required」 유지하되 다음 심사 때 새 값).
5. 추적 이슈에 종료 코멘트(증거: 위 §5 지표 출력).
6. 다음 버전 심사(업데이트)에도 로그인 계정이 필요하다 — Apple 은 업데이트 심사에서도 데모 계정을 쓴다. **재심사 때마다 1~4 를 다시 세우는 대신**, 데모 릴레이를 **중지 상태로 보존**(디렉터리 유지, Access 정책에서 심사관 이메일만 제거)하는 선택지를 오너가 고른다. 보존을 고르면 §5 의 종료 일시를 「다음 재가동 전 점검일」로 다시 잡는다.

---

## English summary
A **separate relay instance** (`native-relay-demo.service`, own data/policy dirs, loopback port 18922, own hostname `relay-demo.<domain>` via the existing Cloudflare tunnel, own Cloudflare Access application and audience) runs on the same host as the family relay but shares nothing but the binary. Reviewer login: option **A — Google IdP through Cloudflare Access with a dedicated Workspace account** (`reviewer@rnmaru.com`-style, password only in App Store Connect review notes), with Google login challenges disabled for that OU and a cross-network rehearsal; OTP (B) is unworkable for reviewers, and an unauthenticated relay plus app demo mode (C) needs app changes and exposes an open relay. The reviewer's first device must still be enrolled by the operator (E1) because the relay binds devices to the login subject — the steps include a candidate-mailbox watch so enrollment happens within minutes. Sample rooms and messages come from a demo bot. The review window end is recorded as an absolute KST datetime on the tracking issue; teardown removes the unit, data, Access apps, DNS, bot token and the reviewer account. Nothing here has been executed.
