# 운영 안내

## 설치 신원과 포트

`server_name`은 Matrix 사용자 ID와 방 신원에 포함되어 설치 후 바꾸기 어렵습니다.
운영자와 이름을 확정한 후 **새 디렉터리·새 데이터베이스**에 초기화합니다.

```bash
python3 scripts/init.py \
  --server-name matrix.example.com \
  --web-url https://chat.example.com \
  --matrix-url https://matrix.example.com
docker compose config --quiet
docker compose up -d --wait --wait-timeout 120
python3 scripts/admin.py owner --admin
python3 scripts/admin.py family_member
```

예시 호스트를 실제 결정한 호스트로 바꿉니다. `.env`, `.runtime/`, 백업은 Git에 추가하지 않습니다.
초기화 실패 시 `.runtime-stage-*`를 무조건 삭제하지 말고 보존된 설정을 확인합니다.
root로 초기화하면 Synapse 파일은 컨테이너 전용 UID/GID 991, 그 외에는 실행한 사용자 UID/GID에 귀속됩니다.

## HTTPS 프록시

`deploy/Caddyfile.example`은 새 두 호스트를 위한 예시이며 운영 설정을 자동 변경하지 않습니다.
웹과 API는 다른 호스트를 사용합니다. 컨테이너 포트는 loopback만 열고 PostgreSQL 포트는 호스트에 공개하지 않습니다.
외부에는 client/media API만 전달하며 `/_synapse/admin`과 federation은 노출하지 않습니다.

Matrix API는 모바일 앱도 접근하므로 Cloudflare Access의 브라우저 로그인으로 감싸지 않습니다.
계정 인증은 Matrix가 담당하며 공개 가입은 닫혀 있습니다. 웹에 Access를 추가하더라도 앱·로그인 호환성을 먼저 확인합니다.
자동 백엔드 업데이트를 켜지 않고 digest 변경 PR에서 새 버전 시험 후 교체합니다.

Cloudflare Tunnel을 운영 서버에서 직접 실행하는 경우에는 Caddy 대신
`deploy/cloudflare-ingress.example.json`의 두 호스트를 확정한 이름으로 바꿔 전용 터널에 적용합니다.
Matrix client/media와 클라이언트 발견 경로만 전달하고 나머지는 404로 막습니다.
토큰은 root 전용 `/etc/family-messenger/cloudflared.token`에 저장하며,
`deploy/family-messenger-tunnel.service`는 systemd credential로 읽습니다.
기존 플릿 터널의 토큰이나 라우팅을 덮어쓰지 않습니다. 예시 파일은 자동 적용되지 않습니다.

## 저장공간 경보

`scripts/check_storage.py`는 데이터 삭제 없이 파일시스템 여유와 저장 트리의 할당량을 검사합니다.
심볼릭 링크·다른 파일시스템·읽기 실패는 정상으로 처리하지 않습니다.

```bash
python3 scripts/check_storage.py .runtime --min-free-gib 100 --max-retained-gib 150
```

초기 운영 제안값은 운영 서버 여유 100GiB 미만 또는 `.runtime` 150GiB 이상에서 경고입니다.
이는 업로드 차단이나 자동 삭제 정책이 아닙니다. 메시지 DB는 별도 Docker 볼륨에 있으므로
150GiB 트리 예산에는 포함되지 않으며, 전체 파일시스템 여유 검사에는 반영됩니다.
백업 목적지의 여유와 보존 세대도 별도로 점검합니다.

`deploy/family-messenger-storage.service`와 `.timer`는 `/opt/family-messenger` 설치를
시간마다 점검하는 예시입니다. 경고는 JSON 출력과 service 실패 상태로 남습니다.
외부 푸시 알림은 별도 연결이 필요하며, 타이머 설치만으로 가족에게 알림이 발송되지는 않습니다.
운영 폴더와 상위 경로는 운영자 소유로 유지합니다. 측정 중 파일 생성·삭제로 실패하면 다시 점검합니다.

## 계정·암호화

관리자가 가족 계정을 발급하고 필요한 방에 초대합니다. `--admin`은 운영자에게만 사용합니다.
가족의 암호화 키/복구 키를 수집하지 않습니다. 로그인 비밀번호 재설정은 잃어버린 암호화 키의 복구와 다릅니다.
Matrix 서버의 저장소 백업에도 사용자 기기의 복호화 키가 모두 들어 있는 것은 아닙니다.
현재 `/auth`는 Synapse 계정 인증을 사용합니다. Element X/OIDC(MAS), passkey/SSO 등은 후속 검증 대상입니다.

