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

## 계정·암호화

관리자가 가족 계정을 발급하고 필요한 방에 초대합니다. `--admin`은 운영자에게만 사용합니다.
가족의 암호화 키/복구 키를 수집하지 않습니다. 로그인 비밀번호 재설정은 잃어버린 암호화 키의 복구와 다릅니다.
Matrix 서버의 저장소 백업에도 사용자 기기의 복호화 키가 모두 들어 있는 것은 아닙니다.
현재 `/auth`는 Synapse 계정 인증을 사용합니다. Element X/OIDC(MAS), passkey/SSO 등은 후속 검증 대상입니다.

## 백업·복구 인수검사

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
