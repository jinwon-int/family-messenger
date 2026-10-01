# M4 실기기 수동 세션 (#177 §4) — 운영자 런북

`real_device_kit.py`는 스모크가 프로그램으로 구동하는 **동일한 durable 워커**를 사람 손으로
구동하는 합성 세션 서버다. Firefox · Safari(iOS) · Android Chrome **실기기 3종**의 실행 기록을
#177 §4 수용 기준(브라우저 3종 UA · 백그라운드 복귀 · 저장소 축출 시 rejoin 안내)에 맞춰
수집하는 것이 목적이다. **headless 불인정, CI 밖, 수동** — 이 문서의 절차는 사람이 수행한다.

## 0. 준비

- 같은 Wi-Fi/LAN에 있는 실기기 3종(데스크톱 Firefox, iPhone/iPad Safari, Android Chrome).
- 번들이 이미 빌드되어 있어야 한다(저장소 루트에서):
  ```bash
  archive/experiments/openmls-browser/build.sh artifacts/mls-pkg   # wasm-bindgen 0.2.126 필요
  ```
  `MLS_WASM_BINDGEN` 환경변수로 wasm-bindgen 경로 지정.

## 1. 세션 서버 시작 (실기기와 같은 LAN의 컴퓨터에서)

```bash
python3 archive/native-mls/tests/real_device_kit.py serve --bundle artifacts/mls-pkg
```

- 인쇄되는 3개 URL 중 LAN IP(`http://192.168.x.x:8765/s/<토큰>/panel.html`)를 기기로 보낸다.
- URL에는 세션 토큰이 있다. 토큰 없는 경로·다른 Host로는 403/404로 막힌다(fail closed).
- 서버는 합성 전용이며 상태를 메모리에만 둔다. Ctrl-C로 종료하면 세션 스켈레톤
  (기기 UA·요청 기록·관찰)이 `archive/artifacts/real-device-*/session-skeleton.json`(0600)으로 저장된다.

## 2. 각 실기기에서 (기기당 약 5분)

1. **기기 등록**: 브라우저 종류를 골라 `이 기기 등록` — UA·화면이 세션에 기록된다.
2. **워커 시작**: 신원(기기마다 다르게, 예 `owner`/`partner`), 데이터베이스
   (`family-mls-synthetic-real-1`, 기기마다 다르게), 암호 **32자 이상**(비밀번호 관리자로 생성 —
   다시 입력해야 하므로 보관). `워커 시작` → 지문 64헥스가 표시된다.
3. **지문 대조**: 두 기기의 지문을 눈으로 비교해 일치 기록을 남긴다(표시용이며 신뢰 결정은
   파사드의 고정 키 검증이 한다).
4. **왕복**: 기기 A `그룹 생성` → 기기 B `키 패키지 → 게시` → A가 교환판 새로고침 후
   B의 패키지 `가져오기` → A `초대`(Welcome 게시) → B가 Welcome 가져와 `참여`.
   이후 A 메시지 `암호화 → 게시` → B 가져와 `해독`, 반대 방향도 동일.
5. **백그라운드 복귀**: 모바일 기기는 홈으로 이탈 **20초 이상**(데스크톱 Firefox는 탭 전환) →
   복귀 → 반대 기기가 새 메시지 게시 → 복귀한 기기가 해독 성공. 이탈 시간을 관찰 기록에 넣는다.
   (탭이 시스템에 회수되어 재시작된 경우에도 성공 인정 — 데이터베이스·암호로 이어하기되므로.
   이 경우 관찰 메모에 "reload 후 이어하기"로 남긴다.)
6. **관찰 전송**: 이탈 시간·복귀 후 해독 성공 여부·메모를 넣고 `관찰 전송`.
7. **저장소 축출 재연습(권장)**: 한 기기에서 `저장소 삭제(축출 재연습)` → 같은
   신원·데이터베이스·암호로 다시 시작 → **새 지문** 확인 → 반대 기기가 새 패키지로 재초대 →
   참여 → 메시지 왕복. iOS의 7일 미사용 축출도 같은 결과(상태 소멸·재등록 필요)로 문서화한다.

## 3. 증거 JSON 작성 · 검증

세션 종료 후 아래 형태로 `real-device-evidence.json`을 만든다(스켈레톤의 `session`을 붙여넣고
나머지를 채운다):

```json
{"schema": "real-device-evidence:v1", "synthetic_only": true, "ci": false,
 "kit_git_sha": "<키트 커밋 SHA>", "operated_by": "<수행자>", "dates": ["YYYY-MM-DD"],
 "session_log_sha256": "<session-skeleton.json의 sha256>",
 "session": {<session-skeleton.json의 session 객체>},
 "devices": [
   {"kind": "firefox|safari-ios|android-chrome", "ua": "<등록된 UA>", "platform": "<platform>",
    "checks": {"init": true, "fingerprint_out_of_band": true, "invite_join": true,
               "encrypt_decrypt_roundtrip": true,
               "background_return": {"performed": true, "away_seconds": 30, "decrypted_after_return": true},
               "storage_eviction": {"tested": true, "rejoined": true},
               "rejoin_guidance": "<축출 시 상태 소멸 → 재등록 후 반대 기기 재초대로 재참여, 과거 메시지는 읽을 수 없다는 안내(60자 이상)>"},
    "notes": "..."}],
 "notes": "..."}
```

검증(하나라도 빠지면 실패):

```bash
python3 archive/native-mls/tests/real_device_kit.py validate real-device-evidence.json
```

## 4. 리허설(선택, headless — 증거 아님)

실기기를 꺼내기 전 패널 동작을 로컬에서 확인:

```bash
python3 archive/native-mls/tests/real_device_kit.py selftest --bundle artifacts/mls-pkg
```

생성→초대→참여→양방향 왕복→새로고침 이어하기→축출 재참여를 헤드리스 Chromium으로
리허설하고 receipt를 `archive/artifacts/real-device-selftest-*/`에 남긴다.
`real_device_evidence: false`가 고정되어 있어 실기기 증거로 쓸 수 없다.

## 증명하지 않는 것

- 이 키트·세션은 합성 키만 다루며 사람 키·실계정·운영 호스트와 무관하다(결정 E).
- 표시용 지문은 패널이 자체 계산한 SHA-256일 뿐이다. 신뢰는 파사드의 MLS 고정 키 검증이 담당한다.
- 교환판은 세션 내 합성 전달일 뿐이며 릴레이 계약(§3.4)과 무관하다.
- headless 실행(selftest 포함)은 실기기 증거로 인정되지 않는다(#177 §4).
