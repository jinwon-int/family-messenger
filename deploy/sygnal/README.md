# deploy/sygnal — 푸시 게이트웨이 배포 패키지

가족이 앱을 닫아둔 동안에도 새 메시지를 알리기 위한 **Matrix 푸시 게이트웨이 Sygnal**의 배포 파일이다.
절차와 검증 체크리스트는 [`docs/SYGNAL-DEPLOY.md`](../../docs/SYGNAL-DEPLOY.md).

**왜 필요한가**: Matrix 스펙상 홈서버는 푸시 게이트웨이까지만 말하고 APNs/FCM/WebPush 벤더 연동은
게이트웨이의 몫이다([push gateway API](https://spec.matrix.org/v1.19/push-gateway-api/)).
Tuwunel은 `PusherKind::Http`만 구현하고 벤더 연동 코드가 없으므로, **게이트웨이 없이는 알림이 0건**이다.

| 파일 | 용도 |
|---|---|
| `sygnal.pins.json` | 이미지 digest·버전·라이선스 고정값. sygnal은 단일 바이너리도 PyPI 배포도 없어(2026-09-21 확인) 공식 경로가 컨테이너뿐이다. 이미지는 `poetry.lock`에서 내보낸 해시 포함 requirements로 빌드되므로 digest 고정이 곧 의존성 고정이다 |
| `sygnal.yaml.example` | webpush 앱 설정. 네이티브 apns 블록은 주석으로 예비 — 한 인스턴스가 둘 다 처리한다 |
| `sygnal.service` | 강화 systemd 유닛(전용 사용자, digest 고정 실행, 루프백 바인드, read-only 컨테이너) |
| `gen-vapid-key.sh` | VAPID 키쌍 생성(이미지의 `vapid` CLI 사용). 개인키는 저장소 밖에만 쓰고 기존 키를 덮어쓰지 않는다 |
| `cloudflare-ingress.example.json` | `POST /_matrix/push/v1/notify` 하나만 노출하는 터널 ingress |

## 한 인스턴스가 PWA와 네이티브를 모두 덮는다

`sygnal/sygnal.py`의 `_make_pushkin`이 `type` 값으로 `sygnal.{type}pushkin`을 동적 import 하고,
`http.py`의 `find_pushkins(appid)`가 홈서버가 보낸 `devices[].app_id`로 라우팅한다.
**`apps:` 아래 app_id별로 타입을 독립 지정하며 혼합에 제약이 없다** — webpush 앱을 지금 쓰고,
네이티브 iOS 착수 시([#165](https://github.com/jinwon-int/family-messenger/issues/165))
`sygnal.yaml`의 apns 블록만 주석 해제하면 된다.

**Apple Developer Program($99/년)은 웹푸시만이면 불필요하다** — [Apple 공식 문서](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)가 명시한다.
네이티브 앱 배포와 APNs p8 키 발급에만 필요하다.

## ⚠ 조용한 유실 4종

sygnal webpush는 **실패해도 조용한 경로가 많다.** 알림이 안 오는데 홈서버는 정상으로 보이는 것이
기본 동작이므로, 배포 후 반드시 로그를 관측한다. 진단 절차는 런북 참조.

1. **`allowed_endpoints` 차단** — `return []`만 하고 pushkey를 reject하지 않는다. Apple 엔드포인트를 빠뜨리면 여기 걸린다
2. **4KB 초과** — 필드별 자르기(`MAX_BODY_LENGTH=1000`, `MAX_CIPHERTEXT_LENGTH=2000`)만 있고 전체 직렬화 크기 검사가 없다. Apple은 `413`을 주지만 sygnal은 `>=400`을 경고 로그만 남긴다(404/410만 reject)
3. **TTL 만료** — 기본 900초
4. **Urgency 고정** — `low`/`normal`만 보내고 Apple의 `high`를 쓰지 않는다. 설정 키가 없어 코드 수정 없이는 못 바꾼다(수정 시 AGPL 네트워크 조항 판단 선행)

## 알려진 제약

- **암호문 컷오프**: `MAX_CIPHERTEXT_LENGTH=2000` 때문에 긴 메시지는 암호문이 통째로 버려진다.
  실측 경계는 **한국어 438자 / 영문 1314자**(megolm 암호화 이분탐색, 2026-09-21).
  클라이언트는 이 경우 본문 없는 대체 알림으로 폴백해야 한다 —
  [#167](https://github.com/jinwon-int/family-messenger/issues/167)
- **webpush는 sygnal에서 2등 시민**이다. README가 webpush를 누락하고, 실질 기능 변경이 2021-12 이후 없으며,
  webpush 관련 Sentry 오류 조사 티켓 2건(element-hq/sygnal#205·#204)이 open으로 남아 있다
- **iOS 실동작은 미확인**이다. 프로토콜 적합성은 Apple 요구사항과 일치하나 1차 보고를 찾지 못했다.
  실기기 검증이 배포의 수용 기준이다
- **리포 이전**: `matrix-org/sygnal`은 2025-07-21 아카이브. 유지보수는 `element-hq/sygnal`이지만
  컨테이너 이미지는 이전 후에도 `matrixdotorg/sygnal`로 계속 배포된다(v0.17.0이 2025-12-10 푸시)
- **라이선스**: AGPL-3.0-only OR Element Commercial(2025-06 전환). 무수정 자체 운영은 무난하나
  수정 후 운영하면 네트워크 조항이 적용된다

이 디렉터리는 코드·문서만이다. 실제 운영 배포는 별도 승인 후 런북대로 진행하며,
여기에 실제 도메인·이메일·VAPID 키·터널 ID를 쓰지 않는다.
