# Google Play Data safety 입력표 — 한데 Android (#584)

> 근거: 릴레이 `archive/native-mls/server/store.go` 의 SQLite 스키마(2026-10-29 main) · 기기 정책 체인(`cmd/native-devices`, `-device-state`) · 앱 코드(`archive/native-mls/android`). Play 정의(Data safety 도움말 10787469): **「수집」= 기기 밖으로 전송**, 단 **종단간 암호화되어 개발자도 읽을 수 없는 데이터는 수집으로 신고하지 않는다**(중간자 누구도 못 읽고 송수신자만 키를 가질 때). 한데의 메시지·첨부 내용이 여기 해당한다. 서버가 평문으로 보는 **메타데이터·식별자**는 신고한다.

## 0. 릴레이가 실제로 저장하는 것 (표 단위)

| 저장소 | 열(요약) | 서버가 읽을 수 있나 | 보관 |
|---|---|---|---|
| `mls_rooms` | 대화방 이름(사용자가 지음), group_id, epoch, revision, last_seq, 생성·종료 시각, 만든 기기(`creator`), 창립 actor 목록 | 예 | 대화방이 있는 동안(운영자 `-reset-room` 으로 삭제) |
| `mls_events` | 대화방, 순번, **발신 기기 ID**, client_id, 종류(commit/welcome/application), epoch, targets, **암호문 bytes**, sha256, 시각 | 메타데이터 예 · **bytes 는 암호문(아니오)** | application: 모든 멤버 커서가 지나면 정리, TTL **30일**(`AppEventTTLSeconds`) · commit/welcome: 최근 8 epoch(하드 상한 256) |
| `mls_blobs` + 블롭 파일 | 첨부 메타(대화방, id, 발신 기기, 크기, after_seq, 시각) + **암호화된 첨부 바이트** | 메타 예 · 내용 아니오(파일 키는 암호문 메시지 안) | TTL 의 2배 = **60일** |
| `mls_keypackages` · `mls_lobby_keypackages` | 기기 ID, MLS 공개 key package, 소비한 기기/대화방, 만료 | 예(공개키) | 7일 / 30일 또는 소비 즉시 |
| `mls_cursors` | 대화방별 기기의 읽기 커서(순번), 제거 시각 | 예 | 멤버인 동안(+ 제거 유예 7일) |
| `mls_members` | 대화방, 기기 ID, **actor(사람 이름 영문)**, 추가 순번 | 예 | 대화방이 있는 동안 |
| `mls_read` | 대화방, actor, **읽음 위치**(순번), 시각 | 예 | 대화방이 있는 동안 |
| `push_devices` | 기기 ID, **APNs 토큰**(iOS), topic | 예 | 등록 철회까지(Android 는 아직 푸시 없음 — 이 표는 iOS 만) |
| `device_candidates` | 기기 ID, **subject(CF Access 신원 = 이메일 형식)**, actor, 서명 공개키, 지문, 만료 | 예 | **10분** TTL |
| 기기 정책 체인(`-device-state`, 파일) | 기기 ID, actor, 서명 공개키, 지문, **subject(CF Access 신원)**, 상태(active/revoked), 역할(registrar), revision·서명 | 예 | **불변 기록**(폐기해도 revoked 로 남음) |
| 서버 로그(stdout/journal) | `auth bind device=<id>` 등 경로·기기 ID·오류 — 토큰·내용 없음 | 예 | **30일**(방침 2-1 의 운영 정책값, `release-checklist.md` 0-4) |
| 오프호스트 스냅샷 | 위 DB·정책 체인 사본(`docs/NATIVE-RELAY-OPERATIONS.md`) | 예(암호문은 여전히 암호문) | 48시간 전량 + 하루 1개 × **30일** |
| Cloudflare Access | Google 로그인 이메일·시각(Cloudflare 측 로그) | 한데 서버는 접근 안 함 | Cloudflare 정책 |

앱이 서버로 **보내는** 것: 요청마다 세션 JWT(CF Access, `sub`=신원) · 기기 ID · 위 표의 값들. 앱 권한은 `INTERNET` 하나. 분석·광고·크래시 SDK 없음(의존성: Compose/AndroidX/OkHttp/JNA/androidx.browser 뿐).

## 1. 양식 답안

### 개요
- 앱이 필수 사용자 데이터를 수집하거나 공유하나요? → **예**(아래 유형).
- 모든 사용자 데이터가 전송 중 암호화되나요? → **예**(TLS; 메시지는 추가로 E2EE).
- 사용자가 데이터 삭제를 요청할 방법을 제공하나요? → **예** — 앱 내 「이 기기 지우기」 + 웹 `delete-account` 페이지(운영자 처리).
- 독립 보안 검토(MASA)? → **아니오**.
- 개발자 계정 유형: 조직.

### 데이터 유형별

