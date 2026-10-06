# 인수검사 2-b — `revoke` 라이브 실측 (실 릴레이, 2026-10-06 10:08~10:16 KST, #243)

파일럿: 오너 PC 브라우저 **새 탭**에 임시 기기 **`owner-pc-tmp`**(DB `family-mls-synthetic-acc-tmp`, 같은 Access 세션·같은 `subject`) —
살아 있는 상태로 폐기해 거부를 관찰하기 위한 기기. 승인자·초대자 = 원래 탭 `owner-pc`. 봇 = 공명 `bot-gongmyoung`. 릴레이 = 서서
`native-relay`(`d47fd52a`, PID 1941712, 무재시작). 체인 CLI = 서서 `native-devices`(`runuser -u native-relay --`). 운영자 = bangtong. 판정 = 오너 + 방통.
선행: 같은 날 E2(#286)·2-c 재참여(#288)·첨부(#292). 2-c 재참여 때의 `revoke`는 폐기 대상 저장소가 이미 삭제돼 라이브 403을 못 봤다 — 그 공백을 채운다.

## 수행·관측

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| tmp 워커 시작 → 등록 전 403 | 10:08:26 | ✓ | tmp 로그 "워커 시작: owner-pc-tmp @ family-mls-synthetic-acc-tmp (relay seq 0, joined=false)"; 릴레이 `auth bind device=owner-pc-tmp: not an active policy device` 10:08:50~ |
| E2(승인자 `owner-pc`) | 10:09:57~10:10:04 | ✓ | 운영자 fp 재계산 일치 `f9d6ce09…`; 원래 탭 로그 "후보 owner-pc-tmp 지문 표시" → 대조 → "승인 서명 완료"(`approved_by: owner-pc`) |
| `-add-device -expected-revision 9` | **10:10:43** | ✓ | **rev 10** `1592873c…`: `owner-pc-tmp` active · trusted · `approved_by={owner-pc, 10}`. 직후 거부 0건(수락). owner 활성 3대(상한 4) |
| 합류 | 10:11:21~39 | ✓ | tmp "키 패키지 게시(저장)" → `owner-pc` 초대 commit seq **41**(epoch 3→4) + welcome seq 42 → tmp "참여 완료(seq 42) — 멤버 5"(옛 `owner-iphone` 자리 포함). 봇 `commit_applied` adds=[owner-pc-tmp], members 5, `outer_checked:true` |
| **살아 있음 증명** | 10:12:49 · 10:13:07 | ✓ | tmp application seq **43**(9 B) → `echo-18` seq 44 · seq **45**(6 B) → `echo-19` seq 46(`duplicate:false`). tmp 커서 46 |
| **`-revoke owner-pc-tmp -expected-revision 10`** | **10:14:18** | ✓ | **rev 11** `6f3f4f97…`: `owner-pc-tmp` **revoked**(device_revision 2). plain revoke(E2 기기는 증거 서명 불가 — DEVICES-V4) |
| 폐기 기기 **GET 403** | 10:14:18~ | ✓ | 같은 초부터 4초 폴링마다 릴레이 `auth bind device=owner-pc-tmp: not an active policy device`(25초 7건, 10:16까지 34건). tmp 화면 상태줄 "릴레이가 이 기기를 받지 않는다(403 device_subject_mismatch) — 운영자 등록 대기", 마지막 성공 동기화 **10:14:15** |
| 폐기 기기 **POST 403** | **10:15:25** | ✓ | tmp `보내기`("after-revoke") → 로그 **"실패: Error: 전송 실패: 403 device_subject_mismatch"**; 릴레이 저널 10:15:25 거부 2건(폴링 GET + POST). `mls_events`에 tmp의 새 행 **0**(last_seq 46 → 다음은 owner-pc의 47) |
| 남은 기기 무영향 | 10:16:17 | ✓ | `owner-pc` seq **47**(3 B) → `echo-20` seq 48. 봇 `acked 47 / cursor 48 / echoes 20 / epoch 4 / halted:false`. 릴레이 MainPID 1941712·NRestarts 0·`/v2/health` 200 |
| 폐기 기기 커서 | 10:16 | 관측 | `mls_cursors`에서 `owner-pc-tmp` 행이 **사라짐**(10:13 46 → 10:16 없음, `removed_*` 아닌 삭제). `mls_members`에는 남음(added_seq 41). 아래 "발견" |

## 판정 제안(#243 2-b `revoke`)

- "폐기 기기 **POST 403**" ✓ · "**GET 비복호화**" → 더 강하게 **GET 자체가 403**(required 모드, DEVICES-V4 "revoked 기기는 GET도 403") ✓ · 체인 tombstone·새 revision ✓.
- "**새 epoch**" → ✗(미발생): revoke는 정책 체인 연산이고 MLS epoch는 Remove commit이 올린다. relay-app에 Remove UI가 없다(#289). → **#289 머지 뒤** 신뢰 기기의 Remove commit으로 채운다.
- "**ack 403 `not_a_member`**" → 미관측: 그 코드는 *Remove commit으로 제거된 뒤에도 정책상 active인* 기기용이다(추적 멤버 아님). revoked 기기는 그보다 앞선 아이덴티티 바인딩에서 `device_subject_mismatch`로 끊긴다 — 설계상 도달 불가. #289 시나리오(active인데 Remove된 기기)에서만 관측 가능.
- 종합: 2-b `revoke` **조건부 통과**(정책·릴레이 거부 전부 실측, epoch·not_a_member는 #289 의존).

## 발견

- **폐기 직후 커서 행 삭제**: 릴레이 `store.go` `dropStaleCursors`("reader cursors of devices no longer active in the device policy (revoked or vanished)… must not pin application events forever", M1 후속)가 정책상 비활성 기기의 커서를 지운다 — 폐기된 기기가 보존 게이트(MIN 커서)를 영원히 붙잡지 못하게 하는 설계(#242 보존 게이트와 정합). 반면 `mls_members`에는 남아 그룹 로스터(5)와 정책 활성(2) 사이 괴리가 커진다 → #289.
- tmp 탭 상태줄은 폐기를 "운영자 등록 대기"로 안내한다(등록 전 403과 같은 문구). 사람에게는 "이 기기는 폐기됐다"가 더 정확하지만 릴레이가 이유를 숨기는 것은 설계(C1: 어느 검사가 실패했는지 비노출) — 클라이언트가 구분할 수 없음. 문구 후보: "등록되지 않았거나 폐기된 기기".
- 같은 브라우저의 두 탭이 DB 이름만 달리해 서로 다른 기기로 동작했다(저장소·outbox 키가 DB 이름 기준). 임시 기기 실험 절차로 재사용 가능.

## 증명하지 않는 것

- 새 epoch·`not_a_member`(위, #289). tmp의 MLS leaf 제거(미수행, 그룹 members 5 유지).
- 다른 `subject`(타인) 토큰으로 폐기 기기 ID를 쓰는 경우(403은 같지만 미실측). Ed25519 서명 독립 재검증.
- 폐기 뒤 tmp가 가진 과거 평문/키 폐기(클라이언트 저장소는 그대로; 축출은 별도 — 오너가 탭의 `저장소 삭제`로 정리 가능).

## 재현(운영자, 서서; 값 비기록)

```sh
CLI="runuser -u native-relay -- /opt/native-relay/bin/native-devices -device-state /var/lib/native-relay/policy"
$CLI -revoke <id> -expected-revision <현재 rev>
journalctl -u native-relay --since "<시각>" -o cat | grep -c "device=<id>"           # 폴링마다 증가
runuser -u native-relay -- python3 -c 'import sqlite3;c=sqlite3.connect("file:/var/lib/native-relay/data/native-mls-v2.db?mode=ro",uri=True);print(list(c.execute("select device,seq from mls_cursors where room=\"family-acc\"")))'
```
