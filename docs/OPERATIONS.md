# 운영 안내

## 설치 신원과 포트

`server_name`은 Matrix 사용자 ID와 방 신원에 포함되어 설치 후 바꾸기 어렵습니다.
운영자와 이름을 확정한 후 **새 데이터베이스·새 미디어 트리**로 초기화합니다.

홈서버는 단일 바이너리 Tuwunel이며 바이너리 확보·설정·systemd 설치 절차는
[Tuwunel 배포 런북](TUWUNEL-DEPLOY.md)을 따릅니다. 설정은 `deploy/tuwunel/tuwunel.toml.example`
형태로 두고, 리스너는 루프백(address)에만 바인딩합니다. 외부 노출은 터널/리버스 프록시가 담당합니다.
이전 Synapse/Element/Postgres 구성(`compose.yaml`, `scripts/init.py`)은 `archive/synapse-stack/`에
보관됐으며 새 설치에 사용하지 않습니다. 운영 호스트가 아직 기존 구성으로 서비스 중이라면
호스트 전환은 별도 운영 작업(1단계 배포)으로 수행합니다.

계정 발급은 `scripts/admin.py`로 끝냅니다. 스크립트는 `.runtime/tuwunel/tuwunel.toml`과
`.runtime/tuwunel/admin_token`(0600)을 읽고, 토큰 값은 어디에도 기록하지 않습니다.

```bash
python3 scripts/admin.py create operator --admin
python3 scripts/admin.py create family_member
python3 scripts/admin.py list-users
```

`.runtime/`과 백업은 Git에 추가하지 않습니다.

## HTTPS 프록시

`deploy/tuwunel/cloudflare-ingress.example.json`대로 client API·인증 미디어·`/_matrix/versions`·
`/.well-known/matrix/client`만 노출하고 나머지 경로는 404로 떨어뜨립니다.
`/_synapse/admin`과 federation은 절대 전달하지 않습니다. 관리 API는 호스트 안에서 루프백으로만 부릅니다.

Matrix API는 모바일 앱도 접근하므로 Cloudflare Access의 브라우저 로그인으로 감싸지 않습니다.
계정 인증은 Matrix가 담당하며 공개 가입은 닫혀 있습니다(등록 토큰만). 웹에 Access를 추가하더라도
앱·로그인 호환성을 먼저 확인합니다.

Cloudflare Tunnel을 운영 서버에서 직접 실행하는 경우 토큰은 root 전용
`/etc/family-messenger/cloudflared.token`에 저장하며, `deploy/family-messenger-tunnel.service`가
systemd credential로 읽습니다. 기존 플릿 터널의 토큰이나 라우팅을 덮어쓰지 않습니다.

## 저장공간 경보

`scripts/check_storage.py`는 데이터 삭제 없이 파일시스템 여유와 저장 트리의 할당량을 검사합니다.
심볼릭 링크·다른 파일시스템·읽기 실패는 정상으로 처리하지 않습니다. 경로는 인자이므로
Tuwunel 데이터 트리와 백업 디렉터리 어디든 그대로 씁니다.

```bash
python3 scripts/check_storage.py /var/lib/tuwunel --min-free-gib 100 --max-retained-gib 150
```

초기 운영 제안값은 운영 서버 여유 100GiB 미만 또는 데이터 트리 150GiB 이상에서 경고입니다.
이는 업로드 차단이나 자동 삭제 정책이 아닙니다. Tuwunel은 메시지 DB(RocksDB)와 미디어를
같은 데이터 트리에 두므로 트리 예산에 함께 포함됩니다.
백업 목적지의 여유와 보존 세대도 별도로 점검합니다.

