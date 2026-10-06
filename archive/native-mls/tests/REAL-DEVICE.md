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
  `MLS_WASM_BINDGEN` 환경변수로 wasm-bindgen 경로 지정. 빌드는 `bundle-sha256.txt`(자산 해시
  매니페스트)를 함께 남긴다 — CI는 두 번 빌드해 이 매니페스트가 동일함을 요구한다(재현성 게이트).
- 검증기 자체 점검(번들·Playwright 불필요, 수 초):
  ```bash
  python3 archive/native-mls/tests/real_device_kit.py validate-selftest
  ```

## 1. 세션 서버 시작 (실기기와 같은 LAN의 컴퓨터에서)

```bash
python3 archive/native-mls/tests/real_device_kit.py serve --bundle artifacts/mls-pkg --bind 192.168.x.x
```

- `--bind`는 실기기와 같은 LAN의 **이 컴퓨터 IP**를 권장한다. 생략하면 `0.0.0.0`(모든 인터페이스)에
  바인드하고 경고를 출력한다. `--port`(기본 8765).
- 인쇄되는 URL 중 LAN IP(`http://192.168.x.x:8765/s/<토큰>/panel.html`)를 기기로 보낸다.
- URL에는 세션 토큰(32헥스)이 있다. 토큰 없는 경로·다른 Host로는 404로 막히고 **기록되지 않는다**
  (fail closed). 요청 기록의 경로는 `/s/<토큰>` 접두사를 뗀 형태로 남는다.
- 서버는 합성 전용이며 상태를 메모리에만 둔다. Ctrl-C로 종료하면 세션 스켈레톤
  (기기 등록·요청 기록·관찰)이 `archive/artifacts/real-device-*/session-skeleton.json`(0600)으로
  저장된다. **이 파일이 검증의 기준점이다** — 수정하지 말고 증거와 함께 보관한다.
- 기기 등록 시 서버는 클라이언트가 보낸 `ua`와 별도로 요청 헤더에서 직접 읽은 `request_ua`,
  `request_sec_ch_ua` · `request_sec_ch_ua_platform` · `request_sec_ch_ua_mobile`(없으면 `null`)을
  기록한다. 검증기는 클라이언트 자기신고가 아니라 이 **서버 관측값**을 기준으로 삼는다.

### 1.1 세션을 망치는 실수 네 가지 (#243 2-c 실측, #251)

1. **서버는 포그라운드 또는 `setsid`로 띄운다.** 스켈레톤은 Ctrl-C(SIGINT) 처리에서 저장되는데,
   `nohup … &` 같은 백그라운드 실행은 SIGINT를 무시하므로 종료해도 **스켈레톤이 남지 않는다**.
   터미널을 비울 수 없으면 `setsid python3 … serve …`로 띄우고 `kill -INT <pid>`로 끝낸다.
   대안: 세션 도중 `http://<LAN IP>:8765/s/<토큰>/evidence.json`을 받아 두면 같은 생성기가 만든
   스켈레톤을 **라이브로** 얻는다(저장본과 `session`이 같다 — selftest가 대조한다).
2. **`web/`를 고치면 서버를 재시작한다.** 서버는 자산을 **시작 시 한 번** 적재해 메모리에서 서빙하므로
   패치 뒤 새로고침만으로는 바뀐 코드가 가지 않는다. 재시작하면 토큰·교환판이 초기화되니 URL을
   다시 보내고 왕복을 처음부터 한다.
3. **세션마다 새 DB 이름으로 시작하거나, 먼저 `저장소 삭제(축출 재연습)`를 한다.** 이전 세션의
   DB로 이어하기한 기기는 이미 그룹을 들고 있어 `그룹 생성`이 `operation 거부`로 끝난다
   (기기 1개 = 그룹 1개). "거부"가 버그가 아니라 이전 상태가 남아 있다는 신호다.
