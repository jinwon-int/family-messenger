# App Store 심사 준비 — 한데 iOS (#584 PR 4)

> 대상: App Store Connect 의 **App Privacy(영양 성분표)** · **심사 노트(App Review Information)** · **수출 규정(Export Compliance)** · 스크린샷/리스팅 자산 · 가이드라인 4.2 대비. Google Play 쪽 양식은 [`play-data-safety.md`](play-data-safety.md), 양쪽 공용 체크리스트는 [`release-checklist.md`](release-checklist.md), 심사용 서버는 [`demo-server.md`](demo-server.md). 근거 표(릴레이가 실제로 저장하는 것)는 `play-data-safety.md` §0 — 이 문서의 답은 **같은 표**에서 뽑았다.
>
> 앱 식별: 번들 ID `com.seoyoon-family.hande`(NSE `…hande.nse`), 표시 이름 「한데」, 릴리스 워크플로 `.github/workflows/native-mls-ios-release.yml`(`marketing_version` 입력, `CURRENT_PROJECT_VERSION = run_number`). App Store 빌드는 `FC_RELAY_URL` 을 **비워** archive 해야 첫 화면이 서버 선택이 된다(`archive/native-mls/ios/README.md` 「온보딩 — 서버 선택」 5).

## 1. App Privacy (Privacy Nutrition Labels)

Apple 정의(「App privacy details on the App Store」): **「수집」= 기기 밖으로 전송되어 개발자나 제3자가 요청 처리 시간보다 오래 접근할 수 있는 형태로 저장되는 것.** 기기 안에서만 처리되는 데이터·요청 처리 뒤 바로 버리는 데이터는 신고하지 않는다. Apple 에는 Google 처럼 명시적인 「E2EE 면제」 문구가 없다 — 대신 정의 자체가 「개발자가 접근할 수 있는 형태」를 요구하므로, 운영자가 읽을 수 없는 **암호문은 「수집」에 들지 않는다**고 본다(아래 ⓐ 주의).

### 1-1. 답안

| 질문 | 답 |
|---|---|
| Do you or your third-party partners collect data from this app? | **Yes** |
| 수집 데이터 유형 | 아래 표 |
| Data used to track you | **없음**(광고·데이터 브로커·제3자 광고 SDK 없음) |
| Privacy Policy URL | `https://jinwon-int.github.io/family-messenger/hande/privacy/` |
| Privacy Choices URL(선택) | `https://jinwon-int.github.io/family-messenger/hande/delete-account/` |

| Apple 데이터 유형 | 수집 | 연결(Linked to you) | 추적 | 목적 | 근거(서버 저장 항목, `play-data-safety.md` §0) |
|---|---|---|---|---|---|
| Contact Info › **Email Address** | 예 | 예 | 아니오 | App Functionality | CF Access `subject`(이메일 형식) — 기기 정책 체인·`device_candidates`. 로그인 자체는 Cloudflare/Google |
| Contact Info › **Name** | 예 | 예 | 아니오 | App Functionality | `actor`(운영자가 정해 준 영문 이름 — 실명일 수 있음) — `mls_members`·`mls_read`·체인. 실명이 아니라고 확정하면 생략하고 User ID 만 |
| Identifiers › **User ID** | 예 | 예 | 아니오 | App Functionality | 체인의 기기 기록(actor + 기기 ID, 공개키·지문) = 계정 수준 식별자 |
| Identifiers › **Device ID** | 예 | 예 | 아니오 | App Functionality | 앱이 만든 기기 ID `<actor>-iphone-<난수>`(광고 ID·IDFV 아님) + **APNs 토큰**(`push_devices`) |
| User Content › **Other User Content** | 예 | 예 | 아니오 | App Functionality | 대화방 이름(사용자가 지음, 평문) · 참여 목록 · 읽음 위치 · 발신 시각 = 서버가 읽는 메타데이터 |
| User Content › **Emails or Text Messages** | **ⓐ 신고하지 않음**(아래) | — | — | — | 내용은 MLS E2EE — 서버·운영자가 읽을 수 없음. 메타데이터는 위 「Other User Content」로 신고 |
| Photos or Videos · Audio · Files | 신고하지 않음 | | | | 첨부 바이트·파일 키 모두 E2EE. 사진 라이브러리 접근 없음(사용자가 고른 파일만) |
| Location · Contacts · Health · Financial · Sensitive · Browsing/Search History · Purchases | 아니오 | | | | 수집·접근 없음 |
| Usage Data · Diagnostics(Crash/Performance) | 아니오 | | | | 분석·크래시 SDK 없음. 서버 요청 로그는 기기 ID(위 Device ID)와 경로뿐 |

