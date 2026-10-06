# 인수검사 2-c 추가 — 저장소 축출 → 재참여(실 릴레이) + 2-b `revoke`(부분) (2026-10-06 08:4x~08:59 KST, #243)

파일럿: 오너 iPhone Safari(축출 전 `owner-iphone` → 축출 뒤 **`owner-iphone-2`**) ↔ 오너 PC 브라우저(`owner-pc`, **신뢰 기기·승인자·초대자**)
↔ 공명 봇(`bot-gongmyoung`). 릴레이 = 서서 `native-relay`(PID 1941712, 무재시작). 체인 CLI = 서서 `native-devices`
(`runuser -u native-relay --`). 운영자 = bangtong. 판정 = 오너 + 방통. 선행 = 같은 날 E2(`native-v2-acceptance-20261006-2a-e2.md`, 체인 rev 7).

설계 전제(소스): 정책 체인은 기기 ID·키 **재사용 금지**(`ids are never reused`, DEVICES-V4 불변식) → 축출된 기기는 **새 ID**로
E2 재등록하고 옛 ID는 E3 `revoke`. relay-app에는 멤버 제거 UI가 없어 옛 leaf는 MLS 그룹에 남는다(아래 "증명하지 않는 것").

## 수행·관측

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| iPhone 저장소 삭제(축출) | 08:4x | ✓ | 오너: "5. 기타 → 저장소 삭제" → 기기 ID를 `owner-iphone-2`로 바꿔 워커 시작(새 키·새 지문) |
| 등록 전 403 | 08:49:20~08:55:1x | ✓ | 릴레이 `auth bind device=owner-iphone-2: not an active policy device` 4초 간격; iPhone 화면 "운영자 등록 대기" + 등록 정보 자동 펼침 |
| 운영자 검증 | 08:5x | ✓ | fingerprint == sha256(signing_key) 재계산 일치 `080e6f8a…`; 후보 = 등록 정보 + `subject`(오너 Access sub, 변동 없음) + `base_revision: 7` |
| **PC가 승인자**(§4) | 08:54:19~34 | ✓ | PC 로그 "후보 owner-iphone-2 지문 표시 — 새 기기 화면의 지문과 눈으로 비교" → 오너 대조(iPhone 화면 `080e 6f8a …` 일치) → "승인 서명 완료". 증거 `approved_by: owner-pc` |
| `-add-device -expected-revision 7` | **08:55:15** | ✓ | **rev 8** `5f168320…`: `owner-iphone-2` active · `trusted-device-fingerprint` · `approved_by={owner-pc, 8}` |
| `-revoke owner-iphone -expected-revision 8` (E3, plain) | **08:55:15** | ✓ | **rev 9** `967cbac7…`: `owner-iphone` **revoked**(device_revision 2, tombstone). 입력 파일 삭제 |
| 403 → 수락 | 08:55:16~ | ✓ | `device=owner-iphone-2` 거부 0건, 옛 `owner-iphone` 요청 0건(클라이언트 저장소가 이미 삭제됨), 릴레이 MainPID 불변·`/v2/health` 200 |
| iPhone-2 키 패키지 → **PC 초대** | 08:57:48 | ✓ | PC 로그 "owner-iphone-2 추가 commit 게시(seq 33) — 반영되면 Welcome" → "내 commit 반영(seq 33) — epoch 전진" → 08:57:49 "owner-iphone-2에게 Welcome 전송". 릴레이 seq **33** commit(epoch 2→3), seq **34** welcome targets=owner-iphone-2; `mls_members` += owner-iphone-2(added_seq 33) |
| 봇 commit 검사 | 08:57:4x | ✓ | `commit_applied` seq 33: committer `owner-pc`, adds `[owner-iphone-2]`, removes `[]`, members `[bot-gongmyoung, owner-iphone, owner-iphone-2, owner-pc]`, **`outer_checked:true`**, epoch 3 |
| iPhone-2 참여 → 송신 → 봇 echo | 08:59:00~01 | ✓ | seq **35** application from `owner-iphone-2`(13 B, epoch 3) → seq **36** `bot-gongmyoung-echo-15`(`duplicate:false`, epoch 3). 커서: owner-iphone-2 **36**(echo를 복호화·ack), owner-pc 36, bot 35. 봇 `acked 35 / cursor 36 / echoes 15 / epoch 3 / halted:false` |

## 클라이언트 측 로그(PC, 오너 복사 — 지난 E2에서 미수집이던 항목)

