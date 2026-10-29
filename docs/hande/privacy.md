# 한데(Hande) 개인정보처리방침

> 이 문서는 Android(Google Play)·iOS(App Store) 「한데」 앱이 **앱 안에서** 여는 페이지이며, Google Play Console 「개인정보처리방침 URL」·App Store Connect 「Privacy Policy URL」 에 같은 주소를 적는다. 게시 주소: `https://jinwon-int.github.io/family-messenger/hande/privacy/`

- 앱 이름: **한데**(Hande) — Android `com.seoyoon_family.hande` · iOS `com.seoyoon-family.hande`
- 개발·운영 주체(개인정보처리자): **rnmaru.com 을 운영하는 법인**(Apple Developer Program·Google Play 개발자 계정의 조직 명의와 동일. 법인명·주소는 스토어 등록 명의와 같게 기입: 〔법인명〕)
- 문의·요청 연락처: **support@rnmaru.com**
- 시행일(최종 수정일): **2026-10-29**
- 적용 범위: 한데 Android·iOS 앱과, 위 운영 주체가 운영하는 한데 릴레이 서버(`relay.seoyoon-family.com`)·한데 웹(`hande.seoyoon-family.com`)

## 0. 먼저 알아 둘 것 — 서버는 운영자마다 다르다
한데 앱은 **서버 주소(도메인)를 사용자가 고르는 구조**다(첫 화면 「서버 찾기」). 이 방침은 위 운영 주체가 운영하는 서버에 대한 설명이며, **다른 운영자가 자기 서버를 돌리면 그 운영자의 방침이 적용된다**(앱은 그 서버로 암호문·메타데이터를 보낸다). 앱 자체는 운영 주체에게 아무것도 따로 보내지 않는다 — 앱이 통신하는 상대는 사용자가 고른 서버 하나뿐이다.

## 1. 한데는 무엇인가
가족끼리 쓰는 **종단간 암호화(E2EE, IETF MLS RFC 9420)** 메신저다. 대화 내용과 첨부는 보내는 기기에서 암호화되어 받는 기기에서만 풀린다. 서버(릴레이)는 암호문을 전달·보관할 뿐 **열 수 없다**. 가입은 공개되어 있지 않다 — 서버 운영자가 허용한 Google 계정으로만 로그인한다(Cloudflare Access).

## 2. 수집·저장하는 정보
### 2-1. 서버(릴레이)에 저장되는 것
릴레이의 저장소(SQLite `native-mls-v2.db` + 기기 정책 체인 파일)에 실제로 있는 항목 전부다(소스: `archive/native-mls/server/store.go` 스키마).