**ⓐ 주의 — 「Emails or Text Messages」.** Apple 「Additional guidance」는 「앱 안에서 사용자 간 비 SMS 메시지를 제공하면 Emails or Text Messages 를 신고하라」고 적는다. 한데는 메시지 **내용**을 개발자가 읽을 수 없으므로 「수집」 정의(개발자가 접근 가능한 형태)에 들지 않는다고 판단해 신고하지 않는다 — 이것이 오너 결정 사항이다(Signal 등 E2EE 메신저의 라벨과 같은 입장). 보수적으로 가려면 「Emails or Text Messages — Linked, App Functionality」를 **추가**하고 방침 2-1 에 「서버는 암호문과 메타데이터만 보관」을 그대로 둔다. 어느 쪽이든 방침 문구와 라벨이 모순되지 않는다.

### 1-2. Privacy manifest(`PrivacyInfo.xcprivacy`)
- iOS 앱은 서드파티 SDK 없음(Rust FFI 정적 라이브러리 + SwiftUI). **Required Reason API** 사용 여부(UserDefaults 는 App Group 공유 — `NSPrivacyAccessedAPICategoryUserDefaults` 사유 `CA92.1`; 파일 타임스탬프·디스크 공간·시스템 부팅 시각 API 는 코드 grep 로 확인) → 해당하면 매니페스트에 적는다. `NSPrivacyTracking = false`, `NSPrivacyCollectedDataTypes` 는 1-1 표와 같게. 매니페스트 추가는 **앱 코드 PR**(이 문서 범위 밖) — 체크리스트 A-7.

## 2. 심사 노트(App Review Information) 템플릿

로그인 필요 앱이라 Apple 은 **심사용 계정**(또는 데모 모드)을 요구한다(가이드라인 2.1·2.3.x). 한데는 「서버 선택 → Google 로그인(CF Access) → 기기 등록」 3단계라 **데모 서버와 심사용 Google 계정**이 함께 있어야 한다([`demo-server.md`](demo-server.md)). 아래 자리표시 `〔 〕` 는 데모 서버를 세운 뒤 채운다 — **값을 저장소에 적지 않는다**(Wiki·콘솔에만).

```
Sign-in required: Yes
Username: 〔reviewer Google account, e.g. reviewer@rnmaru.com〕
Password: 〔App Store Connect 에만 입력〕

Notes:
Hande is an end-to-end encrypted family messenger. Accounts are provisioned by a family
operator, so we prepared a dedicated demo server and a reviewer account.

1. On the first screen ("서버 찾기" / Find server) enter the domain:  〔demo.rnmaru.com〕
   The app discovers the relay via /.well-known/hande and shows the server name "〔한데 데모〕".
   Tap "이 서버로 계속" (Continue with this server).
2. Enter a display name (lowercase letters), e.g.  reviewer
3. Tap "Google 계정으로 로그인" (Sign in with Google). A system browser sheet opens
   (Cloudflare Access). Sign in with the credentials above. The sheet returns to the app.
4. The app then shows "등록 대기" (waiting for device approval) with a fingerprint. Please
   leave it on that screen: a new device must be approved out of band by the family operator,
   and we approve the reviewer device within 10 minutes (〔hours, KST / UTC〕; outside those
   hours call 〔phone〕). After approval the app shows the room list with sample rooms
   ("가족" / Family, "사진" / Photos) that already contain messages from a demo bot.
5. Send a message in "가족"; the demo bot replies within a few seconds. Push notifications
   (APNs) are enabled on the demo server.

The demo server stores only ciphertext and metadata; it is isolated from our family server
and is reset after review. Account deletion: Settings → "이 기기 지우기" (Wipe this device)
plus the web request path at https://jinwon-int.github.io/family-messenger/hande/delete-account/
(no in-app account creation exists; accounts are created by the operator).

Contact: 〔name〕, 〔phone with country code〕, support@rnmaru.com
Demo credentials valid until: 〔YYYY-MM-DD KST〕
```

