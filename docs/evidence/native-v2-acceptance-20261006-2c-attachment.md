# 인수검사 2-c 추가 — 두 기기 간 256 KiB 첨부 왕복 (실 릴레이, 2026-10-06 09:45~10:00 KST, #256 · #243)

파일럿: 오너 PC 브라우저(`owner-pc`) ↔ 오너 iPhone Safari(`owner-iphone-2`) ↔ 공명 봇(`bot-gongmyoung`, 복호화 뒤 echo). 릴레이 = 서서
`native-relay`(바이너리 `d47fd52a`, PID 1941712). 클라이언트 = `/app/` static **web = main `ea34ff5`**(첨부 UI #270 `307a55c`) + **pkg/wasm
= `d47fd52a`(`450df32c…`)** — 09:45:34 KST static 3파일만 교체(오너 "A 승인", 재시작 없음, 백업 `static-pre-attach-20261006T094534.tgz`).
운영자 = bangtong. 판정 = 오너 + 방통.

시험 파일(PC→iPhone): 정확히 **262,144 B** ASCII 텍스트(`attach-256kib-20261006.txt`, sha256 `ff8846292c374cbfe24c0bcbd52120e727dd37cd44b727438155b3b2ca64a0c7`,
비공개 gist로 PC에 전달). 역방향(iPhone→PC): 오너 사진 보관함의 작은 사진 1장.

## 수행·관측

| 단계 | 시각(KST) | 결과 | 관측 |
|---|---|---|---|
| 배포 반영 | 09:55:53 | ✓ | PC 로그 "워커 시작: owner-pc @ … (relay seq 36, joined=true)" — 새 번들로 이어하기, "첨부파일/첨부 보내기" 표시 |
| **PC → 256 KiB 첨부** | **09:57:52** | ✓ | PC 로그 **"첨부 전송 확인(seq 37, 262144바이트)"**. 릴레이 `mls_events` seq **37** `owner-pc` `client_id file-v1-fbf55982-…` kind application epoch 3 **암문 262,361 B**(+217 B 오버헤드) |
| 봇 복호화 → echo | 09:57:52~53 | ✓ | 봇 `application from owner-pc seq 37 bytes 262144` → `echo-16` seq **38**(`duplicate:false`, 암문 262,373 B) |
| iPhone-2 수신 | ~09:58 | ✓ | 릴레이 커서 `owner-iphone-2` = **40**(seq 37·38 복호화·ack 완료 — ack는 처리한 seq까지만 전진). 오너 화면 첨부 행 `[37] owner-pc: 첨부파일 (262,144바이트) [다운로드]`(진술) |
| **iPhone-2 → 첨부(사진)** | **10:00:19** | ✓ | 릴레이 seq **39** `owner-iphone-2` `client_id file-v1-b8c7e38f-…` 암문 219,878 B; 봇 `application from owner-iphone-2 seq 39 bytes 219649` → `echo-17` seq **40** |
| PC 수신·다운로드 | ~10:0x | ✓ | PC `[39] owner-iphone-2: 첨부파일 … [다운로드]` → `attachment-39.bin` 저장 → `certutil -hashfile … SHA256` = `cb47f29457e9aa915c53c19577864810497ff930cd2288abfff5b8e840ded218` |
| 상태 | 10:0x | ✓ | 봇 `acked 39 / cursor 40 / echoes 17 / epoch 3 / halted:false`. 커서 owner-pc 40 · owner-iphone-2 40 · bot 39. 릴레이 오류 0 |

## 판정 제안(#243 2-c · #256)

- 2-c **"두 기기 간 256 KiB 첨부 왕복"** → ✓ (상한 262,144 B 정확히 1건 PC→iPhone, 219,649 B 1건 iPhone→PC, 둘 다 세 번째 기기(봇)도 복호화).
- **"중복 없는 재시도(exact-byte 200 duplicate)"** → 사람 손으로는 **미재현**(릴레이에 도달했는데 응답만 잃는 상황을 만들 수 없음). 클라이언트의 outbox 설계(`relay-attachments.js`: 암문·`client_id`를 POST 전 localStorage에 보존, 재시도는 같은 바이트, 201/200-duplicate만 성공)와 단위 테스트 `relay-attachments.test.mjs`, 릴레이 dedup 테스트(#225)로 갈음.

## 발견

- 첨부 UI가 10-05 머지(#270)된 뒤 서빙 static에 반영되지 않아 오너 화면에 없었다 → 09:45 static 부분 배포로 해결. **2-d 관점에서 서빙 상태는 web=main / pkg=d47fd52a 혼합**(#281의 새 wasm `0d27d28f…` 미배포, 의도됨). 다음 전체 번들 교체 때 정리.
- 봇은 첨부도 평문 그대로 echo한다(262,144 B 텍스트가 사람 화면에 본문으로 그려짐; 사진은 바이너리가 텍스트로 깨져 보임). 파일럿 소음이지만 무해 — 봇이 `file-v1-*` client_id는 echo하지 않거나 길이만 답하는 개선 후보.
- 다운로드 파일명은 `attachment-<seq>.bin`, MIME `application/octet-stream`(설계: 이름·종류 비보존). 오너가 사진을 다시 보려면 확장자를 손으로 바꿔야 한다 — UX 메모.

## 증명하지 않는 것

- PC 다운로드 `attachment-39.bin`의 **원본 사진과의 바이트 동일성**(원본 해시 없음; 봇이 복호화한 길이 219,649 B와 PC 파일 길이 대조는 오너 보고 대기 — 보고되면 아래에 추기).
- iPhone-2가 저장한 `attachment-37.bin`의 sha256(iPhone에서 해시 불가; 커서 40 + 화면 행의 262,144바이트 표시로 간접).
- 200-duplicate 재시도 실측(위). 첨부 메타데이터(이름·종류) 보호 범위, 청킹·대용량(#256 범위 외).
- 릴레이는 평문을 보지 않으므로 서버 측 sha256(`mls_events.sha256`)은 암문 해시다 — 평문 대조에 쓰지 않았다.

## 재현(운영자, 읽기 전용)

```sh
# 서서: 릴레이 DB(ro)에서 첨부 이벤트 크기·client_id 확인
runuser -u native-relay -- python3 -c 'import sqlite3;c=sqlite3.connect("file:/var/lib/native-relay/data/native-mls-v2.db?mode=ro",uri=True);print(list(c.execute("select seq,device,client_id,length(bytes) from mls_events where room=\"family-acc\" and client_id like \"file-v1-%\"")))'
# 공명: 봇이 복호화한 평문 길이
journalctl -u native-relay-bot --since "<시각>" -o cat | grep -E '"client_id":"file-v1-|echo-1[67]'
```
