# Tuwunel 홈서버 운영 (1단계 대상)

이 문서는 [결정 D](DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md)의 1단계에서 도입하는
Tuwunel 홈서버의 배포·계정·백업·복원 절차를 다룬다. 근거는 2026-09-13 격리 평가
([증거 기록](evidence/homeserver-eval-20260913.md))이며, 수치는 그 실측에서 온 것이다.
현재 `compose.yaml`(Synapse/Element/Postgres)은 1단계 교체 전까지 운영 유지이며,
[운영 안내](OPERATIONS.md)와 이 문서는 그때까지 병행된다. 이 문서의 대상은 Tuwunel이고,
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
  data/               # tuwunel.toml의 database.path
    backups/          # 홈서버가 만드는 온라인 백업
    media/            # 업로드 미디어 (온라인 백업에 포함되지 않음)
```

## 보안 기본값

평가에서 확인한 안전 기본값 구성을 유지한다.

- `address = "127.0.0.1"`과 `port`로 루프백 전용 바인딩. 외부 노출은 터널/리버스 프록시가 담당한다.
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
- 기존 Synapse 공유 비밀 발급(`python3 scripts/admin.py owner --admin`)은 현재 구성용으로 그대로 남는다.

## 백업 (scripts/tuwunel_backup.py)

홈서버 내장 온라인 백업 + restic 쌍으로 저장한다. 온라인 백업은 미디어를 포함하지 않으므로(실측)
미디어 스냅샷은 선택이 아니라 필수다. 스크립트는 검증 명령이 "모든 파일 존재"를 확인하지 못하면
restic을 시작하지 않고, 데이터베이스 쪽 스냅샷이 성공한 뒤 미디어를 저장하며, 한쪽만 성공한
기록을 만들지 않는다. prune·forget·삭제는 어디에도 없다.

```bash
# restic 저장소·비밀번호는 환경으로 제공한다(저장소/호스트를 코드에 박지 않는다).
export RESTIC_REPOSITORY=/backup/family-messenger   # 예시
export RESTIC_PASSWORD_FILE=/etc/family-messenger/restic.pass
python3 scripts/tuwunel_backup.py
```

- 성공 기록은 `/var/lib/family-messenger-backups/tuwunel-<시각>-<접미>.json`(0600)에 남는다.
  두 스냅샷 id와 온라인 백업 id가 함께 기록되며, 복원 드릴은 이 기록을 근거로 삼는다.
- 상태 디렉터리는 소유자·권한을 검사하고, 잠금 파일로 동시 실행을 막는다.
- 백업 중 업그레이드·설정/비밀번호 변경·미디어 삭제를 하지 않는다.
- 소스 파일시스템 여유가 예약(10 GiB) 미만이면 시작하지 않는다. restic 목적지 여유는 별도 점검한다.
- 온라인 백업 명령의 무인 전달 경로(`--execute`)는 평가에서 명령 자체만 확인됐고
  실행 중인 인스턴스에 대한 무인 호출은 미실측이다. 1단계 배포에서 타이머 연결 전에 반드시 확인한다.

## 복원 드릴 (scripts/tuwunel_restore_drill.py)

복원은 홈서버 내장 기능만 사용한다(수동 `.sst` 조작 없음). 2026-09-13 실측 절차:
정지 → 데이터베이스 디렉터리 보관 이동 → `--restore-backup --maintenance --execute "server shutdown"`
(330 ms, 메시지 20/20·event_id 일치) → 미디어 복사 → 기동 → client API 확인.

```bash
python3 scripts/tuwunel_restore_drill.py \
  --stop-command 'systemctl stop tuwunel' \
  --start-command 'systemctl start tuwunel' \
  --yes
```

- 스크립트는 정지·시작 명령을 인자로 요구하며 호스트의 서비스 관리 방식을 추측하지 않는다.
- 데이터베이스를 통째로 교체하므로 `--yes` 없이는 실행되지 않는다. **반드시 격리 환경에서 먼저 수행한다.**
- 보관 디렉터리(`db.pre-restore-<시각>`)는 드릴 성공·실패와 무관하게 남으므로,
  확인 뒤 운영자가 직접 정리한다. 스크립트가 자동 삭제하지 않는다.
- 미디어는 `cp -a <보관>/media/. <새>/media/`와 같은 "기존 디렉터리 안으로" 복사가 필요하다.
  복원 실행이 빈 `media/`를 먼저 만들기 때문에(실측) 단순 `cp -a src dst`로는 건너뛰어진다.
  스크립트는 이 의미를 그대로 구현한다.
- 복원이 확인되지 않으면(출력에 기대한 `backup_id`가 없으면) 미디어 복사와 기동을 하지 않고
  현장을 보존한다. 기동 후에는 루프백으로 `/_matrix/client/versions` 응답을 확인한다.
- 특정 과거 백업 선택(`--backup-id`)은 목록에 있는 id인지 검사할 뿐, 내장 복원이 최신을
  되돌리는 기본 동작을 바꾸지는 못한다. 과거 시점 선택이 필요하면 수동 절차로 확정해야 한다.

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