- 4번은 데모 서버 설계 §4-7 의 **운영자 수동 E1**(기본) 문구다. 첫 기기 자동 등록 플래그(§4-7-b, 릴레이 코드 변경)를 구현하면 「approval is automatic within ~10 seconds」 로 바꾼다. 어느 쪽이든 심사관이 기기를 바꾸면 같은 절차가 1회 더 필요하다는 점을 노트에 남긴다.
- Google 로그인 사용 시 「Sign in with Apple」 요구(가이드라인 4.8)는 **해당 없음** — 4.8 은 앱이 제3자 소셜 로그인을 「주된 계정 생성 수단」으로 쓸 때이고, 한데는 계정 생성이 없고(운영자 provisioning) 로그인은 운영자 서버의 접근 제어(Cloudflare Access)다. 심사 노트에 이 점을 한 줄 적는다. 심사관이 4.8 을 들면 반박 근거: 4.8 예외 「a company's own account setup and sign-in systems」(운영자가 구성한 Cloudflare Access).
- 가이드라인 5.1.1(v) 「계정 삭제」: 앱 안에서 계정을 **만들지 않으므로** 삭제 의무의 전제가 다르지만, 「이 기기 지우기」 + 웹 요청 경로를 노트에 적어 둔다(위 문구). 콘솔 「Privacy Choices」 에 삭제 안내 URL.

## 3. 수출 규정(Export Compliance) — 결정과 질문지 답

### 3-1. 사실
- 앱의 암호화: **IETF MLS(RFC 9420) — OpenMLS `0.9.0` + `openmls_rust_crypto` `0.6.0`**(RustCrypto: AES-128-GCM, ChaCha20-Poly1305, X25519/HPKE, Ed25519, HKDF, SHA-256; ciphersuite `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`)이 xcframework/`.so` 에 **정적으로 들어간다**. 즉 **OS 가 제공하는 암호화가 아닌, 표준 알고리즘의 자체 포함 구현**이다. libsodium 은 쓰지 않는다(iOS 파일 봉인은 CryptoKit `ChaChaPoly` = OS 제공, Android 는 Keystore = OS 제공). TLS 는 OS(URLSession/OkHttp+플랫폼 TLS).
- 독자(비표준) 알고리즘 없음.
- 소스는 공개 저장소(`jinwon-int/family-messenger`, OpenMLS 도 공개).

### 3-2. Apple 의 분류표(App Store Connect Help 「Export compliance documentation for encryption」)
| 사용 암호화 | Apple 이 요구하는 문서 |
|---|---|
| Apple OS 안의 암호화만 | 없음 |
| **OS 가 제공하지 않는 산업 표준 알고리즘** ← 한데 | **프랑스 암호화 신고서**(French encryption declaration) — **프랑스 App Store 에 배포할 때만** |
| 독자/비표준 알고리즘 | CCATS + 프랑스 신고서 |

