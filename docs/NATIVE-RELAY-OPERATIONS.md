# 한데 릴레이(native-relay) 운영 — 오프호스트 스냅샷·복원·전환 (#440 0·1단계)

독자 E2EE 트랙(「한데」)의 서버 측은 `native-relay` 하나다: Go 단일 프로세스 + SQLite(`native-mls-v2.db`,
`_journal_mode=DELETE`·`_txlock=immediate`, `archive/native-mls/server/store.go`) + 기기 정책 체인 디렉터리
(`policy-NNNNNN.json`) + 서빙 번들(`static/`, `hande/`). 2026-10-19까지 이 상태의 오프호스트 사본이 없었다
— 호스트를 잃으면 릴레이를 통째로 잃는 구조였다(#440, 배경은 #412 육손 12분 두절). 0단계는
**스냅샷·복원·드릴**, 1단계는 **펜스·대기 호스트·전환**(아래 §전환)이다.

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
- 유닛: `deploy/native-relay/native-relay-snapshot.{service,timer}`(5분, 릴레이 호스트) ·
  `native-relay-snapshot-prune.{service,timer}`(수신 호스트). 경로는 `/etc/native-relay/snapshot.env`
  (`deploy/native-relay/snapshot.env.example`). 체크아웃 경로가 다른 호스트는 drop-in으로 `ExecStart`를 재지정한다.
- 수신 계정: 스냅샷만 받는 전용 계정 + `authorized_keys`에 `restrict,command="rsync --server ..."` 제한을 권장.
  키 값은 어디에도 기록하지 않는다(경로만).

**RPO = 타이머 주기(5분, 오너 결정 D1; 0단계는 15분).** 전환 시 이 창 안의 메시지는 릴레이에서 사라진다 — 아래 c1이 그 손실을 드러낸다.

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

**실제 결과는 "전 기기 동시 정지"다(1단계 설계 §0-2에서 정정).** 클라이언트의 `history_gap` 안내는 "'다시 참여 준비' →
운영자나 다른 가족 기기에서 다시 초대"인데(iOS `Strings+Halt.swift`, 한데 웹 `strings.js`), 모든 방의 `last_seq`를
올리면 모든 기기가 멈추고 멈춘 기기는 보낼 수 없어 **서로 초대할 수 없다**. 따라서 전환 뒤 표준 복구는 **운영자
relay-app이 로비 키패키지(#380 — 스냅샷에 `mls_lobby_keypackages`로 보존)로 방을 새로 열고 전원을 초대**하는 것이다
(오너 결정 D3). 봉인 로컬 이력(#370 B안)은 각 기기에 남는다. 손실 창에 commit(epoch 전진)이 있었다면 seq와 무관하게
MLS 상태가 갈라지므로(클라이언트 epoch n+1, 릴레이 epoch n → 409 → 재암호화 불가) 어차피 재참여가 필요하다 —
c1은 그 경우도 조용한 실패가 아니라 정지로 만든다.

## 펜스 — 한 시점 작성자 하나 (`scripts/native_relay_fence.py`, 1단계)

릴레이는 SQLite 단일 작성자이고 방별 `epoch`/`seq`·정책 `revision`이 단조 증가해야 한다. 두 호스트가 동시에 쓰기를
받으면(예: 같은 CF 터널 토큰의 복제본 — CF가 분산시킨다) MLS 상태가 갈라져 되돌릴 수 없다. 그래서 **공개 DNS TXT
`_native-relay-active.<도메인>`의 내용 = 활성 호스트명**을 펜스로 쓴다.

- 양쪽 `native-relay.service`에 drop-in `30-fence.conf`: `ExecStartPre=native_relay_fence.py --expect <자기 이름> --record <TXT>`.
  DoH(기본 `cloudflare-dns.com`)로 읽어 로컬 리졸버 캐시를 우회한다. 다른 이름이거나(exit 1) 못 읽으면(exit 2) **기동 거부**
  (fail-closed, `Restart=on-failure`/30 s). DNS 장애 시 릴레이를 못 올리는 것은 의도된 선택이며 워치독(#426)으로 드러난다.
- **정지 측** `native-relay-fence-watch.timer`(1분): 같은 스크립트에 `--stop-unit native-relay`. TXT가 **다른 호스트를 적극적으로
  가리킬 때만**(exit 1), 그것도 **연속 3회**(`--stop-after`, 리졸버 TTL 60 s를 넘기는 값) 확인된 뒤에 이 호스트의 릴레이를 stop한다
  (전환 직후 공개 리졸버가 옛 값을 한 번 돌려줘도 새 활성 호스트를 멈추지 않는다; 연속 횟수는 `/var/lib/native-relay/fence-watch.json`) — 전환 뒤 옛 호스트가 재부팅해 살아나거나 TXT가 바뀐 뒤에도 돌고 있던
  릴레이가 지는 쪽. 못 읽는 경우(exit 2)는 멈추지 않는다(DoH 장애가 활성 호스트를 내리면 안 된다). **시작 측 drop-in만으로는
  펜스가 완성되지 않는다**(이미 돌고 있는 프로세스는 ExecStartPre를 다시 거치지 않는다).
- 빈 이름·빈 TXT는 거부한다(`FENCE_SELF` 미설정이 빈 레코드와 "일치"하는 일을 막는다). TXT 레코드는 **TTL 60으로 미리 만든다** —
  대시보드 기본(Auto=300 s)이면 공개 리졸버 PoP가 옛 값을 최대 5분 들고 있어 전환이 그만큼 늦어진다.
- 스냅샷 유닛도 같은 게이트(`--fence <자기 이름> --fence-record <TXT>`): 대기 호스트가 오래된 사본을 밀어내지 않는다.
  펜스에 막히면 아무것도 쓰지 않고 exit 0(실패 아님, stderr에 사유).
- 전환 스크립트는 복원 **뒤**, 릴레이 start **앞**에 TXT를 바꾸고 공개 리졸버가 새 값을 돌려줄 때까지 기다린다.

## 전환 (`scripts/native_relay_cutover.py`, 1단계 — 반자동)

대기 호스트에서 실행한다(failback은 원래 호스트에서 `--to <원래 이름>`으로 같은 스크립트). 인자는 `cutover.args.example`
(한 줄에 하나, `@파일`로 읽는다 — 셸이 다시 파싱하지 않으므로 공백이 든 명령도 그대로).

```bash
python3 scripts/native_relay_cutover.py @/etc/native-relay/cutover.args                   # 1차: 판정 + 계획 + 확인 토큰 (변경 없음, exit 11)
python3 scripts/native_relay_cutover.py @/etc/native-relay/cutover.args --confirm <토큰>  # 2차: 실행
```

| 단계 | 내용 | 멈추는 조건 |
|---|---|---|
| probe | peer `/v2/health`(tailnet) **그리고** 엣지 `/v2/health`(CF Access 서비스 토큰, **리다이렉트 불인정** — Access 로그인 페이지는 200이 아니다) 각 3회×60 s. `--edge-health` 없이는 판정 자체를 거부 | 둘 다 실패(`relay-down`)일 때만 진행. `edge-only`·`peer-unreachable`·`healthy`·`edge-unknown`은 exit 10, 무변경 |
| plan | inbox 최신 아카이브(사이드카 있는 것만)·manifest 요약·**확인 토큰** = sha256(호스트·아카이브·sha·호스트명·터널·펜스 레코드·bump)[:16] | `--confirm` 불일치 → exit 11, 무변경 |
| peer_snapshot | (선택) **계획 실행(토큰 없는 1차)에서만** 살아 있는 peer에 마지막 스냅샷 1회 → 그 결과가 계획·토큰에 들어간다. 확인 실행은 새 스냅샷을 찍지 않는다(토큰이 가리키는 아카이브 = 운영자가 본 아카이브) | — |
| peer_stop | (선택) peer 릴레이 정지. **실패는 치명** — 못 멈춘 peer는 아직 서빙 중일 수 있다. peer 호스트가 죽은 게 확실할 때만 `--peer-unreachable-ok` | exit≠0 |
| restore | `native_relay_restore.py --bump-seq N --owner native-relay`(유닛 active면 거부) | 건수 불일치 |
| fence | TXT → 자기 이름, DoH로 **연속 3회** 확인될 때까지 대기(≤300 s, 리졸버 TTL 창) | 미확인 |
| reprobe | peer·엣지 1회 재확인 — 복원하는 사이 peer가 살아났으면 **여기서 멈춘다**(두 번째 작성자 방지) | 어느 쪽이든 200 |
| start | `systemctl start native-relay` + 로컬 health 200(≤120 s — 유닛의 ExecStartPre가 옛 값을 한 번 읽어 실패해도 `Restart=on-failure` 30 s 재시도를 기다린다) | 미기동 — **DNS는 아직 옛 호스트** |
| dns | 호스트명별 CNAME → 자기 터널(`proxied`) | API 실패 |
| edge | 엣지 프로브 200(≤180 s) | — |
| client_hook | 봇·브리지 재지정 명령(반복 가능) | 실패는 기록 + exit 3(`complete-with-hook-failures`); 전환 자체는 끝난 상태 |

- 실패한 단계에서 멈추고 **되돌리지 않는다**. 기록 JSON(`state/cutover-<시각>.json`)에 어디까지 됐는지 남으므로
  운영자가 이어서 처리한다(예: fence는 바뀌었는데 start 실패 → 원인 수정 후 `systemctl start`, 그다음 dns부터 수동).
- 봇은 릴레이 주소를 `/etc/native-relay/relay.env`(`NATIVE_RELAY_URL`, 비밀 없음) 한 곳에서 읽고(공명 `native-relay-bot`
  유닛·drop-in의 `ExecStart=… ${NATIVE_RELAY_URL} …`, 1단계 ⑤), 재지정 훅은 `deploy/native-relay/native-relay-repoint`
  (`ssh gongmyoung sudo /usr/local/sbin/native-relay-repoint <새 릴레이 http URL>`)가 맡는다(오너 결정 D4). 한데 브리지
  (`ccc-hande-bridge`)는 릴레이 주소를 갖지 않고 봇과 Unix 소켓으로만 통신하므로 재지정 대상이 아니다. JWT 갱신
  (`jwt-refresh.sh`)은 공개 호스트명(`relay.<도메인>`)을 쓰므로 dns 단계를 따라간다.
- `--dry-run`은 판정·계획까지만, `--probe-only`는 판정만(워치독·cron에서 쓴다).
- 기록·stdout에는 토큰 값이 없다. 훅 명령과 stderr는 `Authorization`/`Bearer`/`token=`/`key=`/`secret=`/`password=`/`--token X`/
  URL userinfo 패턴을 **최선 노력으로** 가린 뒤 기록한다 — 완전하지 않으므로 훅에 비밀값을 인자로 넣지 않는 것이 원칙이다(경로·호스트명만).
- **남는 split-brain 창**: 옛 호스트가 재부팅해 자기 ExecStartPre가 옛 TXT 값(리졸버 캐시)을 읽으면 기동할 수 있고, 다음 정지 측
  확인(연속 3분)에서 진다 — 최대 약 TTL + 3분. TXT를 TTL 60으로 미리 만들어 두는 이유다. 전환 스크립트의 재프로브는 1회 샘플이라
  `activating` 중인 peer를 못 볼 수 있다; 정지 측 타이머가 그 창을 닫는다.
- 스냅샷 유닛의 `state/skipped-latest.json`은 다음 성공 스냅샷이 지운다 — 워치독은 이 파일의 존재만으로 "펜스에 막힘"을 판정해도 된다.

### 전환 뒤 가족·봇 복구 (오너 결정 D3)
1. 전 기기가 `history_gap` 정지 — 안내문대로 "다시 참여 준비".
2. 운영자 relay-app(`owner-pc`)에서 새 방 개설 → 로비 키패키지로 가족 기기·봇 전원 초대.
3. 봇(`bot-gongmyoung`)은 재지정 훅으로 새 릴레이를 보고 있으므로 초대만 받으면 된다.
4. 이전 방은 "이력 보관"으로 둔다(릴레이의 `-reset-room`은 쓰지 않는다 — 영구 삭제).

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
- 수용 기준(#440 0단계): 스냅샷이 주기 안에 수신 호스트 2곳에 도착하고 성공 JSON이 남으며, 드릴이 위 판정을 통과한다.
- 월 1회 예방 점검에 포함한다(Wiki 런북, DOC-3436 RB-988 형식): 타이머 active · `latest.json` `status=complete`
  신선도 · 수신 호스트 inbox 최신 시각 · 드릴 1회.

## 기기 셀프서비스 운영 (#574)

2026-10-29부터 **같은 사람의 기기가 그 사람의 새 기기를 승인**하고(E2), 「내 기기를 등록해 주는 기기」 = **registrar** 역할을
사람이 직접 옮긴다(E5). 릴레이 라우트 `POST /v2/devices/candidates`·`GET /v2/devices/candidates`·`POST /v2/devices/approvals`·
`POST /v2/devices/roles`(`archive/native-mls/server/devices.go`)와 `GET /v2/me`의 `devices`·`policy_revision`이 그 경로다. 검증
코드는 운영자 CLI와 같은 `internal/devicepolicy.Apply*`이고 계약 전문은 `archive/native-mls/server/DEVICES-V4.md` 「등록 기기」·
「셀프서비스 라우트」. 라우트는 `-access-mode required` **그리고** `-device-state`가 있을 때만 뜬다(운영 릴레이는 둘 다 있다).
**운영자에게 남는 것**: E1(사람의 첫 기기 — 대역외 지문 의식 + `-enroll-first`), E3/E4(`-revoke`·`-revoke-all`), registrar 전멸
복구(아래 c). 오너가 다른 사람의 첫 기기를 승인하는 D3는 2단계(미구현).

### a. 배포 순서 — 바이너리 먼저, `roles` 레코드는 그다음

1. 릴레이 바이너리(#578 이후) + 한데 웹 번들(#580 이후, `sign_roles`가 든 `durable-worker.js`·wasm 번들 — 바이너리와 짝,
   ND-4059 규칙) + 운영자 `native-devices`(같은 모듈 빌드)를 **먼저** 올린다. 라우트는 뜨지만 체인은 아직 그대로다.
2. 그 뒤에야 체인에 `roles` 키가 생긴다 — 배포 후 첫 E1(`ApplyEnrollFirst`가 첫 기기에 `roles:["registrar"]`를 쓴다), 첫 E5, 또는
   운영자 `-set-roles`. **`roles`가 한 번이라도 기록된 체인은 #578 이전 바이너리가 읽지 못한다**: v4 디코더가 엄격(K6, 모르는 키 거부)이라
   체인 재생이 실패하고 `-access-mode required` 릴레이는 **기동을 거부**한다(fail-closed; 운영 중이던 옛 프로세스는 다음 쓰기부터 500
`device_policy_unavailable`). 역순 배포 = 릴레이 다운.
3. `roles` 없는 기존 레코드의 바이트·`policy_sha256`·체인 링크는 바뀌지 않는다(`omitempty`) — 배포 자체는 체인을 건드리지 않는다.

### b. 배포 뒤 첫 할 일 — 사람마다 registrar 지정

- #574 이전 체인의 actor는 전부 **registrar가 없다**. 그동안은 종전 규칙(**그 사람의 활성 기기 아무나** E2 승인)이 그대로 산다 —
  막히는 것은 없고, 좁히는 것이 아직 안 된 상태다.
- 각 사람이 한데 웹 ⚙ 「내 기기」 시트(`archive/native-mls/web/hande/README.md` 「새 기기 셀프서비스」)에서 자기 기기 하나에
  「등록 기기로 지정」을 누른다(활성 기기 아무 것이나 E5 한 번으로 부트스트랩, 자기 자신 지정 허용). iOS 앱의 같은 화면은 후속이다 —
  그때까지 폰만 쓰는 사람은 PC 한데 웹으로 하거나 운영자 `-set-roles`(c의 명령, 대역외 의식)로 대신한다.
- 지정된 뒤에는 **그 사람의 E2는 registrar 서명만** 받는다. 기기를 바꾸기 전에 새 폰에 먼저 역할을 주고(「등록 기기로 지정」) 옛 폰을
  해제한다 — 마지막 registrar는 스스로 해제할 수 없다(먼저 다른 기기에 부여).
- 확인: `runuser -u native-relay -- native-devices -device-state /var/lib/native-relay/policy -inspect`의 `roles`(서명 키는 출력되지 않는다).

### c. 운영자 복구 — registrar를 전부 잃었을 때

registrar 기기가 전부 폐기(E3/E4)·분실되면 그 actor는 registrar-less로 돌아가 종전 규칙이 되살아난다(남은 활성 기기가 있으면 그 기기가
E5로 다시 부트스트랩할 수 있다). 남은 활성 기기가 있는데 사람이 못 하거나, 운영자가 특정 기기에 역할을 고정하고 싶을 때:

```bash
# 1) 대역외 의식: 대상 기기의 「내 기기」 시트 지문 ↔ -inspect 의 fingerprint 를 독립 채널(통화·대면)로 비교
runuser -u native-relay -- native-devices -device-state /var/lib/native-relay/policy -inspect
# 2) 현재 revision N 으로 CAS — 증거 없는 운영자 선언(approved_by 미기록), 릴레이 정지 불필요(체인 flock·CAS, 요청마다 재읽기)
runuser -u native-relay -- native-devices -device-state /var/lib/native-relay/policy \
  -set-roles <device_id> -roles registrar -expected-revision N
```

대상은 **활성** 기기여야 한다(tombstone에는 역할을 줄 수 없다 — `revoked` 오류). 활성 기기가 하나도 없으면 E1부터다(`-enroll-first`,
첫 기기가 곧 registrar). 체인은 **최대 64 revision**(컴팩션 미구현)이라 셀프서비스로 revision이 전보다 빨리 는다 — `-inspect`의
`revision`을 월 점검에 넣는다.

### d. 라우트 오류 — 사람이 가져오는 문구 ↔ 원인

| 응답 | 뜻 | 조치 |
|---|---|---|
| 403 `first_device_out_of_band` | 호출자(JWT subject)에게 활성 기기가 없다 — **첫 기기**는 셀프서비스 대상이 아님 | 등록 화면의 운영자 JSON → `-enroll-first`(대역외 지문 의식). D3 전까지 정상 |
| 409 `device_exists` | 그 `device_id`가 체인에 이미 있다(활성이든 tombstone이든 — id 재사용 금지) | 기기에서 「이 기기 지우기」 → 새 ID로 다시(웹은 자동으로 id-taken 모드) |
| 409 `stale_revision` | 증거의 `base_revision` ≠ 현재 revision(`revision` 필드가 현재값) — 그 사이 다른 등록/역할 변경 | 클라이언트가 한 번 자동 재서명한다. 반복되면 동시에 누가 체인을 바꾸는지(`-inspect`·릴레이 로그) 확인 |
| 403 `approval_rejected` + `detail` | 서명·서명자 규칙 위반. `detail`: `is not a registrar` = 승인 기기가 registrar 아님(b에서 지정된 뒤) · `would be left without a registrar` = 마지막 registrar 해제 시도 · `no active … device signature verifies` = 서명이 그 actor의 어느 활성 키와도 안 맞음(다른 사람 기기·폐기된 기기·변조) · `fingerprint … does not match` = 승인자가 비교한 지문과 후보 키 불일치 · `approved_by … does not match` = 증거의 승인자 표기가 서명 키와 불일치 | registrar 기기에서 다시 승인 / 먼저 다른 기기에 역할 부여 / 후보 재게시 후 지문 재비교. 변조 의심이면 릴레이 로그와 함께 보고 |
| 403 `subject_mismatch` | 증거·후보의 `subject`가 호출자 JWT와 다르다 | 다른 사람의 로그인 세션으로 올린 것 — 본인 세션에서 다시 |
| 403 `device_subject_mismatch` | 승인 기기 또는 대상 기기가 호출자 subject 소유가 아니다(또는 폐기됨) | 자기 기기로만 승인·역할 변경 가능. 폐기된 기기면 새 기기 등록 |
| 400 `bad_candidate` (`detail`) | 키·지문·역할 목록(`roles` 전체 목록 필수, 알 수 없는 역할)·중복 id 형태 오류 | 클라이언트 버그 가능성 — 번들 sha 확인(ND-4059) |
| 404 (라우트 없음) | `-access-mode disabled` 또는 `-device-state` 없는 릴레이, 또는 #578 이전 바이너리 | 운영 릴레이에서 나오면 배포 상태(a) 확인. 웹은 운영자 모드로 조용히 폴백한다 |
| 500 `device_policy_unavailable` | 체인을 읽지 못함(`pending-*` 잔재·링크 깨짐·권한) | 릴레이 전체가 쓰기 불가 상태다 — `DEVICES-V4.md` 「fail-closed와 CAS」, 스냅샷에서 복원 검토 |
| 후보가 목록에 안 보임 | 후보 TTL **10분**(5분 전에 자동 재게시) 또는 승인 기기가 승인 자격이 없음(registrar 아님) | 새 기기 화면을 열어 두고 registrar 기기에서 본다 |

### e. 롤백 주의 — `roles`가 생긴 뒤에는 체인 스냅샷이 필요하다

바이너리만 #578 이전으로 되돌리면 (a)-2의 이유로 릴레이가 뜨지 않는다. 롤백하려면 **`roles`가 처음 기록되기 전의 `policy/` 스냅샷**
(`native_relay_snapshot.py` 아카이브)이 함께 돌아가야 한다. `native_relay_restore.py`는 `--target-data-dir`과 `--target-policy-dir`을
**함께** 요구하므로 스크립트로 하면 사실상 §복원 전체(DB도 그 시점으로 — `--bump-seq`와 「전 기기 동시 정지」가 따라온다)이고, `policy/`만
되돌리는 것은 스크립트 밖의 수동 절차다(아카이브에서 `policy/` 추출 → 0700/0600·소유자 `native-relay` → 기존 디렉터리는 지우지 말고
`.pre-restore-<시각>`으로 옮겨 둠). 어느 쪽이든 그 뒤 등록된 기기는 403을 받아 재등록 대상이다(스냅샷 `policy_revision` ↔ 현재 revision
차이가 그 범위). 체인 레코드를 손으로 지우거나 고치는 것은 금지다(링크 sha256이 깨져 fail-closed). 따라서 **배포 직전 스냅샷 1회**를 반드시
남기고, 롤백 결정은 `roles` 첫 기록 전에 내리는 것이 싸다.

### f. 후보 우편함 — `device_candidates`

| 열 | 내용 |
|---|---|
| `device` (PK) · `subject` · `actor` | 새 기기 id, 올린 사람의 JWT subject, actor |
| `signing_key` · `fingerprint` | **공개** 서명 키 hex와 그 sha256 — 비밀 없음 |
| `created_at` · `expires_at` | TTL **10분**(`candidateTTL`). 만료 행은 다음 게시 때 지워지고, 승인되면 즉시 삭제 |

`native-mls-v2.db` 안의 테이블이라 스냅샷에 같이 들어가며(복원해도 만료돼 있을 뿐 해롭지 않다), 같은 id 재게시는 갱신, 목록은 subject당
최대 16건. 체인의 일부가 아니다 — 지워도 정책은 바뀌지 않는다.

## 비밀과 공개 저장소 규칙

이 저장소는 PUBLIC이다. 실제 호스트명·계정·키 경로·터널 ID는 호스트의 `snapshot.env`와 Family Wiki에만 쓴다.
ssh 개인키·APNs 키·CF 토큰 값은 어디에도 기록하지 않는다.

관련: #440(1단계 설계 코멘트 2026-10-19) · #412 · #426 · #420 ⑥ · #380 · #370 · `DECISION-2026-10-19-AGENT-CHAT-TO-HANDE.md` · `NATIVE-E2EE.md` · `TUWUNEL-OPERATIONS.md`(같은 틀의 Matrix 쪽 백업)
