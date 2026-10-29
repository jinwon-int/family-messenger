# 한데 출시 체크리스트 — 오너·노드 역할표 (#584 PR 4)

> 「누가」: **오너** = 콘솔·계정·비밀·승인이 필요한 일(Apple/Google/Cloudflare/Workspace 로그인 주체). **노드** = 저장소·워크플로·문서·서버 작업(오너 승인 뒤 실행). 「의존」 = 그 항목이 기대는 저장소 파일·문서. 완료 표시는 #584(또는 후속 이슈)에 코멘트로 남긴다. 상태 열은 2026-10-29 기준.

## 0. 공통 — 정책 페이지 게시(양쪽 스토어 선행 조건)

| # | 항목 | 누가 | 의존 | 상태 |
|---|---|---|---|---|
| 0-1 | **GitHub Pages 켜기**: repo Settings → Pages → **Build and deployment → Source: GitHub Actions**(브랜치 소스 아님). 저장소 설정 변경 = 오너 승인 항목 | 오너 | `.github/workflows/pages.yml` | 대기(현재 Pages 404) |
| 0-2 | PR 4 머지 → `pages.yml` 이 main 푸시로 돌아 `https://jinwon-int.github.io/family-messenger/hande/{,privacy/,delete-account/}` 200 확인 | 노드 | `docs/hande/*.md` | 대기 |
| 0-3 | 방침의 `〔법인명〕` 자리를 스토어 등록 명의(법인명)로 채운다 — Apple·Google 계정의 조직명과 글자 그대로 일치 | 오너(값) → 노드(PR) | `docs/hande/privacy.md` | 대기 |
| 0-4 | 서버 로그 보존 30일을 실제로 맞춘다(seoseo journald `MaxRetentionSec=30day` 또는 릴레이 유닛의 로그 설정) — 방침 2-1 표의 값 | 노드(배포 승인 뒤) | `docs/hande/privacy.md` 2-1 · `docs/NATIVE-RELAY-OPERATIONS.md` | 대기 |
| 0-5 | Android `BuildConfig` 기본 URL(`…/hande/privacy`, `…/hande/delete-account`)이 Pages 301 로 열리는지 실기기 확인. 바꾸려면 repo variables `HANDE_PRIVACY_URL`/`HANDE_DELETE_URL` | 노드 | `archive/native-mls/android/app/build.gradle.kts` · `native-mls-android.yml` | 대기 |
| 0-6 | 심사용 데모 서버 세우기(오너 승인: 서서 배포 · CF Access/DNS · Workspace 계정) + 추적 이슈에 **종료 일시(KST 절대시각)** 코멘트 | 오너(승인·계정) → 노드(실행) | `docs/hande/demo-server.md` | 설계만 |

## A. Apple — App Store