### 3-3. 결정
1. **현재 `ITSAppUsesNonExemptEncryption: false`(`project.yml`) 유지** — Apple 의 표에서 한데(표준 알고리즘, OS 외)의 문서 요구는 「프랑스 배포 시 프랑스 신고서」뿐이므로, **프랑스를 배포 대상에서 제외하면 Apple 쪽 문서 요구가 없고** 키를 `false`(= 문서 제출 면제)로 둘 수 있다. 이것은 「OS 암호화만 쓴다」는 뜻이 아니라 「Apple 에 제출할 문서가 없다」는 뜻이며, `project.yml` 주석(「표준 암호화(App Store 면제 범주)」)은 그 의미로 읽는다. build 9(2026-10-13) 때 API 로 `usesNonExemptEncryption=false` 를 설정한 것과 같은 답이다.
2. **프랑스 제외**: App Store Connect → Pricing and Availability → 국가/지역에서 **France 체크 해제**(체크리스트 A-5). 나중에 프랑스를 넣으려면 ANSSI 신고서를 준비해 ASC 에 업로드하고 받은 코드를 `ITSEncryptionExportComplianceCode` 에 넣는다.
3. **미국 BIS 자체 분류(annual self-classification report, 15 CFR §742.15(b)/§740.17(e))**: Apple 은 「미국 서버에 업로드 = 수출」이라 EAR 적용 대상이라고 적는다(「Complying with Encryption Export Regulations」). 표준 알고리즘의 mass-market 암호화(ECCN 5D992.c, License Exception ENC §740.17(b)(1))는 매년 2월 1일까지 BIS·NSA 에 자체 분류 보고서(이메일)를 보내는 의무가 **수출자**에게 있다. 한데의 수출자가 누구인지(비미국 개발자 — Apple 이 수출자인지, 개발자인지)와 **공개 소스 예외**(§742.15(b): 공개된 암호화 소스와 그 오브젝트 코드는 BIS·NSA 에 소스 위치를 이메일 통지하면 EAR 적용 제외 — 한데·OpenMLS 모두 공개 소스)가 적용되는지는 법률 확인이 필요하다 → **「확인 필요 (non-US developer)」** 로 표시하고 체크리스트 A-6 에 둔다. 확인 전까지는 Apple 질문지에 사실대로 답하고(아래), 프랑스를 제외한 상태로 출시한다. 이 문서는 법률 자문이 아니다.
4. 「재검증(re-verify)」 — 오너 결정(2026-10-29): 자체 분류로 가되 스토어 제출 직전에 ASC 질문지의 실제 문구로 다시 확인한다. ASC 가 아래와 다른 질문을 보이면 이 절을 갱신한다.

### 3-4. 질문지 답(ASC, 2025 UI — 「App Encryption Documentation」/업로드된 빌드의 Manage)
| 질문 | 답 | 이유 |
|---|---|---|
| Does your app use encryption? | **Yes** | MLS·TLS |
| Does your app qualify for any of the exemptions provided in Category 5, Part 2 of the U.S. EAR? *(구 UI)* / What type of encryption algorithms does your app implement? *(신 UI)* | 구 UI: **Yes**(exemption — 표준 알고리즘·mass market) / 신 UI: **「Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system」** | OpenMLS 표준 알고리즘, 독자 알고리즘 없음 |
| Does your app implement any encryption algorithms that are proprietary or not accepted as standard by international standard bodies (IEEE, IETF, ITU, etc.)? | **No** | 전부 IETF/NIST 표준 |
| Is your app going to be available on the French App Store? | **No** | 프랑스 제외(3-3 ②) |
| (문서 업로드) | 요구되지 않음 | 위 표 |

ASC 가 「Export compliance information: Not required / Exempt」로 빌드를 풀면 `ITSAppUsesNonExemptEncryption: false` 가 그대로 맞다. ASC 가 문서를 요구하면(프랑스 포함했거나 질문이 바뀐 경우) 키를 지우고 질문지를 매 빌드 답하거나 `ITSEncryptionExportComplianceCode` 를 받는다.

### 3-5. Google Play
Play 에는 암호화 질문지가 없다. Play 개발자 배포 계약(「수출 법규 준수」)으로 개발자 책임이며 3-3 ③ 과 같은 확인 대상. Play 「App content」 의 선언들은 `play-data-safety.md`.

## 4. 스크린샷·리스팅 자산 체크리스트