4. **모바일에서 `워커 시작` 중에는 앱을 전환하지 않는다.** 암호 키 유도(scrypt logN 18)에 1~3분이
   걸리고 데드라인은 180 s(#246)다. 백그라운드로 가면 브라우저가 워커를 멈춰 데드라인을 넘긴다 —
   화면을 켠 채 지문이 나올 때까지 기다린다.

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
6. **관찰 전송**: 이탈 시간·복귀 후 해독 성공 여부·메모를 넣고 `관찰 전송`. 증거 JSON의
   `background_return.away_seconds`는 **여기 넣은 초와 같은 값**이어야 한다(검증기가 대조).
7. **저장소 축출 재연습(권장)**: 한 기기에서 `저장소 삭제(축출 재연습)` → 같은
   신원·데이터베이스·암호로 다시 시작 → **새 지문** 확인 → 반대 기기가 새 패키지로 재초대 →
   참여 → 메시지 왕복. iOS의 7일 미사용 축출도 같은 결과(상태 소멸·재등록 필요)로 문서화한다.

## 3. 증거 JSON 작성 · 검증

세션 종료 후 아래 형태로 `real-device-evidence.json`을 만든다. `session`은 스켈레톤의 `session`
객체를 **원문 그대로** 붙여넣고, 각 기기의 `ua`·`platform`은 스켈레톤 `devices[]`의
**`request_ua`·`platform`**을 그대로 옮긴다(손으로 고치면 실패한다).

```json
{"schema": "real-device-evidence:v1", "synthetic_only": true, "ci": false,
 "kit_git_sha": "<키트 커밋 SHA — 40헥스 전체, 저장소 HEAD의 조상이어야 한다>",
 "operated_by": "<수행자>", "dates": ["YYYY-MM-DD"],
 "session_log_sha256": "<session-skeleton.json 파일의 sha256 (sha256sum session-skeleton.json)>",
 "session": {<session-skeleton.json의 session 객체 원문>},
 "devices": [
   {"kind": "firefox|safari-ios|android-chrome", "ua": "<스켈레톤 devices[].request_ua>",
    "platform": "<스켈레톤 devices[].platform>",
    "checks": {"init": true, "fingerprint_out_of_band": true, "invite_join": true,
               "encrypt_decrypt_roundtrip": true,
               "background_return": {"performed": true, "away_seconds": 30, "decrypted_after_return": true},
               "storage_eviction": {"tested": true, "rejoined": true},
               "rejoin_guidance": "<축출 시 상태 소멸 → 재등록 후 반대 기기 재초대로 재참여, 과거 메시지는 읽을 수 없다는 안내(60자 이상)>"},
    "notes": "..."}],
 "attestation": "<운영자 서명 진술 — §5 참조>",
 "notes": "..."}
```

검증(하나라도 빠지면 실패) — 스켈레톤 파일이 **필수**다:

```bash
python3 archive/native-mls/tests/real_device_kit.py validate real-device-evidence.json \
  --skeleton archive/artifacts/real-device-<id>/session-skeleton.json
```

| 플래그 | 뜻 |
|---|---|
| `--skeleton <path>` | (필수) serve가 저장한 `session-skeleton.json`. 없으면 검증 자체가 불가. |
| `--repo <dir>` | `kit_git_sha` 조상 검사용 git 저장소. 기본은 키트 파일이 있는 git 루트 자동 탐지. 탐지 실패도 위반. |
| `--allow-ipad-desktop-ua` | §5의 iPad 데스크톱급 UA 예외를 **운영자 진술 하에** 수용. |

검증기가 대조하는 것:

1. `session_log_sha256` == 스켈레톤 **파일**의 sha256(재계산).
2. `session` == 스켈레톤 `session` 전체(deep equal). `requests`가 `log` 길이와 같아야 한다.
3. 기기 3종 각각: 증거 `ua` == 스켈레톤 등록의 **서버 관측 `request_ua`**; 등록 당시 클라이언트 `ua`도
   `request_ua`와 같아야 한다; `platform`이 등록 기록과 같아야 한다; UA 휴리스틱(종류 일치, `Headless`
   부재); 클라이언트 힌트가 있으면 종류와 정합(android-chrome: `Sec-CH-UA-Mobile: ?1`·`Android` 플랫폼·
   Chromium 브랜드; firefox/safari-ios: 힌트 헤더가 **있으면** Chromium 계열로 보고 거부).
4. 기기 3종 각각: 스켈레톤 `observations`에 `kind` 일치 · `bg_seconds ≥ 20` · `bg_decrypted == true` ·
   `bg_seconds == background_return.away_seconds`인 관찰이 1개 이상.
5. `kit_git_sha`: 40헥스 전체 SHA이고 `git merge-base --is-ancestor <sha> HEAD`가 참(저장소 HEAD의 조상).
6. `synthetic_only == true`, `ci == false`, schema, `operated_by`, `dates`, checks 4종, 축출 기록,
   rejoin 안내(60자 이상·"재참여" 포함).

## 4. 리허설(선택, headless — 증거 아님)

실기기를 꺼내기 전 패널 동작을 로컬에서 확인:

```bash
python3 archive/native-mls/tests/real_device_kit.py selftest --bundle artifacts/mls-pkg
```

생성→초대→참여→양방향 왕복→새로고침 이어하기→축출 재참여를 헤드리스 Chromium으로
리허설하고(마지막에 `validate-selftest`도 실행) receipt를 `archive/artifacts/real-device-selftest-*/`에
남긴다. `real_device_evidence: false`가 고정되어 있어 실기기 증거로 쓸 수 없다.

## 5. headless 배제는 진술 기반이다 — 검증기가 증명하는 것 / 못 하는 것

**분명히 적어 둔다: 검증기는 "실기기였다"를 증명하지 못한다.** UA 문자열과 클라이언트 힌트는
브라우저가 자유롭게 바꿀 수 있고, 헤드리스 브라우저도 임의의 UA를 보낼 수 있다. 검증기의 `Headless`
휴리스틱은 *명백한* 실수(헤드리스 리허설 결과를 증거로 제출)를 거르는 장치일 뿐이다.

- **증명하는 것**: 제출된 증거가 서버가 직접 관측·저장한 스켈레톤과 바이트 수준(파일 sha256)·
  구조 수준(session 원문·등록 UA·클라이언트 힌트·관찰 기록)으로 일치한다는 것, 그리고 키트 커밋이
  저장소 역사 안에 있다는 것. 즉 **증거를 세션 밖에서 지어내거나 사후에 손볼 수 없다.**
- **증명하지 못하는 것**: 세션에 접속한 브라우저가 물리 기기였는지, headless/에뮬레이터가
  아니었는지. 이것은 **운영자 서명 진술(attestation)** 로 담보한다 — 증거 JSON `attestation`
  필드에 수행자 이름·날짜·"3종 모두 물리 기기에서 손으로 수행했고 headless·에뮬레이터·UA 변조를
  쓰지 않았다"는 문장을 넣고, PR에서 수행자가 같은 내용을 서명(코멘트)한다. 거짓 진술은 사람의
  책임이지 검증기가 잡을 수 있는 것이 아니다.
- **iPad 데스크톱급 UA 제한**: iPadOS 13+ Safari는 기본으로 `Macintosh` UA(`platform=MacIntel`)를
  보낸다. 구분 신호인 `navigator.maxTouchPoints`는 현재 패널 등록 본문에 **없으므로**(panel.js 변경은
  이 배치 범위 밖, #177 후속) 서버는 iPad와 Mac Safari를 구분할 수 없다. 검증기는 `safari-ios` 등록이
  `Macintosh` UA일 때 `platform == 'MacIntel'`이고 `Sec-CH-UA-Mobile` 헤더가 **없으며**(Chromium 계열
  아님) 운영자가 `--allow-ipad-desktop-ua`를 명시한 경우에만 수용한다. 가능하면 iPad 설정에서
  "데스크톱 웹사이트 요청"을 끄거나 iPhone을 쓰는 것이 낫다.

## 증명하지 않는 것

- 이 키트·세션은 합성 키만 다루며 사람 키·실계정·운영 호스트와 무관하다(결정 E).
- 표시용 지문은 패널이 자체 계산한 SHA-256일 뿐이다. 신뢰는 파사드의 MLS 고정 키 검증이 담당한다.
- 교환판은 세션 내 합성 전달일 뿐이며 릴레이 계약(§3.4)과 무관하다.
- headless 실행(selftest 포함)은 실기기 증거로 인정되지 않는다(#177 §4). 검증기 통과는 "스켈레톤과
  일치"이지 "실기기 확인"이 아니다(§5).

## 6. 릴리스 무결성 재검증 (2-d, 실 릴레이) — 운영자가 아무 노드에서 수행

서빙 중인 정적 번들과 릴레이 바이너리가 **커밋된 산출물**과 같은지 확인한다. 읽기 전용이며
Access JWT 없이 tailnet 주소로 수행한다(서서 `18921`은 ufw로 tailnet만 허용).

```bash
RELAY=http://<relay-tailnet-ip>:18921        # 서서 tailnet 주소
# 1) 서빙 매니페스트 == 커밋 매니페스트 (archive/experiments/openmls-browser/bundle-sha256.txt)
curl -s "$RELAY/app/pkg/bundle-sha256.txt" | sort > /tmp/served.txt
sort archive/experiments/openmls-browser/bundle-sha256.txt > /tmp/committed.txt
diff /tmp/served.txt /tmp/committed.txt && echo "manifest IDENTICAL"
# 2) 서빙 바이트를 다시 해시해 매니페스트와 대조 (매니페스트가 텍스트만 맞는 경우를 배제)
for f in custody.js family_mls_browser_experiment.js family_mls_browser_experiment_bg.wasm; do
  printf '%s ' "$f"; curl -s "$RELAY/app/pkg/$f" | sha256sum | cut -c1-64
done | sort | diff - <(awk '{print $2" "$1}' /tmp/committed.txt | sort) && echo "bytes MATCH"   # 양쪽 모두 줄 전체(파일명) 기준 정렬
# 3) 릴레이 바이너리: 서빙 노드에서 sha256 + 빌드 툴체인 기록 (재현 빌드는 핀 툴체인 노드에서)
ssh <relay-node> 'sha256sum /opt/native-relay/bin/native-mls-relay; strings /opt/native-relay/bin/native-mls-relay | grep -oE "go1\.[0-9.]+" | head -1'
# 4) vcs 판정: 서빙 노드에 go가 없으면 `go version -m` 대신 내장 buildinfo 문자열을 읽는다
ssh <relay-node> 'strings /opt/native-relay/bin/native-mls-relay | grep -E "vcs\.(revision|modified)=" | sort -u'
```

| 날짜(KST) | 번들 매니페스트 | 바이트 재해시 | 릴레이 sha256(12) · 툴체인 | 수행 |
|---|---|---|---|---|
| 2026-10-03 00:5x | IDENTICAL (wasm `13e94dfa…`, js `d9a05287…`, custody `b94b2180…`) | 3/3 일치 | `0cd567cabcc0` · go1.27.1 — **재현 미충족**: `go version -m` `vcs.revision=ae7557e9`(#248 시점) + `vcs.modified=true`(작업트리 빌드). 깨끗한 `d54ee66` 빌드(`CGO_ENABLED=1 go build -trimpath`, gwakga, `vcs.modified=false`) sha `76d0aac7bff9be58…`가 서빙 노드 `/root/native-relay-staging/`에 대기 — 교체는 오너 결정 | yukson |
| 2026-10-04 11:13 | IDENTICAL (wasm `450df32c…`(#262), js `d9a05287…`, custody `b94b2180…`) + 정적 `relay-app.html` `8ab1b52a…`·`relay-app.js` `f9124e34…`·`commit-policy.js` `18ba9958…` == `6dbc5ef` 트리 | 3/3 일치 (1차 diff 실패는 2단계 스니펫의 정렬 불일치 `sort -k2` 대 `sort` 탓 — 이번에 수정) | `0038886cf4c5` · go1.27.1 · `-trimpath` CGO 1 — **깨끗한 커밋 빌드 ✓** buildinfo `vcs.revision=d47fd52a`(#262 머지) `vcs.modified=false`(빌드 노드 gwakga). 독립 재빌드 해시 대조(재현 ✓/✗)는 미수행. 2026-10-03 16:38 KST 교체분 그대로(health 200) | yukson |
| 2026-10-06 09:45 | **의도된 혼합**: pkg 매니페스트는 `d47fd52a` 그대로(wasm `450df32c…` — main의 #281 wasm `0d27d28f…` 미배포) + 정적 `relay-app.html` `47b7f1eb…`·`relay-app.js` `2c5e5ba2…`·`relay-attachments.js`(신규) `616a8407…` == main `ea34ff5`(#270 첨부 UI). static 3파일만 교체, 백업 `static-pre-attach-20261006T094534.tgz` | 설치 직후 루프백 3/3 == git blob | `0038886cf4c5` 불변(재시작 없음, MainPID 1941712) | bangtong |

릴레이 바이너리의 **재현 여부는 `go version -m <binary>`의 `vcs.revision`·`vcs.modified`로 판정**한다(sha 일치만으로 "= 커밋 빌드"라고 쓰지 말 것 — 2026-10-03 오판). 재현 빌드(`go build -trimpath` 해시 일치)는 같은 Go 버전이 핀된 노드에서만 의미가 있다 —
수행 시 이 표에 "재현 ✓/✗ + 빌드 노드 + 커밋"을 추가한다. 번들의 재현 빌드는 rustc 1.91.1 +
`wasm32` 툴체인(gwakga)에서 수행한다.