| 항목 | 내용 | 왜 | 보관 |
|---|---|---|---|
| 로그인 신원(계정 식별자) | 운영자가 허용한 Google 계정으로 Cloudflare Access 에 로그인한 결과의 **신원 식별자(`subject`, 이메일 형식)** | 기기 등록 기록과 요청을 같은 사람에게 묶기 위해 | 기기 기록이 있는 동안. 폐기 뒤에도 체인에 「폐기됨」 상태로 남는다(불변 기록, 6절) |
| 기기 기록(기기 정책 체인) | 앱이 만든 **기기 ID**(`<이름>-android-<난수>` / `<이름>-iphone-<난수>`), 사용자 이름(`actor`, 운영자가 정한 영문 이름 — 실명일 수 있음), 서명 **공개키**, 지문(공개키 해시), 상태(활성/폐기), 역할(등록 기기), 승인 서명 | 어느 기기가 가족 구성원의 것인지 확인하고 메시지 발신자를 검증 | **불변 기록**(폐기해도 「폐기됨」으로 남음) |
| 새 기기 등록 요청(후보 우편함) | 새 기기의 기기 ID·이름·`subject`·서명 공개키·지문 | 같은 사람의 다른 기기가 지문을 비교해 승인하도록 | **10분** 뒤 자동 삭제(승인되면 즉시 삭제) |
| 대화방 메타데이터 | 대화방 이름(사용자가 지음, 평문), 만든 기기, 참여 기기 목록(기기 ID·이름), MLS epoch/순번, 생성·종료 시각 | 메시지 전달 순서·멤버십 관리 | 대화방이 있는 동안(운영자가 삭제할 때까지) |
| 읽기 커서 · 읽음 위치 | 기기별 읽기 커서(순번), 사람별 **읽음 위치**(순번·시각) | 보관 정리 기준·안 읽음 표시를 기기 간에 공유 | 멤버인 동안(+ 제거 후 7일 유예) / 대화방이 있는 동안 |
| 메시지·첨부 **암호문** | MLS 로 암호화된 메시지 바이트(열 수 없음)와 그 메타데이터: 발신 기기 ID, 순번, 종류(commit/welcome/application), 시각, 해시. 첨부도 암호화된 바이트(크기·발신 기기·시각만 평문)로 보관되며 파일 키는 암호화된 메시지 안에만 있다 | 다른 기기에 전달 | 일반 메시지: 모든 참여 기기가 받아간 뒤 정리, **최대 30일**. 첨부: **최대 60일**. 그룹 키 갱신 기록(commit/welcome): 최근 8 epoch(안전 상한 256 epoch) |
| 키 패키지(공개) | 기기가 초대받기 위해 올려 두는 MLS **공개** 키 패키지 | 새 대화방 초대 | 대화방용 7일 · 로비용 30일(또는 사용 즉시) |
| 푸시 토큰 | iOS 앱의 APNs 기기 토큰과 앱 식별자(Android 는 푸시 없음) | 새 메시지 알림(내용 없음 — 「새 글」만) | 기기가 등록을 거둘 때(「서버 바꾸기」·앱 삭제 뒤 운영자 폐기)까지 |
| 서버 로그 | 요청 경로·상태·기기 ID·오류(토큰·메시지 내용 없음) | 장애 대응 | **30일**(운영 정책값) |
| 오프호스트 백업(스냅샷) | 위 저장소의 사본(암호문·메타데이터·정책 체인) | 서버 장애 복구 | 최근 48시간 전량 + 하루 1개 × **30일** — 삭제된 데이터가 백업에는 최대 30일 더 남을 수 있다 |

**이메일 주소**는 위 `subject` 로만 서버에 들어온다(Google 로그인 결과). 전화번호·주소·생년월일 등은 받지 않는다.

Cloudflare Access(로그인 창)는 Google 계정 이메일·로그인 시각을 **Cloudflare 의 Access 로그**에 남긴다(Cloudflare 개인정보처리방침 적용). 한데 서버는 그 로그에 접근하지 않는다.

### 2-2. 이 기기(앱 안)에만 저장되는 것
- 복호화된 대화 기록(`messages.db`), MLS 그룹 상태·서명 비밀키(Android Keystore / iOS Secure Enclave·Data Protection 으로 봉인), 로그인 세션 값(봉인), 설정(서버 주소·이름·읽음 위치). 앱 전용 저장소이며 **OS 백업·기기 이전에서 제외**된다. 앱을 삭제하거나 설정의 「이 기기 지우기」를 누르면 지워진다.

### 2-3. 수집하지 않는 것
- **메시지·첨부 내용**: 운영자도 볼 수 없다(종단간 암호화). 서버에는 암호문만 있다.
- **분석(애널리틱스)·크래시 리포팅·광고 SDK 없음**, 광고 식별자 없음, 추적(트래킹) 없음, 제3자 데이터 판매·공유 없음.
- **위치·연락처·사진·마이크 접근 없음**(첨부는 사용자가 고른 파일만 암호화해 전송). Android 앱 권한은 인터넷 하나다. iOS 는 알림 권한(선택)만 묻는다.
- 연령·성별·결제 정보를 받지 않는다. 유료 기능·인앱 결제 없음.

## 3. 이용 목적
가족 메신저 기능 제공(기기 등록·메시지 전달·알림)과 장애 대응. 그 밖의 목적(마케팅·프로파일링·판매·AI 학습)으로 쓰지 않는다.

## 4. 제3자 제공·처리 위탁
| 상대 | 무엇을 | 왜 |
|---|---|---|
| Cloudflare, Inc. | 서버 앞단(터널·TLS) 경유 트래픽(암호문·메타데이터), Access 로그인(Google 계정 이메일·로그인 시각) | 로그인 보호·네트워크 전달 |
| Google LLC | Google 계정 로그인(Cloudflare Access 의 신원 제공자) — 로그인 시 Google 이 보는 정보는 Google 정책 적용 | 로그인 신원 확인 |
| Apple Inc. | iOS 푸시 알림(APNs 토큰, 알림 내용 없음 — 대화방·순번만) | 새 메시지 알림 |