| # | 항목 | 누가 | 의존 | 상태 |
|---|---|---|---|---|
| A-1 | App Store Connect 앱 레코드: 이름 「한데」, 번들 ID `com.seoyoon-family.hande`(NSE `…hande.nse`), SKU, 1차 언어 한국어 | 오너 | `archive/native-mls/ios/project.yml` | TestFlight 에 이미 존재(build 9 이력) — App Store 정보 탭만 채우면 됨 |
| A-2 | **App Store 빌드**: `native-mls-ios-release.yml` 을 `workflow_dispatch` 입력 **`distribution = appstore-public`** 으로 실행(`FC_RELAY_URL` 빈 값 → 첫 화면 = 서버 선택; 기본 `testflight-family` 는 지금까지의 가족 빌드). environment `testflight` 승인·서명·업로드는 같다. 아카이브 검증 단계가 앱·NSE `FamilyChatRelayURL` 빈 값과 Privacy manifest 2개를 확인 | 오너(dispatch 승인) | `.github/workflows/native-mls-ios-release.yml` · `ios/README.md` 「온보딩」5 | 코드 PR 머지 뒤 실행 |
| A-3 | 개인정보처리방침 URL `…/hande/privacy/` · Privacy Choices URL `…/hande/delete-account/` · 지원 URL `…/hande/` | 오너 | `docs/hande/privacy.md` | 0-2 뒤 |
| A-4 | App Privacy 라벨 입력(Email · Name · User ID · Device ID · Other User Content, Linked, App Functionality, 추적 없음) + 「Emails or Text Messages」 신고 여부 **오너 결정** | 오너 | `docs/hande/app-store-review.md` §1 | 대기 |
| A-5 | 수출 규정: 질문지 답(표준 알고리즘·비독자·**프랑스 아니오**) + Pricing and Availability 에서 **France 제외** + `ITSAppUsesNonExemptEncryption: false` 유지 | 오너 | `app-store-review.md` §3 · `project.yml` | 대기 |
| A-6 | **US BIS 자체 분류 보고/공개 소스 예외 — 확인 필요(non-US developer)**: 법률 확인 뒤 결과를 `app-store-review.md` §3-3 ③ 에 기록. 출시를 막지는 않음(Apple 요구 문서 없음) | 오너 | `app-store-review.md` §3-3 | 확인 필요 |
| A-7 | Privacy manifest(`PrivacyInfo.xcprivacy` 앱·NSE: Required Reason API UserDefaults `CA92.1`+`1C8F.1` · FileTimestamp `C617.1`, 수집 유형 = §1-1, 추적 없음) — 코드 PR 에 포함. 업로드 뒤 ITMS-91053 메일이 오면 범주 추가 | 노드(PR) / 오너(메일 확인) | `app-store-review.md` §1-2 · `ios/README.md` 「App Store 준비」 | 코드 PR |
| A-8 | 4.2 대비 온보딩 문구(서버 선택 화면 안내 + 안내서·개인정보처리방침 링크, 이름·로그인 화면 설명) + 설정 「정책」 링크·앱 버전 — iOS 코드 PR 에 포함(Android 는 #588 에 설정 링크, 서버 화면 안내 문구는 후속) | 노드 | `app-store-review.md` §5 · `ios/README.md` 「App Store 준비」 | iOS 코드 PR / Android 후속 |
| A-9 | 심사 노트: 데모 서버 도메인·심사관 계정·절차·연락처·유효기한(KST) — `〔 〕` 채우기, 비밀번호는 ASC 에만 | 오너 | `app-store-review.md` §2 · `demo-server.md` | 0-6 뒤 |
| A-10 | 스크린샷 6.9"(3~10장) · 설명(「운영자 서버 필요」 명시) · 키워드 · 카테고리 Social Networking · 연령 등급 질문지 · 저작권 | 오너(승인·문안 확정) / 노드(시뮬레이터 캡처·초안) | `app-store-review.md` §4 | 대기 |
| A-11 | 빌드 선택 → 심사 제출. 거절 시 Resolution Center 답변 근거 = `app-store-review.md` §5 | 오너 | | |
| A-12 | 승인 뒤: 데모 서버 철거 또는 보존 결정, 추적 이슈 종료 코멘트 | 오너(결정) / 노드(실행) | `demo-server.md` §7 | |

## B. Google — Google Play

| # | 항목 | 누가 | 의존 | 상태 |
|---|---|---|---|---|
| B-1 | Play Console **조직 계정**($25): D-U-N-S = Apple 가입 때 번호 **재사용**, 결제 프로필의 법인명·주소를 D&B 등록과 일치, 조직 도메인 Google 계정 + 법인 서류 + 대표 신분증 검증 | 오너 | #584 결정 코멘트(2026-10-29) | 대기 |
| B-2 | 업로드 키 생성(PKCS12, 25년+) → GitHub **secrets 4개**(`HANDE_UPLOAD_KEYSTORE_B64`·`HANDE_UPLOAD_KEYSTORE_PASSWORD`·`HANDE_UPLOAD_KEY_ALIAS`·`HANDE_UPLOAD_KEY_PASSWORD`). 키스토어 보관 위치만 Wiki 에 | 오너 | `android/README.md` ② | 대기 |
| B-3 | `native-mls-android.yml` **workflow_dispatch**(`version_name` 예 `0.2.0`) → 서명된 `app-release.aab` 아티팩트(`hande-android-bundle-<sha>`) · 서명자 ≠ 디버그 키 검증 통과 | 노드(dispatch) / 오너(승인) | `android/README.md` ③④ | 대기 |
| B-4 | 앱 만들기(`com.seoyoon_family.hande`, 한국어) → Play App Signing(Google 생성 키) 수락 → **내부 테스트 트랙**에 AAB 업로드 → 테스터(오너 기기) 설치 확인 | 오너 | B-2·B-3 | 대기 |
| B-5 | App content › **개인정보처리방침 URL** `…/hande/privacy/`(앱 안 링크와 동일) | 오너 | `docs/hande/privacy.md` | 0-2 뒤 |
| B-6 | App content › **Data safety**: `play-data-safety.md` §1 그대로 입력(수집 있음 · 전송 암호화 · 삭제 요청 방법 있음 · E2EE 메시지 신고 안 함 · 식별자/이메일/이름/앱 활동) | 오너 | `docs/hande/play-data-safety.md` | 대기 |
| B-7 | App content › **계정 삭제**: 「앱 내 삭제 경로 제공」 예 + **웹 삭제 요청 URL** `…/hande/delete-account/` + 「일부 데이터 보관」(사유: 변조 방지 보안 기록 = 체인 tombstone) | 오너 | `delete-account.md` | 0-2 뒤 |
| B-8 | App content › **App access**: 로그인 필요 → 데모 서버 도메인·심사관 계정·절차(A-9 와 같은 내용, 1세트) | 오너 | `demo-server.md` | 0-6 뒤 |
| B-9 | App content › **콘텐츠 등급**(IARC 설문: 사용자 간 소통 있음 · 개인정보 공유 가능 · 폭력/도박 없음) · 광고 없음 · 뉴스 앱 아님 · 건강/금융 해당 없음 · 정부 앱 아님 · 타깃 연령(가족 — 「아동 대상 아님」 선택 시 아동 정책 미적용; 13세 미만 포함하면 가족 정책 요건 — **오너 결정**) | 오너 | `play-data-safety.md` 「콘솔의 다른 선언」 | 대기 |
| B-10 | 스토어 등록 정보: 아이콘 512 · 피처 그래픽 1024×500 · 스크린샷 2장+ · 짧은/전체 설명(「운영자 서버 필요」 명시) · 카테고리 소셜 · 연락처 이메일 support@rnmaru.com | 오너(확정) / 노드(초안·캡처) | `app-store-review.md` §4 | 대기 |
| B-11 | 내부 테스트 → (조직 계정: 비공개 테스트 12명×14일 **면제**) → **production 신청** → 심사(수일, 확대 심사 7일+) | 오너 | #584 조사 코멘트 | |
| B-12 | 승인 뒤: 데모 서버 철거/보존(A-12 와 공동), 추적 이슈 종료 코멘트 | 오너/노드 | `demo-server.md` §7 | |

## C. 코드 쪽 남은 PR(이 체크리스트가 기대는 것)
| 항목 | 설명 | 의존 |
|---|---|---|
| iOS App Store 빌드 워크플로(A-2) | `distribution` 입력(`appstore-public` = `FC_RELAY_URL` 빈 값 archive) — iOS App Store 준비 PR(`feat/ios-appstore-readiness`) | `native-mls-ios-release.yml` |
| Privacy manifest(A-7) | `PrivacyInfo.xcprivacy` 앱·NSE — 같은 PR | iOS 앱 |
| 온보딩 문구·도움말 링크(A-8) | 서버 선택 화면 안내·정책 링크 — iOS 는 같은 PR, Android 서버 화면 안내 문구는 후속 | 양쪽 앱 |
| (선택) 데모 첫 기기 자동 승인 플래그 | `demo-server.md` §4-7-c — 릴레이 코드 | `server/devices.go` |

---

## English summary
Owner items: enable GitHub Pages (Source: GitHub Actions), fill in the legal entity name, Apple (app record, privacy URLs, App Privacy answers, export compliance answers + exclude France, review notes with demo credentials, screenshots, submit) and Google (organization account reusing the Apple D-U-N-S, upload-key secrets, AAB via `workflow_dispatch`, internal testing track, App content declarations incl. account-deletion URL, Data safety, content rating, production). Node items: Pages publish check, log-retention setting, demo server build-out after approval, screenshot drafts, and three follow-up code PRs (App Store build input, privacy manifest, onboarding copy). The BIS self-classification question is flagged "to be confirmed (non-US developer)" and does not block submission.
