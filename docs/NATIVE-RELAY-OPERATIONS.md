# 한데 릴레이(native-relay) 운영 — 오프호스트 스냅샷·복원 (#440 0단계)

독자 E2EE 트랙(「한데」)의 서버 측은 `native-relay` 하나다: Go 단일 프로세스 + SQLite(`native-mls-v2.db`,
`_journal_mode=DELETE`·`_txlock=immediate`, `archive/native-mls/server/store.go`) + 기기 정책 체인 디렉터리
(`policy-NNNNNN.json`) + 서빙 번들(`static/`, `hande/`). 2026-10-19까지 이 상태의 오프호스트 사본이 없었다
— 호스트를 잃으면 릴레이를 통째로 잃는 구조였다(#440, 배경은 #412 육손 12분 두절). 이 문서는 0단계
**스냅샷·복원·드릴**만 다룬다. 대기 호스트 전환(1단계)·펜싱·DNS 교체는 #440에서 별도로 확정한다.

## 무엇을 복사하고 무엇을 복사하지 않는가

| 포함 | 근거 |
|---|---|
| `data/native-mls-v2.db` — **SQLite 온라인 백업 API**로 복사(릴레이 무중단; busy_timeout 5 s와 호환) | 방·이벤트·커서·멤버·키 패키지·푸시 토큰 전부가 이 한 파일 |
| `policy/` 정책 체인 전체 | 기기 등록·폐기의 유일한 기록. 없으면 `-access-mode required` 릴레이가 기동 자체를 거부(`main.go` fail closed) |
| `static/`, `hande/` 서빙 번들 | 번들 sha256은 릴레이 바이너리와 짝이 맞아야 한다(ND-4059 주의) |
| 릴레이 유닛 drop-in 디렉터리, `relay.env`(issuer/aud/jwks) | 같은 플래그로 다시 띄우기 위한 재료. `relay.env`는 0600 유지 |
| `manifest.json` — 파일별 sha256 + 방별 `epoch`/`revision`/`last_seq` + 테이블 건수 + 정책 revision + `integrity_check` | 복원 뒤 "무엇이 돌아왔는지" 대조 근거 |

| 제외 | 근거 |
|---|---|
| APNs `.p8` 키 | 오너 결정 #440-A: 대기 호스트는 푸시 없이 운영. `.p8` 또는 `apns` 디렉터리 밑의 파일이 포함 경로에 있으면 **건너뛰지 않고 실패**한다 |
| 릴레이 바이너리 | 곽가 재현 빌드 → 서서 스테이징(`STAGE-SHA256SUMS`)이 정본. 스냅샷은 데이터만 |
| CF 터널 토큰·Access 설정 | 호스트 비밀. 전환 시 CF API로 다시 만든다(1단계) |

## 스냅샷 (`scripts/native_relay_snapshot.py`)

```bash
python3 scripts/native_relay_snapshot.py \
  --data-dir /var/lib/native-relay/data --policy-dir /var/lib/native-relay/policy \
  --static-dir /opt/native-relay/static --hande-dir /opt/native-relay/hande \
  --dropin-dir /etc/systemd/system/native-relay.service.d --env-file /etc/native-relay/relay.env \
  --dest /var/lib/native-relay-snapshots/local --state /var/lib/native-relay-snapshots/state \
  --push relay-snapshots@<대기호스트>:/var/lib/native-relay-snapshots/inbox \
  --push relay-snapshots@<오프사이트>:/var/lib/native-relay-snapshots/inbox \
  --ssh-key /etc/native-relay/snapshot-push.key --keep-hours 48 --keep-days 30
```

- 산출물: `<dest>/relay-<UTC시각>.tar.gz`(0600) + `.sha256` 사이드카. 상태 디렉터리에 `relay-<시각>.json`과
  `latest.json`(0600). `status`는 `complete` 또는 `push-failed`(로컬 사본은 남고 종료 코드 1 → systemd 실패로 드러남).
- 복사본에 `PRAGMA integrity_check`를 돌려 `ok`가 아니면 보관하지 않는다.
- 심볼릭 링크·특수 파일은 거부한다(복사본이 조용히 다른 것을 가리키는 일을 막는다).
- 잠금 파일로 동시 실행을 막는다. 삭제는 보존 규칙이 정한 **이 스크립트가 만든 이름**만 건드린다.
- 보존: 최근 48시간 전량 + 그 이전은 UTC 하루 1개 × 30일. 수신 호스트는 `--prune-only --dest <inbox>`로 같은 규칙 적용.
- 유닛: `deploy/native-relay/native-relay-snapshot.{service,timer}`(15분, 릴레이 호스트) ·
  `native-relay-snapshot-prune.{service,timer}`(수신 호스트). 경로는 `/etc/native-relay/snapshot.env`
  (`deploy/native-relay/snapshot.env.example`). 체크아웃 경로가 다른 호스트는 drop-in으로 `ExecStart`를 재지정한다.
- 수신 계정: 스냅샷만 받는 전용 계정 + `authorized_keys`에 `restrict,command="rsync --server ..."` 제한을 권장.
  키 값은 어디에도 기록하지 않는다(경로만).

**RPO = 타이머 주기(15분).** 전환 시 이 창 안의 메시지는 릴레이에서 사라진다 — 아래 c1이 그 손실을 드러낸다.

## 복원 (`scripts/native_relay_restore.py`)

```bash
# 1) 검증만 — 아무것도 쓰지 않는다
python3 scripts/native_relay_restore.py --archive /var/lib/native-relay-snapshots/inbox/relay-<시각>.tar.gz --summary-only

# 2) 실제 복원(릴레이 유닛이 inactive 여야 한다; active 면 거부)
python3 scripts/native_relay_restore.py --archive .../relay-<시각>.tar.gz \
  --target-data-dir /var/lib/native-relay/data --target-policy-dir /var/lib/native-relay/policy \
  --target-static-dir /opt/native-relay/static --target-hande-dir /opt/native-relay/hande \
  --owner native-relay --bump-seq 1000
```

- 순서: 아카이브 sha256 ↔ 사이드카 → 안전 추출(절대 경로·`..`·링크·복수 최상위 거부) → 모든 멤버 sha256 ↔ manifest
  → 유닛 active 검사 → 기존 디렉터리는 `<이름>.pre-restore-<시각>`으로 **옮겨 둠(삭제 없음)** → 복사 → 권한
  (data/policy 0700/0600, static/hande 0755/0644) → `--bump-seq` → 복원본 요약과 manifest 건수 대조(`counts_match`).
- 어느 검증이든 실패하면 대상 디렉터리를 건드리기 전에 끝난다.

### `--bump-seq` — 왜 필요한가 (오너 결정 #440-C, c1)

클라이언트는 `GET events?after=<커서>`로 읽고, **릴레이가 커서보다 앞서 있을 때만**(`first_seq > cursor+1`)
`history_gap`으로 멈춘다(iOS `RoomSyncEngine.swift` 주석 ①~③, 웹·봇 동일 토큰). 오래된 스냅샷으로 복원하면
릴레이는 **뒤로 간다**: 이미 소비된 seq 번호를 다시 발급하고, 커서가 앞서 있는 클라이언트는 그 메시지를
**조용히 건너뛴다**(멈추지도 않는다). `store.go:202`도 `last_seq`는 절대 뒤로 가면 안 된다고 못 박는다.

`--bump-seq N`은 모든 방의 `mls_rooms.last_seq`에 N을 더한다. 다음 이벤트의 seq가 어떤 클라이언트 커서보다도
커지므로, 손실 구간이 있든 없든 클라이언트는 `history_gap`으로 **명시적으로 멈추고** 운영자 절차(재참여/
커서 정리)로 복구한다. 조용한 손실을 보이는 정지로 바꾸는 것이 목적이다. `epoch`(MLS 암호 상태)과
`revision`은 건드리지 않는다. N은 스냅샷 이후 발생했을 수 있는 이벤트 수보다 넉넉히(기본 권장 1000).
`NATIVE-E2EE.md`의 "restoring an old crypto snapshot must force reconciliation ... before any send"가 요구하는
바로 그 강제다. 드릴·격리 복원에서는 0으로 두고 건수 대조만 해도 된다.

정책 체인도 같은 성격이다: 스냅샷 이후 등록된 기기는 복원본에 없어 403을 받는다 → 재등록(revision +1).
스냅샷 `policy_revision`과 현재 체인의 마지막 revision 차이가 그 범위다.

## 복원 드릴 (격리 환경 전용)

```bash
python3 scripts/native_relay_restore.py --archive .../relay-<시각>.tar.gz \
  --target-data-dir /tmp/relay-drill/data --target-policy-dir /tmp/relay-drill/policy \
  --target-static-dir /tmp/relay-drill/static --target-hande-dir /tmp/relay-drill/hande \
  --skip-unit-check --relay-binary /opt/native-relay/bin/native-mls-relay --drill-port 18999
```

- 복원본으로 릴레이를 **루프백·`-access-mode disabled`**로 띄워 `/v2/health` 200을 확인하고 바로 내린다.
  운영 데이터 디렉터리에는 절대 쓰지 않는다(`--skip-unit-check`는 임시 디렉터리에서만).
- 판정: 종료 코드 0 = 아카이브·멤버 sha256 일치 + `integrity_check` ok + 테이블 건수 manifest 일치 + health 200.
- 수용 기준(#440 0단계): 스냅샷이 15분 안에 수신 호스트 2곳에 도착하고 성공 JSON이 남으며, 드릴이 위 판정을 통과한다.
- 월 1회 예방 점검에 포함한다(Wiki 런북, DOC-3436 RB-988 형식): 타이머 active · `latest.json` `status=complete`
  신선도 · 수신 호스트 inbox 최신 시각 · 드릴 1회.

## 비밀과 공개 저장소 규칙

이 저장소는 PUBLIC이다. 실제 호스트명·계정·키 경로·터널 ID는 호스트의 `snapshot.env`와 Family Wiki에만 쓴다.
ssh 개인키·APNs 키·CF 토큰 값은 어디에도 기록하지 않는다.

관련: #440 · #412 · #426 · `DECISION-2026-10-19-AGENT-CHAT-TO-HANDE.md` · `NATIVE-E2EE.md` · `TUWUNEL-OPERATIONS.md`(같은 틀의 Matrix 쪽 백업)