| Play 데이터 유형 | 수집 | 공유 | 필수/선택 | 목적 | 처리 | 근거(서버 저장 항목) |
|---|---|---|---|---|---|---|
| 개인 정보 › **이메일 주소** | 예 | 아니오 | 필수 | 앱 기능, 계정 관리 | 전송 중 암호화, 삭제 요청 가능 | CF Access `subject`(이메일 형식) — 기기 정책 체인·`device_candidates`. 로그인 자체는 Cloudflare/Google 이 처리 |
| 개인 정보 › **이름** | 예 | 아니오 | 필수 | 앱 기능 | 〃 | `actor`(운영자가 정해 준 영문 이름 — 실명일 수 있음) — `mls_members`·`mls_read`·체인. 실명이 아니면 「사용자 ID」로 바꿔도 됨(오너 판단) |
| 개인 정보 › **사용자 ID** | 예 | 아니오 | 필수 | 앱 기능, 계정 관리 | 〃 | 기기 정책 체인의 기기 기록(actor+기기 ID, 공개키·지문) |
| **기기 또는 기타 ID** | 예 | 아니오 | 필수 | 앱 기능 | 〃 | 앱이 만든 기기 ID `<actor>-android-<6 hex>`(IMEI·광고 ID 아님), APNs 토큰(iOS 만) |
| 메시지 › **기타 인앱 메시지** | **신고 안 함** | — | — | — | — | 내용은 MLS E2EE — 서버·운영자가 읽을 수 없음(도움말 「End-to-end encryption」 면제). 단 **메타데이터**(발신 기기·순번·시각·대화방 이름·읽음 위치)는 서버가 보므로 아래 「앱 활동」으로 신고 |
| 앱 활동 › **기타 사용자 생성 콘텐츠** | 예 | 아니오 | 필수 | 앱 기능 | 〃 | 대화방 이름(사용자가 지음, 평문) · 참여 목록 · 읽음 위치 · 발신 시각(메타데이터). 오너 판단: 「앱 상호작용」으로 분류해도 됨 |
| 파일 및 문서 | **신고 안 함** | — | — | — | — | 첨부 바이트·파일 키 모두 E2EE(`mls_blobs` 메타: 크기·발신 기기만 — 위 「앱 활동」에 포함) |
| 사진·동영상 / 오디오 | 신고 안 함 | | | | | 첨부는 사용자가 고른 파일만, E2EE. 사진 라이브러리 접근 없음 |
| 위치 · 연락처 · 금융 · 건강 · 캘린더 · 웹 검색 기록 · 설치된 앱 | 아니오 | | | | | 수집·접근 없음 |
| 앱 정보 및 성능(크래시·진단) | 아니오 | | | | | SDK 없음. 서버 로그는 요청 경로·기기 ID(위 「기기 ID」) |

### 보안 관행 항목
- 전송 중 암호화: 예(TLS 1.2+; 릴레이는 Cloudflare 뒤).
- 삭제 요청 메커니즘: 예 — `https://jinwon-int.github.io/family-messenger/hande/delete-account/`(앱 설정 화면 링크 `DELETE_ACCOUNT_URL` 은 끝 `/` 없는 같은 경로 → Pages 301).
- 데이터 처리 위치/보관: 릴레이 서버 1대(운영 주체 = rnmaru.com 운영 법인; 호스트 위치는 Family Wiki 노드 문서) — 위 표의 보관 기간.

### 콘솔의 다른 선언과의 일관성
- 개인정보처리방침 URL = `https://jinwon-int.github.io/family-messenger/hande/privacy/`(앱 안 링크 `BuildConfig.PRIVACY_URL` 과 같은 페이지).
- 계정 삭제: 「앱 내 삭제 경로 제공」 예(이 기기 지우기), 「웹 삭제 요청 URL」 = 위 delete-account 주소. 체인의 폐기 기록이 남는 점은 삭제 페이지 3절에 명시(「일부 데이터 보관」 선택 → 사유: 변조 방지 보안 기록).
- 광고: 없음. 콘텐츠 등급: IARC 설문(사용자 간 소통 있음 → 「사용자 상호작용」 예, 개인정보 공유 가능 예).
- App access: 로그인 필요 — 심사용 데모 서버·Google 계정([`demo-server.md`](demo-server.md), iOS 와 공용 · 심사 노트 문안은 [`app-store-review.md`](app-store-review.md) §2).
- Apple App Privacy 라벨은 같은 §0 표에서 뽑은 [`app-store-review.md`](app-store-review.md) §1 — 두 스토어의 답이 서로 모순되지 않게 같이 고친다.

---

## English summary
Worksheet for the Google Play Data safety form, derived from the relay's actual SQLite schema and device-policy chain. Declared as collected (not shared, required, App functionality, encrypted in transit, deletion request available): email address (Cloudflare Access subject), name (operator-assigned display name), user ID and device ID (app-generated, plus iOS APNs token), and "other user-generated content" for plaintext room metadata (room names, membership, read positions, timestamps). Message and attachment content is **not** declared under Google's end-to-end-encryption rule (unreadable by the developer). No ads, analytics, crash SDKs, location, contacts, or photos access.