## 백업·복구 인수검사

### 매일 암호화 백업

`deploy/family-messenger-backup.service`와 `.timer`는 매일 한국시간 04:30~04:40에
PostgreSQL 덤프와 파일을 두 Restic 스냅샷으로 백업합니다. DB를 먼저 캡처하고 파일을 나중에 저장합니다.
자동 미디어 삭제를 켜지 않은 현재 구성에서 사용하며, **백업 중 수동 미디어 삭제·설정/비밀번호 변경·업그레이드를 하지 않습니다.**
수동 유지보수는 타이머를 중지하고 `/var/lib/family-messenger-backups/backup.lock` 잠금이 풀린 뒤 수행합니다.
이미 저장된 미디어 원본을 유지한다는 조건이며, 쓰기가 완전히 멈춘 스냅샷과 같지는 않습니다.

`/etc/family-messenger/backup.env`에는 Restic 저장소 URL과 비밀번호 파일 경로를 넣습니다.
실제 비밀번호는 root 전용 파일에 보관하고 Git/로그에 넣지 않습니다.
운영 서버 파일시스템 여유 100GiB, 백업 서버에는 현재 미디어 전체 크기와 추가 80GiB를 수용할 여유가 있어야 시작합니다.
자동 prune/forget/메시지 삭제는 하지 않습니다. 보관량이 증가하면 별도 용량 확보·보존 정책을 검토합니다.

두 스냅샷이 성공하고 필수 설정 파일이 유지됐을 때만
`/var/lib/family-messenger-backups/pair-*.json`에 완료 기록을 남깁니다.
한쪽만 생성된 실패 작업을 완전한 백업으로 사용하지 않습니다. DB 출력은 Restic으로 직접 전달되어 암호화됩니다.
실패는 systemd/journal에 남으며 외부 푸시 발송은 별도 연결해야 합니다.

복구 시 **같은 완료 기록의 `database_snapshot`과 `files_snapshot`**을 선택합니다.
파일 스냅샷을 격리 디렉터리로 복원하고 DB 스냅샷의 `/postgres.dump`를
새 PostgreSQL DB에 `pg_restore`한 다음, 원래 설치 신원/서명키와 UID/GID로 서비스를 시작합니다.
가장 최신 스냅샷 두 개를 임의로 조합하지 않습니다. 최초 복구 검사는 아래 정지 스냅샷 절차와 함께 수행합니다.

운영 시작 전 아래 절차를 별도 시험 환경에서 실행해야 합니다. 자동 복원 도구는 아직 제공하지 않습니다.

1. 설정 파일, PostgreSQL DB, Synapse 서명키·미디어를 같은 시점으로 백업합니다. DB만 백업하면 첨부/서명키를 잃을 수 있습니다.
2. 일관된 첫 백업은 Synapse를 정상 종료한 짧은 정지 구간에 DB 덤프와 `.runtime/synapse` 보관으로 만듭니다. 예시 SQL 덤프 명령은 `docker compose exec -T postgres pg_dump -U synapse -d synapse -Fc`입니다. 출력 파일은 생성 전 `umask 077`을 적용합니다.
3. 백업에는 등록 비밀키·서명키·DB 인증정보가 포함됩니다. 암호화하여 운영 서버와 다른 저장소에 보관합니다.
4. 동일 image digest로 격리 환경을 띄우고 PostgreSQL 복원, 설정·서명키·미디어 복원 후 계정·대화·첨부 및 두 기기의 키 복구를 검증합니다.
5. `docker compose down`은 데이터 볼륨을 보존합니다. 운영 환경에서 `down -v`나 `docker volume prune`을 사용하지 않습니다.

## 첫 운영 전 완료 기준

- 승인한 두 도메인의 TLS와 외부 관리자 API 차단 실측
- 관리자가 발급한 계정만 로그인 가능, 비초대 방 접근 거부
- 두 기기에서 실제 암호화 메시지 송수신·첨부·키 백업/복구
- 네트워크 단절 후 중복 없는 재연결·동기화
- 가족 기기별 백그라운드 알림 및 모바일 인증 호환성
- 별도 환경의 백업 복원 확인

`tests/smoke.py`는 합성 이벤트 전송 검사이며 이 전체 인수검사를 대체하지 않습니다.
