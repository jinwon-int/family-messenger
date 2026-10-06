# 인수검사 2-b 추가 — 폐기 기기의 MLS leaf 제거(Remove commit → 새 epoch), 실 릴레이 (2026-10-06 12:59~13:0x KST, #243 · #289)

파일럿: 오너 PC 브라우저 `owner-pc`(신뢰 기기·커미터) ↔ 오너 iPhone Safari `owner-iphone-2` ↔ 공명 봇 `bot-gongmyoung`. 릴레이 = 서서
`native-relay`(`d47fd52a`, PID 1941712, 무재시작). 클라이언트 = `/app/` static **web = main `5c25011c`**(#294 멤버 제거 UI, 11:16:55 KST
부분 배포 — Wiki ND-3689) + pkg/wasm `d47fd52a`(`450df32c…`). 운영자 = bangtong. 판정 = 오너 + 방통.
선행: 같은 날 `native-v2-acceptance-20261006-2b-revoke.md`(revoke 라이브 — "새 epoch·not_a_member는 Remove commit(#289) 뒤") · `…-2c-rejoin.md`(옛 `owner-iphone` revoke).
정책 체인 rev 11 그대로(revoke는 이미 끝났고, 이 단계는 MLS 그룹만 바꾼다). 제거 대상 두 leaf는 모두 **정책상 revoked**였다(`owner-iphone` rev 9, `owner-pc-tmp` rev 11).

## 수행·관측

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| 배포 반영 | 12:59:18 | ✓ | PC 로그 "워커 시작: owner-pc @ family-mls-synthetic-acc-1 (relay seq 48, joined=true)" — 새 번들에 `제거할 기기`/`멤버 제거(폐기 기기)` 표시 |
| **`owner-iphone` 제거** | **12:59:43** | ✓ | PC "owner-iphone 제거 commit 게시(seq 49) — 반영되면 epoch 전진" → 같은 초 "내 commit 반영(seq 49) — epoch 전진". 릴레이 seq **49** commit(epoch 4→**5**, 732 B); `mls_members`에서 `owner-iphone` 삭제. 봇 `commit_applied` committer `owner-pc`, **`removes:["owner-iphone"]`**, adds `[]`, members 4, **`outer_checked:true`** |
| **`owner-pc-tmp` 제거** | **13:01:36** | ✓ | PC "owner-pc-tmp 제거 commit 게시(seq 50)" → "내 commit 반영(seq 50) — epoch 전진". 릴레이 seq **50** commit(epoch 5→**6**, 615 B); `mls_members` = **3**(`bot-gongmyoung`, `owner-pc`, `owner-iphone-2`). 봇 `removes:["owner-pc-tmp"]`, members 3, `outer_checked:true` |
| 남은 기기 왕복 | 13:01:58 | ✓ | PC seq **51** application(21 B, epoch 6) → `bot-gongmyoung-echo-21` seq **52**(`duplicate:false`). 봇 `acked 51 / cursor 52 / echoes 21 / epoch 6 / halted:false`. 커서: owner-pc 52, bot 51, owner-iphone-2 48(화면 꺼짐 — 아래) |
| **iPhone-2(타인 commit 수신측)** | **13:08:49** | ✓ | 이어하기(relay seq 48, joined=true) 직후 한 폴링에서 두 commit을 `stage_commit → checkCommit → merge_staged`로 적용. 오너 복사 로그: `commit 검증·적용(seq 49, owner-pc) — +없음 −owner-iphone · (이전 epoch: 내부 검사만) — 멤버 bot-gongmyoung, owner-iphone-2, owner-pc, owner-pc-tmp` → `commit 검증·적용(seq 50, owner-pc) — +없음 −owner-pc-tmp · 릴레이 로스터 일치 — 멤버 bot-gongmyoung, owner-iphone-2, owner-pc`. seq 49는 페이지의 최신 epoch가 아니라 설계대로 내부 검사만(#261: outer 비교는 `ev.epoch+1 == 응답 epoch`일 때), seq 50은 **outer == inner 일치** |
| 릴레이 | 13:0x | ✓ | 재시작 없음(MainPID 1941712), `/v2/health` 200, 저널 오류 0, 폐기 기기 요청 0 |

## 판정 제안(#243 2-b `revoke` 잔여)

- **"새 epoch"** → ✓: revoke된 두 기기를 신뢰 기기가 Remove commit으로 제거 → epoch 4→5→6, 릴레이 추적 로스터·봇 내부 로스터·커미터 화면 로스터 모두 3으로 일치(`outer_checked:true`).
- **"ack 403 `not_a_member`"** → 라이브에서는 **여전히 미관측**: 제거된 두 기기는 정책상 revoked라 그보다 앞선 바인딩(`device_subject_mismatch`)에서 끊기고, 제거 commit 뒤 어떤 요청도 보내지 않았다(저장소 삭제/403 상태). "active인데 Remove된" 기기 시나리오는 운영에서 발생하지 않도록 절차(revoke → 제거)를 두므로 서버 Go 테스트(`server_hardening_test.go`의 removed-member 케이스)로 갈음. #294 스모크는 멤버십 강제 OFF라 이 코드를 치지 않음(명시).
- 종합: 2-b `revoke` **통과**(정책 tombstone + 릴레이 403 + Remove commit 새 epoch 실측; `not_a_member`만 테스트 증거).

## 발견

- **화면 상태 유실**(#296): 제거 전 PC 이어하기가 `joined=false`·로스터 `—`로 떠 `멤버 제거`가 "먼저 방에 들어가 있어야 한다"로 거부. 워커(지문·revision·그룹)는 온전 — `relay-app:<room>:<dev>` 키가 지워진 뒤 참여 전 경로로 seq/epoch만 재구성된 상태. 운영자가 서버 값(seq 48·epoch 4·멤버 5)으로 `localStorage` 복구 + 즉시 reload(4초 폴링 `save()`가 먼저 덮어쓴 함정 1회) → 정상. 원인 후보: 다른 탭에서 같은 기기 ID로 다른 DB 시작 → `confirm-fresh`가 키 삭제.
- 제거 UI는 "폐기 기기"라고 적혀 있지만 정책 상태를 확인하지 않는다(active 기기도 제거 가능) — 운영 절차로 제한(RELAY-APP.md §6).

## 증명하지 않는 것

- iPhone-2 로그는 오너가 복사한 텍스트(화면 캡처 없음). seq 49의 outer 비교는 설계상 생략됐으므로 "두 commit 모두 outer 일치"는 아니다 — 50만 outer 일치, 49는 내부 검사 + 봇 측 `outer_checked:true`.
- `not_a_member` 라이브 403(위). 제거된 leaf의 클라이언트 측 상태(두 기기 저장소는 이미 삭제·403).
- 봇 외 제3자가 보낸 Remove commit에 대한 PC의 검사 경로(이번 두 commit은 PC 자신이 커미터).

## 재현(읽기 전용)

```sh
# 서서: 그룹 추적 로스터·epoch
runuser -u native-relay -- python3 -c 'import sqlite3;c=sqlite3.connect("file:/var/lib/native-relay/data/native-mls-v2.db?mode=ro",uri=True);print(list(c.execute("select epoch,last_seq from mls_rooms where room=\"family-acc\"")),[r[0] for r in c.execute("select device from mls_members where room=\"family-acc\"")])'
# 공명: 봇의 commit 검사 결과
journalctl -u native-relay-bot --since "<시각>" -o cat | grep commit_applied
```
