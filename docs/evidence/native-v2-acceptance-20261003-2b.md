# 인수검사 2-b — 복구·백업 5연산 (부분: 봇 영속 신원 재시작, 2026-10-03 11:17 KST, #243)

**상태: 부분 증거.** 2-b 중 "봇 영속 신원"(계획 재시작 11:17 + SIGKILL 20:24)과 recover-all-lost의 "서버 에스크로 없음·복구 비밀 미노출" 부분(20:2x)을 다룬다. restore-history는 **범위 안** 절반을 2026-10-04에 실측했다(추가 3). add-device·revoke(E3)·recover-all-lost 실연·restore-history **범위 밖**(gap → 재참여)은 PC(`owner-pc`) E2 등록 뒤(#243 ⑪) 또는 별도 승인 뒤로 미룬다 — 이 파일에 추가 커밋으로 이어 쓴다.

파일럿 봇: 공명 `native-relay-bot`(`bot-gongmyoung`, 바이너리 sha `a33fd515…`, `--state-file /var/lib/native-relay-bot/bot/state.json`), 릴레이 = 서서 `native-relay`(main `d54ee66` clean), tailnet 경유. 운영자 = yukson. 오너 사전 고지·승인: "권장대로 진행"(⑤-1 지금 재시작). 판정 = 오너 + 방통.

## 계획 재시작 (11:17:29 KST)

| 항목 | 재시작 전 (11:1x) | 재시작 후 (11:17:29~) |
|---|---|---|
| 유닛 | MainPID 1520242, `ActiveEnter` 03:06:46, NRestarts 1 | MainPID 1597141, `ActiveEnter` 11:17:29, NRestarts 0, active |
| 신원 | 공개키 `d019d6df…8a67`(체인 rev 6 fp `635fdfb3…`) | `{"event":"identity","public_key":"d019d6df…8a67","restored":true}` — **같은 키** |
| ready | — | `{"event":"ready","restored":true,"room":"family-acc","key_ref":null}` (재시작 후 수 초 내) |
| 방 상태 | `acked 13, cursor 14, echoes 6, epoch 1, joined true` | **동일** `acked 13, cursor 14, echoes 6, epoch 1, joined true` |
| 상태 파일 | 19,603 B, mtime 02:09:21 | 19,603 B, mtime 02:09:21 — **재시작이 상태를 다시 쓰지 않음** |
| 릴레이 DB | `mls_cursors (family-acc, bot-gongmyoung) = 13`, 방 max seq 14 | 동일(13 / 14) |
| 릴레이 저널 | — | 11:17 이후 403/error 0 |

`key_ref: null`은 봇이 이미 그룹에 있어 새 키 패키지를 게시하지 않았다는 뜻(재시작 전 Welcome 재요청 없음). `restored:true`가 `identity`·`ready` 양쪽에 찍혀, 상태 파일에서 MLS 그룹 상태(epoch 1)와 서명 키를 복원해 **재초대 없이** 같은 리프로 복귀했음을 보인다.

## 비계획 재시작 1회 (03:06:46 KST, 참고)

2-d 바이너리 교체로 서서 릴레이가 03:06:36에 재시작되는 동안 봇이 `io error: Connection refused`로 종료 → systemd `Restart=`로 1회 자동 재기동 → `identity/ready restored:true`, 이후 03:06~11:17 사이 `status` 17건 모두 `cursor 14`. 계획 재시작과 같은 결과였고, 릴레이 재시작 시 봇의 열린 fetch가 끊기는 운영 특성(DOC-3645 ③ 메모)을 실측으로 확인한 셈이다.

## 추가 1 — SIGKILL 뒤 영속 신원 (2026-10-03 20:24 KST)

봇 바이너리 `cdddcfc3…`(main `6ba941cb`, #263 commit 검사 포함). 오너 지시 "아이폰 등록한 걸로 계속 진행".

| 항목 | 전 (20:24:07) | 후 |
|---|---|---|
| 유닛 | MainPID 1653637, NRestarts 0 | `kill -9` → `code=killed, status=9/KILL` → `Restart=on-failure` 10 s 뒤 MainPID **1679773**, NRestarts 1, active |
| 신원 | 공개키 `d019d6df…8a67` | `identity`·`ready` 모두 `restored:true`, **같은 키** |
| 방 상태 | `acked 19, cursor 20, echoes 9, epoch 1, halted false, joined true` | **동일** |
| 상태 파일 | mtime 13:11:20 | mtime 13:11:20 — 마지막 메시지 이후 쓰기 없음, SIGKILL로 손상 없음 |
| 릴레이 응답 | — | 재기동 직후 6초 캡처 `HTTP/1.1 200` 15건, 그 외 0 |

**증명하지 않는 것**: "echo 카운터 무재사용"은 재기동 뒤 첫 echo가 있어야 직접 확인된다(오너 메시지 없음). 오너의 다음 메시지에 대해 봇 로그에 `echo_client_id_reuse`가 없고 echo `client_id`가 이전과 겹치지 않으면 통과다. #230·#238 스모크가 같은 성질을 CI에서 확인한다. → **2026-10-04 직접 확인(추가 3)**: SIGKILL 뒤 첫 echo가 `echo-10`(seq 22)이고, 이후 재기동 뒤에도 `echo-11`·`echo-12`로 이어졌다.

## 추가 2 — recover-all-lost 중 "서버 에스크로 없음·복구 비밀 미노출" (2026-10-03 20:2x KST, 정적·라이브 감사)

전 기기 분실 실연(새 방·옛 방 읽기 전용)은 오너 기기를 실제로 버려야 하므로 파일럿 끝(또는 PC 등록 뒤)으로 미룬다. 여기서는 그 전제인 "서버가 복구 비밀을 갖고 있지 않다"만 증명한다.

1. **릴레이 DB(라이브, 서서 `native-mls-v2.db`, read-only)**: 테이블은 5개뿐이다.
   `mls_rooms`(room, group_id, epoch, revision, last_seq, created_at, closed_at, creator) ·
   `mls_events`(… `bytes` = MLS 암호문, sha256) · `mls_keypackages`(공개 키 패키지) ·
   `mls_cursors` · `mls_members`(device, actor). 개인키·금고·복구 비밀을 담는 열은 없다.
2. **클라이언트 코드(main `6ba941cb`)**: 네트워크 호출은 `web/relay-app.js`의 `api()` 하나(`fetch`)뿐이다. 호출처는 events POST/GET(+ack), keypackages POST/GET 다섯 곳이고, 본문은 암호문·키 패키지·`members`·커서다.
   `durable-worker.js`·`session-store.js`에는 `fetch`/XHR/`sendBeacon`/WebSocket이 0건이다. 암호(32–128자)는 `callWorker('init', …)`로 워커에만 넘어가 기기 안에서 금고 키를 유도하고(`createVault`/`unlockVault`, IndexedDB capsule), 입력칸은 바로 비운다(`relay-app.js` 297행).
3. **URL**: 경로·쿼리에는 room·device·after·ack·consumer만 들어간다. 비밀은 없다.
4. **로그**: 릴레이 저널(10-02 22:00 이후 526줄)은 인증 바인딩 실패(`not an active policy device`, 등록 전 봇)·시작/정지·방 생성 줄뿐이고 요청 본문은 남기지 않는다. 릴레이·봇 저널 모두 JWT 형태 문자열(`eyJ`) 0건.
5. **백업**: 서버 쪽 백업(static tgz, sqlite 사본)은 위 DB와 정적 파일의 사본이므로, 복구 비밀이 들어갈 경로가 없다.

**한계**: 오너의 실제 암호 문자열로 grep하지 않았다(운영자는 그 값을 모르고, 알아서도 안 된다). 대신 "서버로 가는 경로가 코드에 없음"과 "서버 저장소에 그런 열이 없음"을 함께 보였다. 봇의 `state.json`에는 봇 자신의 서명키·MLS 상태가 있지만, 이는 봇 기기의 보관물이지 오너 복구 비밀이 아니다(0600, 공명 로컬).

## 추가 3 — restore-history 범위 안 + echo 무재사용 (2026-10-04 21:17–21:19 KST)

봇 바이너리 `cdddcfc3…`(main `6ba941cb`), 릴레이 서서 `0038886c…`(clean `d47fd52a`). 오너 iPhone은 **Safari** `/app/`로 `family-acc`를 이어서 열었다(홈 화면 PWA 아님). 기준(#243 본문): 봇이 꺼져 있는 동안 쌓인 메시지가 릴레이 보존 범위(`first_seq`) 안이면, 다시 켠 뒤 그 메시지를 해독하고 따라잡아야 한다. 봇 정지는 오너가 "시작"이라고 보낸 뒤에 했다(공명은 운영자 자율 범위 밖). 정지 중에는 45분 뒤 자동으로 다시 켜는 안전 타이머를 걸어 두었다.

| 단계 | 시각(KST) | 관측 |
|---|---|---|
| 1 평시 echo | 21:17:00 | 오너 seq 21 → 봇 echo seq 22 (`echo-10`, `duplicate:false`) |
| 정지 | 21:17:41 | `systemctl stop native-relay-bot`, MainPID 1693578 → 0 |
| 꺼져 있는 동안 오너 메시지 | 21:19:05 | seq 23·24 (`owner-iphone`). 봇 이벤트 0, 릴레이 `mls_cursors(bot-gongmyoung)=21` 그대로 |
| 재기동 | 21:19:29 | MainPID 1944761, NRestarts 0. `identity`·`ready` 모두 `restored:true`, **같은 키** `d019d6df…8a67` |
| 따라잡기 | 21:19:3x | 23 해독 → echo seq 25 (`echo-11`), 24 해독 → echo seq 26 (`echo-12`). 둘 다 `duplicate:false`, 오너가 보낸 바이트 수(2·16)와 echo 바이트 수가 일치 |

- 끝난 뒤: 릴레이 `family-acc`는 seq 1..26, epoch 1이다(commit 없음 → 범위 밖 경로는 타지 않음). 봇 status는 `acked 24, cursor 26, echoes 12, halted false`이다.
- 21:19 이후 봇 저널: `gap`·`error`·`halted`·`commit_refused`·`auth_wait`·403·panic 0건. 안전 타이머는 해제했다.
- **echo 무재사용**: 10-03 12:00 이후 봇 저널의 echo `client_id`는 `echo-7`(seq 16)부터 `echo-12`(seq 26)까지 빠짐도 겹침도 없다. `echo_client_id_reuse` 0건. `echo-9`(10-03 13:11)와 `echo-10` 사이에 재기동이 세 번 있었다(17:38 바이너리 교체, 20:24 SIGKILL, 21:45 자동 재기동). `echo-10`과 `echo-11` 사이에도 이번 재기동이 한 번 있다. 그래서 카운터가 상태 파일에서 복원되고 재사용되지 않는다는 것을 직접 증명한다(추가 1의 미증명 항목 해소).

**증명하지 않는 것**: 범위 밖 경우. 이 경우에는 봇이 꺼져 있는 동안 commit으로 epoch가 오르거나, 보존 범위가 봇 커서를 넘어선다. 그러면 봇은 `gap`을 보고하고 재참여해야 한다. 이는 #242 보존 게이트와 commit 정책(#263) 쪽 실측이 필요하므로 별도 승인 뒤에 진행한다.

**2-c 메모**: 10-03 20:33 첫 시도는 오너 화면에 "방이 안 만들어져 있어"가 떠서 메시지 0건으로 끝났다. 홈 화면 PWA와 Safari의 저장소가 분리돼 생긴 일로 추정한다. 하지만 오너가 어느 쪽으로 열었는지 기억하지 못해 **미확인**으로 남긴다. 오늘은 Safari로 열어 정상 동작했다.

## 증명하지 않는 것(11:17 계획 재시작 기준)

- revoke(E3) 뒤 봇/기기의 403 전환, recover-all-lost(복구 비밀로 전체 복원), restore-history 범위 밖(gap → 재참여) — PC 등록 뒤 또는 별도 승인 뒤 실측(이 파일에 이어 씀). restore-history 범위 안은 추가 3.
- 재시작 직후 새 메시지 복호화·echo(오너가 메시지를 보내지 않음) — 커서 동일성과 `restored:true`로 간접 증명. 오너의 다음 메시지에 대한 echo(seq 15 이상)를 2-e 파일럿 로그에서 확인하면 직접 증명이 된다.
- 상태 파일 손상·삭제 시 동작(저장소 삭제 = 새 기기 → 운영자 재등록·재초대; 2-c 발견과 동일 원칙).

## 재현(운영자, 공명)

```sh
journalctl -u native-relay-bot -o cat | grep '"event":"status"' | tail -1   # 전
systemctl restart native-relay-bot                                           # 오너 고지 후
journalctl -u native-relay-bot -o cat --since "<restart time>" | grep -E '"event":"(identity|ready|status)"'
# 서서(read-only): sqlite3 -readonly …/native-mls-v2.db 'select room,device,seq from mls_cursors'
```
