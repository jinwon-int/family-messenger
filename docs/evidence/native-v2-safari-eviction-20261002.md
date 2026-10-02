# Safari iOS 저장소 축출 재참여 — 2026-10-02 23:32~23:45 KST (#243 §1, #229 보완)

- 대상: 오너 iPhone 15 Pro · iOS 18.7 · Safari(서버 관측 UA `Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) … Version/27.0 Mobile/15E148 Safari/604.1`, platform `iPhone`, 393x852@3, ko-KR). 손으로 수행(오너).
- 파트너: 공명(x86_64) headless Chromium 자동화(`m4-safari-partner.py`) — **기기 증거가 아니라 상대역**. 참여·답장·재초대만 자동.
- 세션 서버: 공명 `real_device_kit.py serve`(192.168.55.27 / Tailscale 100.93.90.63 : 8765), 번들 = main `3f7bc78`을 곽가에서 핀 툴체인(rustc 1.91.1 · wasm-bindgen 0.2.126 · esbuild 0.27.2)으로 재현 빌드, `bundle-sha256.txt` 일치(wasm `a20a5dd0…`, js `d9a05287…`, custody `b94b2180…`).
- 서버 관측본: [native-v2-safari-eviction-20261002-skeleton.json](native-v2-safari-eviction-20261002-skeleton.json) sha256 `9ec374bff302daaf…` — `/evidence.json`의 **라이브 내보내기**(`skeleton()`와 같은 생성기). Ctrl-C 저장본이 아닌 이유: 서버를 `nohup` 백그라운드로 띄워 SIGINT가 무시됐다(아래 교훈).

## 타임라인 (서버 관측, KST = UTC+9)

| 시각 | iPhone (서버 로그) | 파트너 로그 |
|---|---|---|
| 23:32:43 | | partner 시작 · 키 패키지 게시 |
| 23:35:22 | 기기 등록(`/devices`) | |
| 23:35:43 / 23:39:12 | `워커 시작` ×2 (저장소 삭제 → 새 암호로 시작; 첫 시도는 이어하기) | |
| 23:40:30~36 | `그룹 생성` → `keypackage:partner` 가져오기 → 초대(`welcome:owner`) | 23:40:49 참여(round 1) |
| 23:40:48~57 | 메시지 `암호화 → 게시`(`ciphertext:owner`) | 23:40:59 해독 "실기기 합성 인사" · 답신 게시 |
| 23:41:13 | `ciphertext:partner` 가져오기 → 해독 | |
| **23:42:08** | **`저장소 삭제(축출 재연습)` → 같은 신원·DB·암호로 `워커 시작`** (워커 자산 재로드) | |
| 23:43:35 | `키 패키지 → 게시`(`keypackage:owner`, 새 기기) | 23:43:35 새 패키지 감지 → 재초대(`welcome:partner`) |
| 23:44:49 | `welcome:partner` 가져오기 → `참여` | |
| 23:45:11 | "재참여" 메시지 게시(`ciphertext:owner`) | 23:45:14 해독 **"재참여"** · round 2 답신 |
| 23:45:42 | `ciphertext:partner`(round 2) 가져오기 → 해독 | 23:45:14 `ALL_PARTNER_PHASES_OK` |

교환판 최종: `keypackage:partner, welcome:owner, ciphertext:owner, ciphertext:partner, keypackage:owner, welcome:partner, ciphertext:owner, ciphertext:partner` (8건, 요청 318건).

## 판정

- `storage_eviction: {tested: true, rejoined: true}` — 축출 뒤 **새 키 패키지로 재초대받아 참여**하고 양방향 메시지가 왕복했다(파트너가 "재참여" 평문을 해독, 오너가 round-2 답신 해독).
- 오너 진술(채팅, 2026-10-02 23:4x KST): "끝". **2026-10-03 00:1x KST 추가 진술: 지문이 바뀌었는지, round-2 답신이 iPhone에서 해독돼 보였는지는 "확인하지 못했음"** — 그래서 아래 두 사실은 서버·파트너 관측으로만 뒷받침된다: (a) 축출 뒤 파트너가 새 `keypackage:owner`를 받아 재초대했고 그 Welcome으로만 참여가 가능했다(새 기기), (b) 오너 기기가 23:45:42에 round-2 암호문을 가져갔다(해독 자체는 미관측).
- 관찰 전송(`observations`)은 0건 — 이 세션은 백그라운드 복귀가 아니라 축출만 다뤘고, 백그라운드 복귀 관찰은 #229 세션(스켈레톤 `8967ebe6…`)에 있다. 따라서 이 스켈레톤은 3기기 `validate` 대상이 아니라 **#229 증거의 Safari `storage_eviction` 필드를 뒷받침하는 보조 관측본**이다. #229 증거 JSON은 필드 갱신 후 원 스켈레톤으로 `validate` 통과.

## 발견 (인수검사 2-c 피드백)

1. **`worker deadline`(60 s) — iPhone의 scrypt(logN 18)가 60 s를 넘김.** 첫 `워커 시작` ~55 s, 새로고침 뒤 이어하기에서 초과 → 워커 종료. 패널 `init` 데드라인을 180 s로 — PR #246. KDF는 낮추지 않음.
2. **`operation 거부` on `그룹 생성`** — 이전 세션의 DB를 이어하면 그 기기는 이미 그룹을 가진 상태라 생성이 거부된다(기기 1 = 그룹 1). 세션을 새로 시작할 때는 저장소 삭제 후 시작. 런북 §2에 명시 필요.
3. 세션 서버를 백그라운드(`nohup`)로 띄우면 SIGINT가 무시돼 Ctrl-C 저장이 안 된다 — `/evidence.json`을 내보내거나 포그라운드/`setsid`로 띄울 것(런북 보강 대상).
4. 모바일에서 `워커 시작`은 화면을 켜 두고 앱 전환 없이 기다려야 한다(백그라운드 전환 시 타이머가 멈춰 데드라인에 걸림).

## 증명하지 않는 것

- 지문이 바뀌었는지는 서버가 볼 수 없고 **오너도 확인하지 못했다**(2026-10-03 진술). 재초대 없이는 참여가 불가능했다는 사실(파트너가 새 `keypackage:owner`를 받아 재초대)이 새 기기임을 간접 증명할 뿐이다. round-2 답신의 iPhone 해독도 미관측(가져가기만 로그됨).
- 축출 이전 메시지를 읽을 수 없음 — 설계상 사실이며 이 세션에서 별도로 시도하지 않았다.
- 파트너는 headless 자동화 — Safari 기기 증거에만 의미가 있다.
