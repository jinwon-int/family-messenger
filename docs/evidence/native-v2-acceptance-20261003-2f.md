# 인수검사 2-f — AI 노드 work-room 바인딩: 미초대 방 음성 대조군, 실 릴레이 (2026-10-03 08:32~09:17 KST, #243)

#225의 합성 스모크 `uninvited_room_no_join_no_decrypt_no_posts`(Welcome 0 · 입장 0 · 복호화 0 · 봇 POST 0)를
**실 릴레이**(서서 `native-relay`, main `d54ee66` clean 빌드, `-access-mode required`, 정책 체인 enforcement on)에서 재현했다.
파일럿 봇 = 공명 `bot-gongmyoung`(방 `family-acc`에만 바인딩, `watch_room: null`). 운영자 = yukson. 판정 = 오너 + 방통.
오너 승인: "2 승인"(프로브 레인 신설). 관측 창·판정 기준은 #243 코멘트 5963295690에 사전 기록.

## 구성 — 프로브 레인(봇과 **별개 신원**)

| 요소 | 값 |
|---|---|
| CF Access 서비스 토큰 | `native-relay-probe-yukson`(만료 2027-10-02). 값은 yukson `/root/.config/native-relay/probe-service-token.env`(0700/0600)에만, 어디에도 미기록 |
| Access 앱 `native-relay` 정책 | precedence 3 `non_identity`(이 토큰만). 변경 전 백업 서서 `/root/.config/cfut/backups/native-relay-policies-pre-probe-20261003T085018.json` |
| JWT | 서비스 토큰 헤더 → `CF_Authorization` 쿠키(730h, `type: app`, `sub` 빈값, `common_name` = client_id). 릴레이 subject = 그 `common_name` |
| 기기 체인(서서) | **rev 5 → 6** `native-devices -enroll-first`(actor `probe`, 기기 `probe-yukson`, fp `50d40f44…`, acceptance out-of-band). 릴레이 재시작 없음 |
| 프로브 클라이언트 | 공명 봇과 동일 바이너리 사본(sha256 `a33fd515…`) `session family-private-2f probe-yukson`, tailnet `100.127.171.124 → 100.88.73.41:18921`, `NATIVE_MLS_BOT_MAX_SECS=1500`, 신원 `ed66f53f…fb03` |

프로브는 키 패키지 1개를 게시해 방을 founding한 뒤 Welcome을 기다리기만 한다. **아무도 봇을 초대하지 않는다.**

## 수행·관측

| 시각(KST) | 사건 | 증거 |
|---|---|---|
| 08:32:56 | T0 베이스라인 | 릴레이 DB 방 1(`family-acc`) · 봇 footprint outside family-acc 0 · 봇 로그 03:06 재시작 이후 `status` 17 |
| 08:51:37–50 | 등록 전 프로브 POST 37건 | 릴레이 저널 `auth bind device=probe-yukson: not an active policy device`(403) — 미등록 기기는 방을 만들 수 없음 |
| 08:52 | 체인 rev 6 커밋 | `-inspect` revision 6, sha `5e34d332…`, probe-yukson active |
| **08:52:24** | **`family-private-2f` founding** | 릴레이 DB `mls_rooms` creator `probe-yukson`, `mls_keypackages` (probe-yukson, 1, consumed 0). 등록 후 403 0건 |
| 08:52:29 | founding 직후 스냅샷 | 방 2 · 봇 footprint 0 |
| 09:17:24 | 프로브 데드라인 종료 | 프로브 로그 `status` 569줄 전부 `joined:false, cursor 0, epoch 0`; `joined`/`welcome_ignored` 0 |
| 09:17:28 | 최종 스냅샷 | 아래 표 |

### 최종 스냅샷(09:17:28, read-only — `observe-2f.sh`)