```
오전 8:28:45 키 패키지 게시(저장) — 상대 기기가 "초대"로 이 기기를 넣을 수 있다
오전 8:29:11 참여 완료(seq 30) — 멤버 bot-gongmyoung, owner-iphone, owner-pc
오전 8:54:19 후보 owner-iphone-2 지문 표시 — 새 기기 화면의 지문과 눈으로 비교한다
오전 8:54:34 승인 서명 완료 — 아래 증거를 운영자에게 전달한다(-add-device -input)
오전 8:57:48 owner-iphone-2 추가 commit 게시(seq 33) — 반영되면 Welcome을 보낸다
오전 8:57:48 내 commit 반영(seq 33) — epoch 전진
오전 8:57:49 owner-iphone-2에게 Welcome 전송
```

PC는 이번 commit의 **커미터**라 `merge_pending` 경로다(타인 commit의 `stage_commit→검사→merge_staged`가 아님). 타인 commit을 사람
클라이언트가 검사한 로그는 iPhone-2 쪽(seq 33은 Welcome으로 참여했으므로 해당 없음)에도 없다 — 아래 "증명하지 않는 것".

## 판정 제안(#243 체크박스)

- 2-c **저장소 축출 시 rejoin 안내** → ✓: 축출 → 새 기기 안내 문구(화면) → 운영자 재등록(E2, PC 승인) + 옛 ID revoke → 상대(PC) 재초대 → Welcome 참여 → 왕복. 전 과정 실 릴레이·오너 손.
- 2-b **`revoke`** → **부분**: 체인 tombstone(새 revision 9)과 릴레이 거부 규칙(required 모드에서 revoked는 GET도 403 — DEVICES-V4)은 확인. 그러나 "폐기 기기 POST 403·GET 비복호화·ack 403 `not_a_member`" **실측은 없음**(폐기 대상 클라이언트의 저장소가 이미 삭제되어 요청 자체가 0건). "새 epoch"는 revoke로 생기지 않았다(epoch 3은 Add commit). → 살아 있는 기기를 폐기하는 별도 실측이 필요(후보: 3번째 기기 또는 PC를 폐기 대상으로).

## 발견

- 옛 `owner-iphone`의 MLS leaf가 그룹에 남는다(릴레이 `mls_members` 4, 봇 members 4). 정책상 revoked이므로 그 ID로는 어떤 요청도 403이고 키 자체도 지워졌지만, **MLS 그룹에서 제거(Remove commit)할 UI가 relay-app에 없다**(파사드는 `remove_pending` 노출). 메시지는 계속 그 leaf에도 암호화된다(비밀 유출은 아님 — 복호화 키가 없음). → 후속: 운영자/신뢰 기기용 "멤버 제거" 버튼 또는 revoke 시 자동 Remove 정책(#231 계열).
- 축출 뒤 새 기기 ID를 **반드시** 바꿔야 한다는 점이 화면 문구("같은 기기 ID로 다시 시작하면 … 운영자 재등록(revoke + 재등록)")에서 바로 읽히지 않는다 — CLI는 같은 ID를 거부한다. 문구 개선 후보: "기기 ID를 새 이름으로 바꾸고 시작한다".
- 승인·초대의 역할이 바뀌어도(PC가 승인자·초대자) 사람 절차는 동일하게 통과 — E2 의식은 기기 종류에 독립.

## 증명하지 않는 것

- 폐기된 기기의 라이브 403·비복호화(위). 폐기로 인한 새 epoch. 옛 leaf 제거.
- 사람 클라이언트의 **타인 commit** `stage_commit→검사→merge_staged` 로그(이번 두 commit 모두 사람 커미터 자신 또는 Welcome 참여자만 관여; 봇 측 `outer_checked:true`만 확보).
- iPhone-2 평문 내용(13 B)과 iPhone 화면 캡처 — 오너 진술·봇 echo·커서 36으로 대신.
- Ed25519 서명 독립 재검증(CLI `VerifyApproval`만). `subject`가 PC·iPhone 두 로그인 세션에서 동일함은 릴레이 수락으로만 간접 확인.

## 재현(운영자, 서서; 값 비기록)

```sh
CLI="runuser -u native-relay -- /opt/native-relay/bin/native-devices -device-state /var/lib/native-relay/policy"
$CLI -inspect
$CLI -add-device -input <0600 6필드 JSON> -expected-revision <rev>     # 새 ID, approved_by = 신뢰 기기
$CLI -revoke <옛 id> -expected-revision <rev+1>                           # plain revoke (E1 기기, 증거 없이)
journalctl -u native-relay --since "<시각>" -o cat | grep -c "device=<새 id>"  # 0
```
