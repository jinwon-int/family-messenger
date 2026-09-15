# Tuwunel 홈서버 운영 (1단계 대상)

이 문서는 [결정 D](DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md)의 1단계에서 도입하는
Tuwunel 홈서버의 배포·계정·백업·복원 절차를 다룬다. 근거는 2026-09-13 격리 평가
([증거 기록](evidence/homeserver-eval-20260913.md))이며, 수치는 그 실측에서 온 것이다.
현재 레포에서 `compose.yaml`(Synapse/Element/Postgres)은 `archive/synapse-stack/`으로 퇴역했다(#104).
운영 호스트는 별도 1단계 배포 작업 전까지 여전히 기존 구성으로 서비스할 수 있으며, 이 문서는
그 전환의 운영 기준이다. 이 문서의 대상은 Tuwunel이고,
예시 값은 전부 `example.com` 같은 자리표시자다.

## 설치와 고정

Tuwunel은 단일 바이너리(정적 링크, 1.9.1 기준 102 MiB)로 배포한다. 릴리스에는
공식 체크섬·서명·attestation이 없으므로 다음을 저장소 밖 기록과 함께 의무화한다.

1. 내려받은 `.zst`와 `.deb` 각각의 sha256을 배포 증거에 기록한다.
2. `.deb`를 `dpkg-deb -x`로 풀어 나온 바이너리와 `.zst` 추출본의 sha256이 같은지 확인한다(교차 검증).
3. 버전을 올릴 때마다 위 절차를 반복하고, 직전 버전 기록과 함께 남긴다.

설치 레이아웃(예시):

```text
/opt/family-messenger/
  .runtime/tuwunel/
    tuwunel.toml      # 설정 (0600 권장)
    admin_token       # admin API Bearer 토큰 (0600 필수)
  data/
    db/               # tuwunel.toml의 database_path
      media/          # 업로드 미디어 (온라인 백업에 포함되지 않음)
    backups/          # tuwunel.toml의 database_backup_path — 홈서버가 만드는 온라인 백업
```

`database_backup_path`는 **반드시 `database_path` 바깥**에 둔다. 복원 드릴이 데이터베이스 디렉터리를
통째로 옮기므로 안쪽에 두면 백업까지 함께 옮겨져 "No backups found"로 실패한다(2026-09-13 실측).
`scripts/tuwunel_backup.py`와 `scripts/tuwunel_restore_drill.py`는 이 조건을 검사하고 위반 시 아무것도
정지·이동하지 않는다. 설정 파일 형식은 `deploy/tuwunel/tuwunel.toml.example`을 따르며
(`[global]`, `address` 문자열/배열, `database_path`, `database_backup_path`), 스크립트는 공용 로더
`scripts/tuwunel_config.py`로 읽는다. 옛 `[database] path` 표기는 폴백으로만 인식한다.

## 보안 기본값

평가에서 확인한 안전 기본값 구성을 유지한다.

- `address = ["127.0.0.1"]`(문자열 `"127.0.0.1"`도 허용)과 `port`로 루프백 전용 바인딩. 모든 항목이
  루프백이 아니면 스크립트가 접속을 거부한다. 외부 노출은 터널/리버스 프록시가 담당한다.
- 공개 가입 금지: `allow_registration = false` 또는 등록 토큰 운용, `allow_guest_registration = false`, `allow_federation = false`.
- `allow_encryption = true`와 방 기본 암호화 지정(private_chat 자동 megolm 실측됨).
- `max_request_size`는 100 MiB가 터널 요청 본문 한도 경계다. 터널 경유 대형 업로드는 미검증이므로 영상 등은 별도 확인 전에 제한한다.
- IP 신뢰 설정(`ip_source` 계열)은 프록시 문서의 권고를 따른다. 미설정 시 헤더 스캔 동작은 위조 가능으로 본다.
- `well_known` 미설정 시 404가 관측됐다. 엣지에서 제공하거나 설정에 명시한다.
- `/_synapse/admin` 경로는 절대 외부에 전달하지 않는다. `scripts/admin.py`는 루프백 기본값이 아니면 접속을 거부한다.

## 계정 관리 (scripts/admin.py)

Tuwunel은 Synapse 호환 admin API를 제공하므로 계정·방 관리가 JSON으로 끝난다.
토큰은 `.runtime/tuwunel/admin_token`(0600, 일반 파일)에서 읽고 어디에도 기록하지 않는다.

```bash
python3 scripts/admin.py create family_member --display-name '가족'
python3 scripts/admin.py create operator --admin
python3 scripts/admin.py list-users
python3 scripts/admin.py list-rooms
python3 scripts/admin.py deactivate '@old:example.com' --yes
```

- 상류 버그(실측): `PUT /_synapse/admin/v2/users`에 `admin: false`를 넣으면 사용자는
  생성되지만 응답이 500(`M_UNKNOWN`)으로 온다. `admin.py`는 `admin` 필드를
  `true`일 때만 보내 회피한다. 업스트림 보고 전까지 이 동작을 기대값으로 문서화한다.
- 첫 가입자가 자동으로 관리자가 된다. 서버 내부 계정은 `@conduit:<서버>` 이름이므로
  가족 화면에서 표시명을 별도로 처리해야 한다.
- 비활성화는 되돌릴 수 없는 절차다. `--yes` 없이는 실행되지 않는다.
- 기존 Synapse 공유 비밀 발급(`python3 scripts/admin.py owner --admin`)은 보관된 Synapse 구성
  (`archive/synapse-stack/`) 전용 레거시 경로로 스크립트에 남는다. Tuwunel에서는 `create` 서브커맨드를 쓴다.

## 백업 (scripts/tuwunel_backup.py)

홈서버 내장 온라인 백업 + restic 쌍으로 저장한다. 온라인 백업은 미디어를 포함하지 않으므로(실측)
미디어 스냅샷은 선택이 아니라 필수다. 스크립트는 검증 명령이 "모든 파일 존재"를 확인하지 못하면
restic을 시작하지 않고, 데이터베이스 쪽 스냅샷이 성공한 뒤 미디어를 저장하며, 한쪽만 성공한
기록을 만들지 않는다. prune·forget·삭제는 어디에도 없다.

```bash
# restic 저장소·비밀번호는 환경으로 제공한다(저장소/호스트를 코드에 박지 않는다).
export RESTIC_REPOSITORY=/backup/family-messenger   # 예시
export RESTIC_PASSWORD_FILE=/etc/family-messenger/restic.pass
python3 scripts/tuwunel_backup.py \
  --config /etc/tuwunel/tuwunel.toml \
  --admin-token-file /etc/family-messenger/admin_token \
  --state /var/lib/family-messenger-backups
```

- **관리 명령은 실행 중인 서버에 관리방으로 보낸다.** 서버가 켜져 있을 때 두 번째
  `tuwunel --execute` 프로세스는 RocksDB `LOCK`에 막혀 실패하고(실측), 서버가 꺼져 있으면 오히려
  서버를 하나 더 띄운다. 그래서 `scripts/tuwunel_admin_room.py`가 admin 토큰으로
  `#admins:<server_name>`을 방 디렉터리에서 찾아 `!admin server backup-database` →
  `list-backups` → `verify-backup`을 `m.room.message`로 보내고, 서버 계정(`@conduit:<server_name>`)의
  답을 `/messages`에서 제한 시간 안에 읽는다. 답에 기대 문구(`Done`, 검증은 `all files present`)가
  없거나 제한 시간 안에 오지 않으면 실패로 끝난다. `--execute`는 아래 오프라인 복원 단계에만 쓴다.
- restic `database` 스냅샷은 `database_backup_path` 디렉터리 + 설정 파일, `media` 스냅샷은
  `<database_path>/media`다. 두 스냅샷은 `production`, `<쌍 이름>`, `database|media` 태그를 가진다.
- 성공 기록은 `--state`(기본 `/var/lib/family-messenger-backups`)의 `tuwunel-<시각>-<접미>.json`(0600)에
  남는다. 두 스냅샷 id와 온라인 백업 id가 함께 기록되며, 복원 드릴은 이 기록을 근거로 삼는다.
- 상태 디렉터리는 소유자·권한을 검사하고, 잠금 파일로 동시 실행을 막는다.
- 백업 중 업그레이드·설정/비밀번호 변경·미디어 삭제를 하지 않는다.
- `database_backup_path` 파일시스템 여유가 예약(10 GiB) 미만이면 시작하지 않는다. restic 목적지 여유는 별도 점검한다.
- 실패한 실행은 그 시점까지 만든 것을 **의도적으로 남긴다**: 미디어 스냅샷이 실패하면 온라인 백업
  하나와 `database` 태그 restic 스냅샷 하나가 짝 없이 남고 기록 json은 쓰지 않는다. 짝 없는 스냅샷은
  기록 json이 없다는 점으로 구별하며, 정리는 운영자가 직접 한다(스크립트는 삭제하지 않는다).
  온라인 백업 보관 수는 홈서버의 `database_backups_to_keep`이 정한다.

## 복원 드릴 (scripts/tuwunel_restore_drill.py)

복원은 홈서버 내장 기능만 사용한다(수동 `.sst` 조작 없음). 2026-09-13 실측 절차:
실행 중인 서버에 관리방으로 `list-backups` → 정지 → 데이터베이스 디렉터리 보관 이동 →
`--restore-backup --maintenance --execute "server shutdown"`(백업은 `database_backup_path`에서 읽음;
1271 ms, 백업 시점 메시지 56/56·event_id 집합 일치) → 미디어 복사 → 기동 → client API 확인.

```bash
python3 scripts/tuwunel_restore_drill.py \
  --config /etc/tuwunel/tuwunel.toml \
  --admin-token-file /etc/family-messenger/admin_token \
  --stop-command 'systemctl stop tuwunel' \
  --start-command 'systemctl start tuwunel' \
  --yes
```

- 스크립트는 정지·시작 명령을 인자로 요구하며 호스트의 서비스 관리 방식을 추측하지 않는다.
- 데이터베이스를 통째로 교체하므로 `--yes` 없이는 실행되지 않는다. **반드시 격리 환경에서 먼저 수행한다.**
- 정지 전에 `database_backup_path`가 설정돼 있고 `database_path` 바깥인지, 디렉터리가 실재하는지
  확인한다. 하나라도 어긋나면 아무것도 정지·이동하지 않고 끝난다.
- 보관 디렉터리(`db.pre-restore-<시각>`)는 드릴 성공 시 남으므로, 확인 뒤 운영자가 직접 정리한다.
  스크립트가 자동 삭제하지 않는다.
- **자동 되돌림**: 복원 단계가 실패하면(프로세스 오류, 또는 출력이 기대한 `backup_id`를 확인하지 못함)
  실패한 시도는 `db.failed-restore-<시각>`으로 옮겨 보존하고, 보관 디렉터리를 원래 자리로 되돌린 뒤
  시작 명령을 실행한다. 각 단계는 stderr에 `restore drill:` 접두로 기록되고 종료 코드는 1이다.
  되돌림 자체나 재기동이 실패하면 그 사실을 기록하고 끝나므로 운영자가 즉시 개입해야 한다.
  서비스를 조용히 내려둔 채 끝나는 경로는 없다.
- **복원 뒤 클라이언트 주의**: 복원 전 sync 토큰을 쥔 채 살아 있던 클라이언트는 이후 메시지를
  받지 못할 수 있다(실측: 서버 `/messages`에는 있으나 20 s 안에 도착하지 않음). 복원 후에는 가족
  기기와 봇 모두 재로그인 또는 sync 상태 초기화를 안내하고, 봇은 상태 디렉터리의 sync 토큰을
  지운 뒤 재시작한다.
- 미디어는 `cp -a <보관>/media/. <새>/media/`와 같은 "기존 디렉터리 안으로" 복사가 필요하다.
  복원 실행이 빈 `media/`를 먼저 만들기 때문에(실측) 단순 `cp -a src dst`로는 건너뛰어진다.
  스크립트는 이 의미를 그대로 구현한다.
- 복원이 확인되지 않으면(출력에 기대한 `backup_id`가 없으면) 미디어 복사와 기동을 하지 않고
  현장을 보존한다. 기동 후에는 루프백으로 `/_matrix/client/versions` 응답을 확인한다.
- 특정 과거 백업 선택(`--backup-id`)은 목록에 있는 id인지 검사할 뿐, 내장 복원이 최신을
  되돌리는 기본 동작을 바꾸지는 못한다. 과거 시점 선택이 필요하면 수동 절차로 확정해야 한다.
  출력이 다른 id를 확인하면 위의 자동 되돌림이 동작한다.

## 상시 운영 자동화 (systemd 타이머)

운영 평면의 세 타이머는 배포 패키지 유닛(`deploy/tuwunel/`)을 호스트에 설치해 운영한다. 이름과
실행 창은 Synapse 시절 일정을 이어받는다. 2026-09-15 퇴역 뒤 구 `family-messenger-backup.timer`는
퇴역한 compose 스택 스크립트를 가리켜 매일 04:30 실패했고(2026-09-16 실측), 같은 이름의 아래
유닛으로 대체하며 해소한다.

| 타이머 | 주기 | 하는 일 |
|---|---|---|
| `family-messenger-backup.timer` | 매일 04:30 Asia/Seoul | `scripts/tuwunel_backup.py` — 관리방 온라인 백업 + restic 쌍. restic 저장소·비밀번호는 환경 파일(예시 `/etc/family-messenger/backup.env`), admin 토큰 경로가 다른 호스트는 드롭인으로 ExecStart를 재지정 |
| `family-messenger-storage.timer` | 매시 | `scripts/check_storage.py`를 Tuwunel 데이터 트리(`/var/lib/tuwunel`)에 실행 — 여유·보존 예산 경계 검사 |
| `family-messenger-health.timer` | 매시 | `scripts/health_check.py` — client API 200·필수 유닛 활성·마지막 완료 백업 신선도(기본 26시간). `--alert-admin`이면 healthy↔unhealthy 전환 시에만 관리방 통지(0600 상태 파일로 중복 억제, 첫 실행은 기록만) |

```bash
install -m 0644 deploy/tuwunel/family-messenger-backup.service deploy/tuwunel/family-messenger-backup.timer \
  deploy/tuwunel/family-messenger-health.service deploy/tuwunel/family-messenger-health.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now family-messenger-backup.timer family-messenger-health.timer
systemctl start family-messenger-backup.service   # 첫 수동 실행으로 기록을 확인한다
```

- 유닛이 환경 파일을 요구하므로(`EnvironmentFile=`) 설치 전에 restic 환경을 준비한다. 파일이
  없으면 유닛이 시작하지 않는다(의도된 fail-loud).
- 봇 노드는 `deploy/family-matrix-health.service.example`+`.timer.example`로
  family-matrix 유닛 활성·홈서버 도달·봇 sync 신선도(`meta.health`)를 점검한다. 관리방 통지는
  봉인 토큰이 있는 홈서버 노드 유닛이 담당한다. 관리방 밖 외부 경보는 여전히 후속 작업이다.
- 헬스 점검은 읽기 전용이며 백업·스토리지 타이머와 충돌하지 않는다(백업은 자체 잠금 파일로
  동시 실행을 막는다). 실패한 백업 실행은 기록 json을 쓰지 않으므로, 신선도 검사는
  마지막 **완료** 쌍을 기준으로 한다.

## 업그레이드 주의

- 1.8.x → 1.9 첫 기동 시 DB 마이그레이션이 리스너 오픈 전에 실행된다. 이 구간 강제 종료는
  손상 위험이 있으므로, 업그레이드 전 `tuwunel_backup.py`로 백업+검증을 먼저 수행한다.
- 업그레이드 후에는 복원 드릴을 격리 환경에서 한 번 더 수행해 복구 가능성을 확인한다.

## 알려진 열린 위험 (1단계에서 처리)

- 릴리스 체크섬·서명 미공개 → 위 설치 절차로 방어, 배포 증거에 기록.
- `PUT /_synapse/admin/v2/users` 500 → `admin` 필드 생략으로 회피, 업스트림 이슈 확인 필요.
- 온라인 백업의 미디어 제외 → 본 문서의 restic 쌍으로 상시 방어.
- 터널 경유 대형 업로드 미검증 → 영상 허용 전 확인.
- 유휴 스레드 수(실측 602)는 저사양 노드에서 재측정 필요.
- Tuwunel↔continuwuity DB 마이그레이션 가능성은 미실측. 분기마다 재확인하고, 최악의 경우
  프로토콜이 같으므로 Synapse 복귀 시 화면·에이전트 코드는 무손실이다.

## 비밀과 공개 저장소 규칙

실제 호스트명·도메인·계정·토큰·토큰 파일 경로를 코드·문서·커밋·로그에 넣지 않는다.
문서 예시는 `example.com`과 자리표시자로 쓴다. `admin_token`과 restic 비밀번호 파일은
0600 일반 파일로 두고, Git·백업 대상 목록·오류 메시지 어디에도 내용을 출력하지 않는다.
스크립트들의 오류 출력은 오류 유형과 정적 메시지로 한정한다.