| 자산 | 요건 | 준비 |
|---|---|---|
| 앱 아이콘 | 1024×1024 PNG(알파 없음) — `Assets.xcassets/AppIcon` 에 이미 있음(ASC 업로드 필수, run 38354223649 교훈) | 있음 |
| iPhone 스크린샷 | 6.9"(1320×2868 / 2868×1320) **필수**, 6.5"(1284×2778) 선택(없으면 6.9" 로 대체). 3~10장 | 시뮬레이터(iPhone 16 Pro Max)에서 데모 서버로 로그인한 화면: ① 서버 선택 ② 대화방 목록(안 읽음 배지) ③ 대화(봇 답장) ④ 새 기기 승인(지문 카드) ⑤ 설정(개인정보·삭제 링크·「이 기기 지우기」) |
| iPad | `TARGETED_DEVICE_FAMILY: "1"`(iPhone 전용) → iPad 스크린샷 불필요 | — |
| 프로모션 텍스트(170자) · 설명(4000자) · 키워드(100자) | 한국어 기본, 영어 보조 | 설명 초안: `index.md` 첫 문단 + 「운영자 서버 필요」 명시(4.2 대비, 아래 5) |
| 지원 URL | `https://jinwon-int.github.io/family-messenger/hande/` | Pages 게시 뒤 |
| 마케팅 URL(선택) | 같은 주소 | |
| 개인정보처리방침 URL | `…/hande/privacy/` | |
| 연령 등급 | 질문지: 사용자 생성 콘텐츠 **있음**(비공개 가족 간) · 무제한 웹 접근 없음 · 도박 없음 → 4+ 또는 12+(사용자 간 메시지 「빈번/강함」 답에 따라). Play IARC 와 같은 사실로 답한다 | |
| 카테고리 | Social Networking(1차) · Utilities(2차) | |
| 저작권 | 〔법인명〕 | |
| 심사 연락처 | 이름·전화·이메일(2절 템플릿) | |

Google Play 쪽 자산: 아이콘 512×512, 피처 그래픽 1024×500(필수), 휴대전화 스크린샷 2장 이상(16:9~9:16, 320~3840px), 짧은 설명 80자, 전체 설명 4000자 — 같은 화면을 Android 에뮬레이터(Pixel 8)에서 찍는다.

## 5. 가이드라인 4.2(최소 기능)·4.2.x 대비 — 「서버가 있어야 쓸 수 있는 앱」

심사관이 보기에 한데는 「계정도 못 만들고 서버 주소가 없으면 아무것도 못 하는 앱」이다. 거절 사유 후보: 4.2(Minimum Functionality), 2.1(불완전/크래시·데모 계정 없음), 5.1.1(v). 대응:

1. **데모 서버 + 심사 계정**(2절)으로 전 기능을 심사관이 직접 쓰게 한다 — 가장 큰 리스크 제거.
2. **온보딩 문구**(앱 코드 후속 PR, 체크리스트 A-8): 서버 선택 화면 상단에 「한데는 가족 운영자가 세운 서버에 연결하는 앱입니다. 운영자에게 서버 도메인을 받으세요. 직접 운영하려면 안내서(링크)」 + 도움말 링크(`…/hande/`). 심사관이 「서버 없이도 앱이 뭔지」 알게 한다(Element 「홈서버 선택」 화면과 같은 구성).
3. **빈 상태(empty states)**: 대화방 목록이 비었을 때 「참여 요청 중 — 운영자/다른 내 기기가 초대하면 여기에 보입니다」, 등록 대기 화면에 「이미 쓰는 내 기기에서 '새 기기 승인'」 안내 — 모두 이미 있음(`AppModel` phase 별 문구). 스크린샷에 빈 화면을 쓰지 않는다.
4. **스토어 설명에 명시**: 「가족 운영자가 운영하는 서버가 필요합니다(공개 가입 없음)」 — 심사관의 기대치를 맞춘다. 숨기면 2.3(정확한 메타데이터) 위반.
5. 「웹사이트 포장 앱」이 아님을 보이는 요소: 네이티브 E2EE·기기 승인·푸시·설정 — 스크린샷 ④⑤ 가 그 증거.
6. 거절되면 Resolution Center 에 2절 노트 + 이 절의 근거를 답하고, 필요하면 **심사용 영상**(데모 서버 로그인→메시지→승인 흐름, 1~2분)을 첨부한다.

---

## English summary
Export compliance: Hande ships OpenMLS (standard IETF algorithms, not provided by the OS) statically; no proprietary algorithms. Per Apple's table this requires only a French encryption declaration, and only if sold in France — so we **exclude France** initially and keep `ITSAppUsesNonExemptEncryption = false` (documentation-exempt), answering the questionnaire as "standard algorithms, not proprietary, not available in France". The US BIS annual self-classification report (and the public-source exemption) is marked **to be confirmed (non-US developer)**. App Privacy: Email, Name, User ID, Device ID, Other User Content (metadata) — linked, App Functionality, no tracking; message content is E2EE and not declared (owner decision; conservative alternative documented). Review notes: demo server + reviewer Google account via Cloudflare Access, see `demo-server.md`. 4.2 risk mitigated by the demo server, onboarding copy, and an honest store description.
