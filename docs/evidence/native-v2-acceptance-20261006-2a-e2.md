# 인수검사 2-a 추가 — 둘째 기기 승인(E2) + 2-b `add-device` 왕복 (2026-10-06 08:17~08:33 KST, #243)

파일럿: 오너 PC 브라우저(`owner-pc`, 오너 Google 계정으로 CF Access 로그인) ↔ 오너 iPhone Safari(`owner-iphone`,
신뢰 기기) ↔ 공명 봇(`bot-gongmyoung`). 릴레이 = 서서 `native-relay`(바이너리 `vcs.revision=d47fd52a`, PID 1941712,
`-access-mode required`, 정적 클라이언트 `/app/`). 체인 CLI = 서서 `/opt/native-relay/bin/native-devices`
(`runuser -u native-relay --`로 실행 — 디렉터리 소유자=euid 규칙). 운영자 = **bangtong**(원래 예정 운영자 yukson의
09:30 알림을 기다리지 않고 오너 지시 "지금 진행"으로 08:1x 선행). 판정 = 오너 + 방통.

## 수행·관측

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| 사전 inspect | 08:1x | — | 체인 **rev 6** `5e34d332…`: `owner-iphone` active(fp `3b64cd4d…`), `bot-gongmyoung` active, `probe-yukson` active, `bot-1` revoked. 공명 봇 `halted:false`, echo 13(seq 27→28) |
| PC 워커 시작 → 등록 전 403 | 08:17:46~08:25:02 | ✓ | 릴레이 저널 `auth bind device=owner-pc: not an active policy device` 4초/1분 간격 반복; PC 화면 "릴레이가 이 기기를 받지 않는다(403 device_subject_mismatch) — 운영자 등록 대기" + "운영자 등록 정보" 자동 펼침 |
| 등록 정보 검증(운영자) | 08:2x | ✓ | `signing_key` 32 B hex, **fingerprint == sha256(signing_key)** 재계산 일치 `792afd9e…`; 후보 JSON = 등록 정보 + `subject`(= `owner-iphone`의 Access `sub`, 동일 오너) + `base_revision: 6` |
| E2 승인 서명(iPhone §4) | 08:2x | ✓ | 오너가 후보 JSON을 iPhone "4. 두 번째 기기 승인"에 붙여 `지문 보기` → **PC 화면 지문과 사람이 대조**(오너 진술 일치) → `이 지문이 맞습니다` → 증거 JSON(`signature` 128 hex, `approved_by: owner-iphone`) 전달 |
| `-add-device` | **08:25:05** | ✓ | 입력 = 증거 중 6필드(`device_id actor subject signing_key base_revision signature`; strict 디코더), 0600·`native-relay` 소유, 실행 후 삭제. `-expected-revision 6` → **rev 7** `7b56a80a…`: `owner-pc` active · `trusted-device-fingerprint` · `approved_by={owner-iphone, revision 7}` · fp `792afd9e…`(CLI 재계산 = 화면) |
| 403 → 수락 전환 | 08:25:05~ | ✓ | 릴레이 저널 `device=owner-pc` 거부 **0건**(이후 전 구간), 재시작 없음(MainPID 1941712, NRestarts 0), `/v2/health` 200 |
| PC 키 패키지 게시 | 08:2x | ✓ | `mls_keypackages`: `owner-pc` ref `f16c30eb…` → `consumed_by=owner-iphone` |
| iPhone 초대 commit | **08:29:09** | ✓ | 릴레이 `mls_events` seq **29** `commit`(owner-iphone, epoch 1→2) · seq **30** `welcome` targets=`owner-pc`; `mls_members` += `owner-pc`(added_seq 29); `mls_rooms.family-acc` epoch **2** |
| 봇 commit 검사(outer==inner) | 08:29:09 | ✓ | 봇 `commit_applied` seq 29: committer `owner-iphone`, adds `[owner-pc]`, removes `[]`, members `[bot-gongmyoung, owner-iphone, owner-pc]`, **`outer_checked:true`**, epoch 2 |
| PC 참여 → 메시지 → 봇 echo | **08:32:56** | ✓ | seq **31** application from `owner-pc`(22 B, epoch 2) → 봇 `decrypt` → seq **32** `bot-gongmyoung-echo-14`(`duplicate:false`, epoch 2). 봇 status `acked 31 / cursor 32 / echoes 14 / epoch 2 / halted:false`. 커서: owner-pc 32, owner-iphone 32, bot 31. 오너 진술 "완료"(양 화면에 PC 메시지·echo 표시) |

## 판정 제안(#243 체크박스)

- 2-a **등록 의식 E2** → ✓ (지문 대조는 관리 선언 — DEVICES-V4 "approved_by는 암호학적 증명이 아님" 그대로).
- 2-b **`add-device`: 승인 → 모든 방 Add commit → 새 기기 복호화** → ✓ (방은 `family-acc` 1개; PC가 Welcome으로 참여해 epoch 2에서 송수신).
- 2-c "저장소 축출 rejoin은 PC 등록 뒤" 전제 해소 — 이제 수행 가능.

## 발견

- 오너는 "키 패키지 게시 → 상대가 초대 → 참여"의 순서를 처음 안내에서 이해하지 못했다. 화면 버튼 이름(`키 패키지 게시(초대받기)`, `초대할 기기`+`초대`, `동기화`)과 "누가 어느 기기에서 누르는가"를 1:1로 적은 재안내 뒤 통과. → 클라이언트 §2에 "새 기기 합류 순서" 3줄 안내 후보(UX 메모, #258 계열).
- `native-devices`는 root로 실행하면 `native device policy unavailable`만 출력한다(소유자=euid 규칙). 메시지가 원인을 말하지 않는다 → 운영 메모: 반드시 서비스 유저로.
- 10-05 봇 교체(`42a00665`, #269) 뒤 조건부 미결이던 "오너 다음 메시지 echo 12→13"은 10-05 seq 27→28에서 이미 발생해 있었다(#268 해소 근거).

## 증명하지 않는 것

- 사람 클라이언트(PC·iPhone)가 commit을 `stage_commit → 검사 → merge_staged` 경로로 처리했다는 **클라이언트 측 로그**는 수집하지 않았다(화면 로그를 오너가 복사하지 않음). 서버·봇 측 증거(릴레이 members, 봇 `outer_checked:true`)와 PC가 epoch 2에서 정상 송수신한 사실로 간접 확인. 클라이언트 로그 수집은 다음 commit(축출 재참여)에서.
- PC 평문 내용(봇 로그는 길이 22 B만). 다중 방 Add(방이 1개).
- Ed25519 서명 검증은 CLI(`VerifyApproval`)가 수행 — 운영자가 독립 재검증하지 않음(CLI는 공개키를 출력하지 않음).
- 오너 Access `sub`가 PC 로그인 세션에서도 같은 값인지는 릴레이의 수락(403 → 0건)으로만 간접 확인(JWT 클레임 미열람).

## 재현(운영자, 서서; 값 비기록)

```sh
runuser -u native-relay -- /opt/native-relay/bin/native-devices -device-state /var/lib/native-relay/policy -inspect
# 입력 = {device_id, actor, subject, signing_key, base_revision, signature} 만, 0600, native-relay 소유
runuser -u native-relay -- /opt/native-relay/bin/native-devices -device-state /var/lib/native-relay/policy \
  -add-device -input /var/lib/native-relay/<input>.json -expected-revision <현재 rev>
journalctl -u native-relay --since "<실행 시각>" -o cat | grep -c "device=owner-pc"   # 0 이어야 함
```