| 판정 기준(#243 코멘트 5963295690) | 결과 | 관측 |
|---|---|---|
| ① 릴레이 DB: 봇(`bot-*`)의 `family-acc` 밖 행 | ✓ 0 | `mls_members 0 · mls_cursors 0 · mls_events 0 · mls_keypackages 0`, `family-acc` 밖 봇 대상 Welcome 0 |
| ② 공명 봇 로그(03:06 이후) | ✓ | 이벤트 `status` 17건뿐, `"room"` 언급 11,240건 전부 `family-acc`, `family-private-2f` 언급 0, `joined/welcome_ignored/application/echo/rejected` 0 |
| ③ 봇 바인딩 유지 | ✓ | 마지막 status `rooms=[{family-acc, joined:true, epoch 1, cursor 14, acked 13, echoes 6}]`(T0와 동일) |
| ④ 프로브 측 Welcome | ✓ 0 | `joined:false` 유지, 데드라인으로 종료(`session deadline exceeded`) |

릴레이 측 Welcome 이벤트는 창 전체에서 1건(`family-acc` seq 2, 01:53, 대상 bot-gongmyoung — 2-a 때의 것)뿐이다.

**판정**: 2-f 음성 대조군 **통과** — 봇은 자기 방(`family-acc`) 외의 방을 요청·입장·복호화·POST하지 않았고, 릴레이는 미등록 기기의 방 생성을 403으로 막았다.

## 발견

- 문서(ND-3641) 표기 "`common_name=<id>.access`"에서 `<id>`는 **client_id 그 자체**(이미 `.access`로 끝남) — `client_id + ".access"`를 subject로 넣으면 체인 등록이 어긋난다. 운영 스크립트는 JWT에서 `common_name`을 읽어 쓰는 공명 `jwt-refresh.sh` 방식이 맞다.
- 서서 `/opt/native-relay/bin/native-mls-bot`(sha `164c3f66…`)은 공명 가동본(sha `a33fd515…`)과 다른 빌드 — 프로브는 공명본을 썼다. 서서 사본은 봇 레인 이전 전 잔재(참고용).
- `-enroll-first`는 **새 actor**의 첫 기기라 승인 서명이 없다(E1). 같은 actor의 추가 기기(E2)는 신뢰 기기 서명이 필요하므로, 향후 AI 노드 롤아웃에서 노드마다 actor를 분리할지 한 actor 아래 E2로 묶을지는 설계 결정 사항(#243 2-f 제목의 "바인딩·오너 승인·취소 증명" 중 **승인·취소는 이 증거가 다루지 않음**).

## 증명하지 않는 것

- 봇의 **양성** 바인딩(방 초대·오너 승인·취소/revoke 흐름) — 2-b(⑤)와 향후 롤아웃 설계에서 다룬다. 이 증거는 "초대받지 않은 방에 접근하지 않는다"만 보인다.
- 봇이 Welcome을 **받았을 때** 다른 방을 거부하는 경로(`welcome_ignored`) — 릴레이가 Welcome을 대상 기기에만 전달하므로 이 창에서는 발생 조건 자체가 없었다(#225 합성 스모크가 담당).
- 사람 기기(iPhone/PC)로 만든 방 — 프로브는 기계 레인(서비스 토큰)이다. 오너 Google 세션으로 같은 절차를 하면 relay-app 워커가 저장소당 그룹 1개라 **새 저장소명**이 필요하다(`group already exists`).
- 고아 방 `family-private-2f`와 프로브 기기/토큰의 뒤처리(삭제는 오프라인 `-reset-room`·체인 `-revoke`·CF 삭제 — 별도 오너 결정).

## 재현(운영자, 아무 노드)

```sh
# 베이스라인/최종 스냅샷(read-only; ssh seoseo·gongmyoung 필요)
/root/.a2a-ops/observe-2f.sh "2026-10-03 03:06" <label>
# 프로브(등록된 기기·JWT 파일 필요)
NATIVE_MLS_BOT_MAX_SECS=1500 native-mls-bot http://<relay-tailnet>:18921 session <room> <probe-device> \
  --access-jwt-file <jwt> --state-file <state.json>
```

원본 스냅샷: yukson `/root/.a2a-ops/2f/{baseline-20261003T083256,after-found-20261003T085229,final-20261003T091728}.txt`, 프로브 로그 `/root/.a2a-ops/2f/probe/run-session.log`.
