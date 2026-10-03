# 인수검사 2-b — 복구·백업 5연산 (부분: 봇 영속 신원 재시작, 2026-10-03 11:17 KST, #243)

**상태: 부분 증거.** 2-b 중 "봇 영속 신원 재시작"만 다룬다. revoke(E3)·recover-all-lost·restore-history는 PC(`owner-pc`) E2 등록 뒤(#243 ⑪, time-gated)로 미룬다 — 이 파일에 추가 커밋으로 이어 쓴다.

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

## 증명하지 않는 것

- revoke(E3) 뒤 봇/기기의 403 전환, recover-all-lost(복구 비밀로 전체 복원), restore-history — PC 등록 뒤 실측(이 파일에 이어 씀).
- 재시작 직후 새 메시지 복호화·echo(오너가 메시지를 보내지 않음) — 커서 동일성과 `restored:true`로 간접 증명. 오너의 다음 메시지에 대한 echo(seq 15 이상)를 2-e 파일럿 로그에서 확인하면 직접 증명이 된다.
- 상태 파일 손상·삭제 시 동작(저장소 삭제 = 새 기기 → 운영자 재등록·재초대; 2-c 발견과 동일 원칙).

## 재현(운영자, 공명)

```sh
journalctl -u native-relay-bot -o cat | grep '"event":"status"' | tail -1   # 전
systemctl restart native-relay-bot                                           # 오너 고지 후
journalctl -u native-relay-bot -o cat --since "<restart time>" | grep -E '"event":"(identity|ready|status)"'
# 서서(read-only): sqlite3 -readonly …/native-mls-v2.db 'select room,device,seq from mls_cursors'
```