그 외 제공 없음. 법령에 따른 요구가 있어도 서버에는 암호문과 위 표의 메타데이터만 있다. 국외 이전: Cloudflare·Google·Apple 의 처리 위치는 각 사 정책을 따르며, 릴레이 서버의 위치는 운영자 문서(Family Wiki)에 적는다.

## 5. 보안
전송 구간 TLS, 메시지 종단간 암호화(MLS — 표준 알고리즘: X25519·AES-128-GCM·SHA-256·Ed25519), 기기 비밀키는 기기의 보안 하드웨어(Android Keystore StrongBox/TEE · iOS Secure Enclave/Data Protection)로 보호. 새 기기는 이미 쓰는 내 기기의 지문 비교 승인 또는 운영자의 대역외 승인으로만 등록된다. 서버는 폐기된 기기의 요청을 모두 거부한다.

## 6. 보관·삭제 — 이용자의 권리
- **이 기기의 자료 삭제**: 앱 설정 → 「이 기기 지우기」(즉시, 되돌릴 수 없음). 앱 삭제도 같은 효과다.
- **서버의 기기 기록 폐기·대화방 데이터 삭제·로그인 허용 해제**: [계정 및 데이터 삭제 안내](delete-account.md) 의 절차로 운영자에게 요청 — 접수 후 **7일 이내** 처리하고 회신한다. 기기 정책 체인은 변조 방지용 불변 기록이라 폐기된 기기의 **기기 ID·공개키·지문·`subject`** 는 「폐기됨」 상태로 남으며(그 외 용도 없음), 그 기기로는 어떤 요청도 할 수 없다. 암호문은 2-1 의 보관 기간이 지나면 자동 삭제되고, 백업에는 최대 30일 더 남을 수 있다.
- **열람·정정**: 서버에 사람이 읽을 수 있는 개인정보는 로그인 신원과 기기 기록뿐이며 연락처로 요청하면 제공·정정한다.
- 요청은 support@rnmaru.com 으로 보낸다(본인 확인: 로그인에 쓴 Google 계정에서 보낸 메일, 또는 가족 운영자가 직접 확인).

## 7. 아동
가족 구성원인 미성년자가 보호자(운영자)의 허용 아래 쓸 수 있다. 앱은 연령 정보를 수집하지 않으며 광고·외부 콘텐츠가 없다. 만 14세 미만(또는 거주국 기준 연령 미만) 아동의 계정은 보호자가 운영자로서 직접 허용·등록한다.

## 8. 변경
방침을 바꾸면 이 페이지에 시행일과 함께 게시한다(변경 이력은 이 저장소의 커밋 기록). 중요한 변경은 앱 알림 또는 가족 운영자가 직접 알린다.

---

## English summary
**Hande** (Android `com.seoyoon_family.hande`, iOS `com.seoyoon-family.hande`) is a family messenger with end-to-end encryption (IETF MLS). Developer/operator: the company operating **rnmaru.com**; contact **support@rnmaru.com**. Last updated 2026-10-29.

- The app talks only to the server you choose on the first screen. This policy covers the server operated by us (`relay.seoyoon-family.com`); another operator's server is covered by that operator's policy.
- **Stored on our server:** your login identity (the Cloudflare Access subject, an email address), a device record (app-generated device ID, your display name, public signing key, fingerprint, active/revoked state), pending device-approval requests (deleted after 10 minutes), room metadata (room name, members, sequence numbers, timestamps), read cursors/read positions, **ciphertext** of messages and attachments plus their metadata (sender device, sequence, time, hash), public MLS key packages, iOS APNs push tokens, and request logs (path, status, device ID; no content, no tokens).
- **Retention:** message ciphertext up to 30 days (attachments 60 days) after all members fetched it; key packages 7/30 days; approval requests 10 minutes; logs 30 days; off-host backups up to 30 days. The device-policy chain is append-only: a revoked device stays as a tombstone (device ID, public key, fingerprint, subject).
- **Not collected:** message or attachment plaintext (end-to-end encrypted; the operator cannot read it), analytics, crash reports, advertising identifiers, tracking, location, contacts, photos, microphone, age, payment data.
- **Third parties:** Cloudflare (edge transport, Access login logs), Google (identity provider for the login), Apple (APNs, no content).
- **Your rights:** wipe this device in-app (Settings → "Wipe this device"); ask us at support@rnmaru.com to revoke a device, delete room data, or remove your login — handled within 7 days. See the [account and data deletion page](delete-account.md).
