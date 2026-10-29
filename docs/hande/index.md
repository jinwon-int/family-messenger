# 한데(Hande)

가족끼리 쓰는 **종단간 암호화(E2EE, IETF MLS)** 메신저. 대화 내용은 보내는 기기에서 암호화되어 받는 기기에서만 풀리고, 서버는 암호문을 전달·보관할 뿐 열 수 없다. 가입은 공개되어 있지 않다 — 앱 첫 화면에서 **가족 운영자의 서버 도메인**을 입력하고, 그 운영자가 허용한 Google 계정으로 로그인한 뒤, 이미 쓰는 내 기기(또는 운영자)의 지문 비교 승인으로 새 기기를 등록한다.

- Android: `com.seoyoon_family.hande` (Google Play)
- iOS: `com.seoyoon-family.hande` (App Store)
- 개발·운영: rnmaru.com 을 운영하는 법인 · 문의 **support@rnmaru.com**
- 소스 코드: [github.com/jinwon-int/family-messenger](https://github.com/jinwon-int/family-messenger) (`archive/native-mls/`)

## 정책 문서
| 페이지 | 주소 |
|---|---|
| [개인정보처리방침](privacy.md) | `https://jinwon-int.github.io/family-messenger/hande/privacy/` |
| [계정 및 데이터 삭제 안내](delete-account.md) | `https://jinwon-int.github.io/family-messenger/hande/delete-account/` |

## 지원
- 이메일: support@rnmaru.com
- 서버가 다른 운영자의 것이면(앱 첫 화면에서 고른 도메인) 그 운영자에게 문의한다. 이 페이지의 정책은 rnmaru.com 을 운영하는 법인의 서버에 대한 것이다.

## 자주 묻는 것
- **로그인이 안 된다 / 「등록 대기」에서 멈춘다** — 첫 기기는 운영자의 대역외 승인이 필요하다. 두 번째 기기부터는 이미 쓰는 내 기기의 「새 기기 승인」에서 지문을 비교해 승인한다.
- **메시지를 서버에서 볼 수 있나** — 없다. 운영자도 암호문만 본다.
- **기기를 잃어버렸다** — 운영자에게 기기 폐기를 요청한다([삭제 안내](delete-account.md) 2절). 폐기 뒤 그 기기는 서버에 아무 요청도 할 수 없다.

## 저장소 안내(개발자용)
이 디렉터리(`docs/hande/`)의 Markdown 이 GitHub Pages(`.github/workflows/pages.yml`, 소스 = GitHub Actions)로 `https://jinwon-int.github.io/family-messenger/hande/<이름>/` 에 게시된다. Android 앱의 `BuildConfig.PRIVACY_URL`/`DELETE_ACCOUNT_URL` 기본값(`archive/native-mls/android/app/build.gradle.kts`)은 `…/hande/privacy` · `…/hande/delete-account`(끝 `/` 없음)이며, GitHub Pages 가 디렉터리 경로를 301 로 `…/privacy/` 에 보내므로 같은 페이지가 열린다. 스토어 콘솔에는 끝 `/` 가 붙은 정식 주소를 적는다. 주소를 바꿀 때는 repo variables `HANDE_PRIVACY_URL`/`HANDE_DELETE_URL`(`native-mls-android.yml`)과 콘솔 값을 함께 바꾼다. 같은 디렉터리의 심사 준비 문서도 함께 게시된다(비밀값 없음 — 저장소가 공개라 게시 여부와 무관): [App Store 심사 준비](app-store-review.md) · [Google Play Data safety 입력표](play-data-safety.md) · [심사용 데모 서버 설계](demo-server.md) · [출시 체크리스트](release-checklist.md).

---

## English summary
**Hande** is a family messenger with end-to-end encryption (IETF MLS). You pick your family operator's server domain on the first screen, log in with a Google account that operator allowed, and enroll each new device by fingerprint comparison on a device you already use. The server only relays ciphertext. Developer: the company operating rnmaru.com — support **support@rnmaru.com**. Policies: [Privacy policy](privacy.md) · [Account and data deletion](delete-account.md).