`deploy/family-messenger-storage.service`와 `.timer`는 설치 트리를 시간마다 점검하는 예시입니다.
경고는 JSON 출력과 service 실패 상태로 남습니다. 외부 푸시 알림은 별도 연결이 필요하며,
타이머 설치만으로 가족에게 알림이 발송되지는 않습니다. 운영 폴더와 상위 경로는 운영자 소유로
유지합니다. 측정 중 파일 생성·삭제로 실패하면 다시 점검합니다.

## 계정·암호화

관리자가 가족 계정을 발급하고 필요한 방에 초대합니다. `--admin`은 운영자에게만 사용합니다.
가족의 암호화 키/복구 키를 수집하지 않습니다. 로그인 비밀번호 재설정은 잃어버린 암호화 키의 복구와 다릅니다.
Matrix 서버의 저장소 백업에도 사용자 기기의 복호화 키가 모두 들어 있는 것은 아닙니다.
현재 `/auth`는 Synapse 호환 계정 인증을 사용합니다. Element X/OIDC(MAS), passkey/SSO 등은 후속 검증 대상입니다.

## 백업·복구 인수검사

### 상시 암호화 백업

Tuwunel 내장 온라인 백업과 restic을 짝으로 씁니다. `scripts/tuwunel_backup.py`는 홈서버의
검증 명령이 "모든 파일 존재"를 확인한 뒤 데이터베이스(온라인 백업 디렉터리)와 미디어를
두 restic 스냅샷으로 저장하고, 한쪽만 성공한 기록은 만들지 않습니다. prune·forget·메시지 삭제는 없습니다.
**백업 중 업그레이드·설정/비밀번호 변경·미디어 삭제를 하지 않습니다.** 잠금, 여유 공간 사전 검사,
성공 기록(`tuwunel-<시각>-<접미>.json`)과 명령 행 예시는 [Tuwunel 운영](TUWUNEL-OPERATIONS.md)을 따릅니다.
이전 PostgreSQL 덤프 방식(`scripts/backup.py`, `deploy/family-messenger-backup.{service,timer}`)은
`archive/synapse-stack/`에 보관됐습니다.

### 복구

복원은 홈서버 내장 기능만 사용합니다. **같은 완료 기록의 데이터베이스·미디어 스냅샷 짝**을 선택하고,
가장 최신 스냅샷 두 개를 임의로 조합하지 않습니다. 절차와 자동 되돌림이 포함된 복원 드릴
(`scripts/tuwunel_restore_drill.py`)은 월 1회 격리 환경에서 수행합니다.
복원 뒤에는 가족 기기와 봇 모두 재로그인 또는 sync 상태 초기화가 필요합니다.

운영 시작 전 복구 절차를 별도 시험 환경에서 실행해야 합니다.

1. 데이터베이스와 미디어를 같은 시점의 완료 기록으로 백업합니다. DB만 백업하면 첨부를 잃습니다.
2. 백업에는 관리 토큰·설정이 포함됩니다. 암호화하여 운영 서버와 다른 저장소에 보관합니다.
3. 격리 환경에서 복원 드릴로 복원한 뒤 계정·대화·첨부와 두 기기의 키 복구를 검증합니다.
4. 보관 디렉터리(`db.pre-restore-<시각>`)는 드릴 성공 후 운영자가 직접 정리합니다. 스크립트는 자동 삭제하지 않습니다.

## 첫 운영 전 완료 기준

- 승인한 도메인의 TLS와 외부 관리자 API 차단 실측
- 관리자가 발급한 계정만 로그인 가능, 비초대 방 접근 거부
- 두 기기에서 실제 암호화 메시지 송수신·첨부·키 백업/복구
- 네트워크 단절 후 중복 없는 재연결·동기화
- 가족 기기별 백그라운드 알림 및 모바일 인증 호환성
- 별도 환경의 백업 복원 확인

`tests/tuwunel_smoke.py`는 루프백 Tuwunel에서 방 기본 암호화와 두 계정 사이의
E2EE 암호화 왕복을 검사하는 합성 시험이며, 이 전체 인수검사를 대체하지 않습니다.
