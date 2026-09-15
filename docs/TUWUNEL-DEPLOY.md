# Tuwunel 배포 런북 — 가족 메신저 홈서버

상태: **배포 패키지 문서**(2026-09-13). 실제 운영 배포는 [로드맵 #92](https://github.com/jinwon-int/family-messenger/issues/92) 1단계에서
**별도 승인** 후 이 절차로 수행한다. 근거: [결정 D](DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md),
[홈서버 평가](evidence/homeserver-eval-20260913.md). 파일: [`deploy/tuwunel/`](../deploy/tuwunel/README.md).
이 문서에는 실제 도메인·토큰·터널 ID를 쓰지 않는다.

## 0. 전제

- Linux x86_64, systemd, `dpkg-deb`(deb 추출) 또는 `zstd`, `curl`, `python3`, `sha256sum`.
- **CPU가 x86-64-v3를 지원해야 한다**(AVX·AVX2·BMI1/2·FMA·F16C·LZCNT·MOVBE·XSAVE). 고정 자산이 v3 빌드라서, 없는 호스트에서는 바이너리가 `Illegal instruction`으로 즉사한다(2026-09-13 저사양 노드 실측). `fetch-tuwunel.sh`가 다운로드 전에 `/proc/cpuinfo`를 검사해 exit 78로 멈춘다. 그런 호스트에는 v1/v2 자산을 교차 검증해 pins에 추가한 뒤 쓴다.
- 리버스 프록시는 cloudflared 터널. Tuwunel은 `127.0.0.1:8008`에만 듣는다.
- 운영 호스트에 기존 Synapse 구성이 있으면 **그대로 둔 채** 다른 포트·디렉터리·도메인으로 병행 설치한다. Synapse → Tuwunel DB 이관은 지원되지 않으며(업스트림 명시), 우리 Synapse는 메시지 0건이므로 이관하지 않고 계정만 재생성한다.

## 1. 바이너리 받기 (해시 검증)

```bash
git clone https://github.com/jinwon-int/family-messenger && cd family-messenger
deploy/tuwunel/fetch-tuwunel.sh --dest /opt/tuwunel        # deb 자산 → sha256 대조 → 바이너리 추출·대조 → /opt/tuwunel/tuwunel
/opt/tuwunel/tuwunel --version                               # tuwunel 1.9.1
```

- 업스트림은 릴리스 체크섬·서명을 공개하지 않는다. `tuwunel.pins.json`의 값이 기준이며, 불일치면 스크립트가 파일을 지우고 exit 1로 멈춘다.
- **버전 올리기**: 새 릴리스의 deb·zst를 각각 받아 추출 바이너리 해시가 서로 같은지 확인 → `tuwunel.pins.json` 갱신 PR → 머지 후 배포. 릴리스 노트의 마이그레이션·백업 경고를 먼저 읽는다.

## 2. 사용자·디렉터리·설정

```bash
useradd --system --home-dir /var/lib/tuwunel --shell /usr/sbin/nologin tuwunel
install -d -m 0700 -o tuwunel -g tuwunel /var/lib/tuwunel
install -d -m 0700 -o tuwunel -g tuwunel /var/lib/tuwunel-backups  # 백업 도구가 요구 — 바이너리가 자동 생성하지 않는다(2026-09-15 실측)
install -d -m 0750 -o root -g tuwunel /etc/tuwunel
install -m 0640 -o root -g tuwunel deploy/tuwunel/tuwunel.toml.example /etc/tuwunel/tuwunel.toml
# server_name, well_known.client 채우기. server_name은 나중에 바꿀 수 없다.
python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > /etc/tuwunel/registration_token
chown root:tuwunel /etc/tuwunel/registration_token && chmod 0640 /etc/tuwunel/registration_token  # 값은 어디에도 기록하지 않는다
# [2026-09-15 yukson 실측] LoadCredential(/run/credentials/...)은 서비스 정지 시 사라져 복원 드릴의
# 원샷 복원이 실패한다 — 서비스 사용자가 직접 읽는 정적 경로를 쓴다(소유 root:tuwunel 0640).
install -m 0644 deploy/tuwunel/tuwunel.service /etc/systemd/system/tuwunel.service
systemctl daemon-reload && systemctl enable --now tuwunel
journalctl -u tuwunel -n 50 --no-pager                       # "listening" 확인, WARN 없는지
```

설정 핵심(평가 실측 근거): 가입은 `registration_token_file`만, `allow_guest_registration=false`, `allow_federation=false`,
`encryption_enabled_by_default_for_room_type="invite"`, `max_request_size="100 MiB"`, `allow_legacy_media=false`,
URL 미리보기 허용목록 비움, `ip_source="cf_connecting_ip"`(미설정 시 IP 위조 가능).

## 3. 터널 ingress

`deploy/tuwunel/cloudflare-ingress.example.json`대로 **client API·인증 미디어·`/_matrix/versions`·`/.well-known/matrix/client`만** 노출한다.
`/_synapse/admin`, `/_matrix/federation`, `/_matrix/key`는 규칙이 없어 404로 떨어진다. 관리 API는 호스트 안에서 `127.0.0.1:8008`로만 부른다.

## 4. 첫 관리자와 검증 체크리스트

첫 가입자가 서버 관리자가 되고 `#admins:<server_name>` 방이 생긴다. 등록 토큰으로 운영자 계정 1개를 만든 뒤 아래를 **모두** 기록한다.

| 검사 | 기대 | 방법 |
|---|---|---|
| 토큰 없는 가입 | 401, flows=`m.login.registration_token` | `POST /_matrix/client/v3/register` 빈 auth |
| 게스트 | 403 `M_GUEST_ACCESS_FORBIDDEN` | `?kind=guest` |
| 연합 | 외부에서 `/_matrix/federation/v1/version` 404(터널) · 설정 `allow_federation=false` | curl 외부 |
| 방 암호화 기본 | `createRoom(preset=private_chat)` 후 `m.room.encryption` 상태 존재 | 클라이언트 API |
| 비인증 미디어 | `/_matrix/media/v3/download/...` 403 | curl 무토큰 |
| 인증 미디어 | 30 MiB·90 MiB 업로드 후 다운로드 sha256 일치, 120 MiB → 413 | 터널 경유로 실측(CF 100 MB 경계) |
| well-known | `https://<server_name>/.well-known/matrix/client` → `m.homeserver.base_url` | curl |
| 관리 API | 호스트 내부 `GET /_synapse/admin/v1/rooms` 200, 비관리자 403, 터널 밖 404 | curl |
| 백업 | `!admin server backup-database` → `list-backups` → `verify-backup` "all files present" | admin 방 또는 `--execute` |

알려진 거친 부분: `PUT /_synapse/admin/v2/users/{id}`에 `admin:false`를 포함하면 사용자는 생성되지만 500이 온다 → `admin` 필드는 true일 때만 보낸다(#97 `admin.py`가 처리).

## 5. 백업·복원 (요약; 상세는 #97 산출 `docs/TUWUNEL-OPERATIONS.md`)

- 온라인 백업은 **RocksDB만** 포함한다. `media/`는 별도로 restic에 넣어 **쌍**으로 기록한다.
- 복원: 서비스 정지 → `mv /var/lib/tuwunel/db /var/lib/tuwunel/db.pre-restore` → `tuwunel -c tuwunel.toml --restore-backup --maintenance --execute "server shutdown"` → 미디어 `cp -a src/. dst/`(Tuwunel이 빈 `media/`를 먼저 만들어 `cp -a src dst`는 건너뛴다) → 시작 → 메시지 수·로그인 확인. 평가에서 330 ms, 20/20 event_id 일치.
- 복원 드릴은 격리 디렉터리·임시 포트에서 월 1회.

## 6. 업그레이드

1. 릴리스 노트 확인(1.8→1.9는 첫 기동 시 리스너를 열기 **전에** DB 마이그레이션 — 그동안 강제 종료 금지).
2. 백업 쌍 1회 성공 확인.
3. `fetch-tuwunel.sh --dest /opt/tuwunel`(pins 갱신본) → `systemctl restart tuwunel` → journal에서 마이그레이션 완료·listening 확인 → 4장 체크리스트 재실행(가입 401·비인증 미디어 403·암호화 기본).
4. 문제 시 롤백: 정지 → `/opt/tuwunel/tuwunel` 심볼릭 링크를 이전 `tuwunel-vX.Y.Z`로 → DB는 **복원**(다운그레이드 마이그레이션은 없음) → 시작.

## 7. 알려진 위험 (평가에서 넘어온 항목)

- 릴리스 체크섬·서명 미공개 → 해시 고정 + deb↔zst 교차 확인을 릴리스마다 반복.
- CF 요청 본문 100 MB 한도 = `max_request_size`와 같은 경계 → 터널 경유 대용량 실측 필수.
- 서버 계정명이 `@conduit:<server_name>`로 표시됨 → 웹 화면에서 표시명 처리(#95).
- 유휴 스레드 600여 개는 12 vCPU 호스트 측정값 → 저사양 호스트 재측정.
