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
| 릴레이 바이너리 | 곽가 재현 빌드 → 서서 스테이징(`STAGE-SHA256SUMS`)이 정본. 빌드는 digest 고정 컨테이너 [`deploy/native-relay/build/build.sh`](../deploy/native-relay/build/build.sh) `<빈 산출 디렉터리>`로만(깨끗한 커밋 클론, 산출 `SHA256SUMS`·`BUILDINFO`; 같은 커밋 2회 빌드 해시 일치는 CI `native-mls`가 네이티브 트랙·빌드 컨테이너를 건드리는 PR과 머지 큐마다 확인). 스냅샷은 데이터만. 교체는 [`deploy/native-relay/native-relay-swap`](../deploy/native-relay/native-relay-swap)로만(rename 교체 + `/v2/health` 확인 + 롤백) |
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
  --ssh-key /etc/native-relay/snapshot-push.key --keep-hours 6 --keep-days 30
```

- 산출물: `<dest>/relay-<UTC시각>.tar.gz`(0600) + `.sha256` 사이드카. 상태 디렉터리에 `relay-<시각>.json`과
  `latest.json`(0600). `status`는 `complete` 또는 `push-failed`(로컬 사본은 남고 종료 코드 1 → systemd 실패로 드러남).
- 복사본에 `PRAGMA integrity_check`를 돌려 `ok`가 아니면 보관하지 않는다.
- 심볼릭 링크·특수 파일은 거부한다(복사본이 조용히 다른 것을 가리키는 일을 막는다).
- 잠금 파일로 동시 실행을 막는다. 삭제는 보존 규칙이 정한 **이 스크립트가 만든 이름**만 건드린다.
- 보존: 최근 6시간 전량 + 그 이전은 UTC 하루 1개 × 30일. (2026-10-29 48h→6h: 5분 주기×48h=576개×~70MB로 서서·수신 2곳이 각 35~43G를 써서 축소. 5분 단위 복구 지점은 최근 6시간만 보장.) 수신 호스트는 `--prune-only --dest <inbox>`로 같은 규칙 적용.
- 유닛: `deploy/native-relay/native-relay-snapshot.{service,timer}`(5분, 릴레이 호스트) ·
  `native-relay-snapshot-prune.{service,timer}`(수신 호스트, **매시** — 하루 1회면 정리 사이에 5분 스냅샷이 하루치
  쌓여 2026-11-11 공명 수신함이 새벽 직전 약 35~40G까지 찼다. 매시면 최대 약 12G). 경로는 `/etc/native-relay/snapshot.env`
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

오래된 스냅샷으로 복원하면 릴레이는 **뒤로 간다**: 이미 소비된 seq 번호를 다시 발급하고, 커서가 앞서 있는 클라이언트는 그 메시지를
**조용히 건너뛴다**. `store.go`도 `last_seq`는 절대 뒤로 가면 안 된다고 못 박는다. `--bump-seq N`은 모든 방의 `mls_rooms.last_seq`에
N을 더해, 복원 뒤 첫 이벤트의 seq가 어떤 클라이언트 커서보다도 크게 만든다. `epoch`(MLS 암호 상태)과 `revision`은 건드리지 않는다.
N은 스냅샷 이후 발생했을 수 있는 이벤트 수보다 넉넉히(기본 권장 1000). 드릴·격리 복원에서는 0으로 두고 건수 대조만 해도 된다.

**하는 일은 seq 재사용 방지뿐이다. 클라이언트를 멈추게 하지 않는다**(2026-11-13 격리 실측, #440). 이 절은 그 전까지 "모든 기기가
`history_gap`으로 명시적으로 멈춘다"고 적었는데 사실이 아니었다. 클라이언트의 정지 규칙은 `first_seq > 커서 + 1`이고
(`host-core/src/room.rs` `history_gap`), `first_seq`는 릴레이가 **아직 갖고 있는 가장 오래된** 이벤트의 seq다(`server.go` `FirstSeq`) —
`last_seq`를 올려도 변하지 않는다. `history_gap`은 릴레이가 오래된 이벤트를 지웠을 때(#268)의 규칙이지 복원의 규칙이 아니다.

실측한 것(합성 데이터 · 루프백 릴레이 · 정책 ON · 한데 웹과 스튜어드 봇):

| 스냅샷 뒤에 있었다가 사라진 것 | 복원 + `--bump-seq 1000` 뒤 |
|---|---|
| 없음 | 열려 있던 웹·봇이 그대로 이어진다. 정지·경고 없음. 새 이벤트 seq = 스냅샷 `last_seq` + 1001 |
| application 메시지만 | 정지·경고 없음. 그 메시지를 아직 못 받았던 기기는 끝내 못 받는다(조용한 일부 손실) |
| 같은 경우, **`--bump-seq 0`** | 새 메시지가 옛 seq로 발급돼 커서가 앞선 기기에 전달되지 않는다. 보낸 기기 화면에서도 사라진다. 오류 표시 없음 |
| commit(구성원 변경) | 방이 **안내 없이 갈라진다** — 아래 |
| 방 생성 | 릴레이는 404 `no_such_room`. 봇은 그 방을 계속 `joined`·`halted: false`로 보고한다 |
| 기기 등록(정책 revision) | 그 기기의 쓰기가 403 `device_not_allowed` → 재등록(revision +1) |

commit이 사라진 방(릴레이 epoch n, 기기 MLS epoch n+1). 클라이언트는 릴레이가 알려 주는 epoch으로 보내므로 CAS(409)에 걸리지 않고,
MLS는 지난 epoch의 메시지도 풀 수 있어 대부분이 "정상처럼" 돈다:

| 기기 | 보이는 것 | 실제 |
|---|---|---|
| 손실 구간 내내 켜져 있던 기존 구성원 | 정상 | 서로 송수신 정상 |
| 사라진 commit으로 **추가된** 기기 | 수신은 된다. 송신은 「보내지 못했습니다(403 not_a_member)…」 | 릴레이 명단에 없다. 다른 기기는 모른다 |
| 손실 구간에 **꺼져 있던** 기존 구성원 | 정상처럼 보인다(멤버 수는 옛 값) | 남의 새 메시지를 못 푼다(앱 기록에만 「해독 거부 → 건너뜀」). 자기 메시지는 일부만 읽는다 |
| 스튜어드 봇 | `halted: false`, 오류 이벤트 0건 | 릴레이 epoch을 따라가 계속 응답. 어긋남을 감지하지 못한다 |

그 방에 다음 commit이 들어가면 릴레이 명단이 commit의 명단으로 다시 맞춰져 「추가된 기기」는 풀린다. 「꺼져 있던 기기」는 그 commit을
적용하지 못해 풀리지 않는다 — 새 방으로 옮겨야 한다.

로비 키패키지(#380)도 스냅샷 시점으로 돌아간다: 스냅샷 뒤에 소비된 패키지가 "미사용"으로 되살아나는데 기기는 그 비밀을 이미 지웠을 수
있다(유예 뒤 정리). 기기의 목록과 릴레이의 목록이 한 칸 어긋나, 복원 뒤 로비 초대는 **실패 → 성공 → (정리 뒤) 실패 → 성공**을
되풀이했다(받는 기기 기록: 「열 수 없는 Welcome 은 건너뛴다」, 초대한 쪽에는 구성원으로 보인다). 스스로 풀리지 않는다.

정책 체인도 같은 성격이다: 스냅샷 `policy_revision`과 현재 체인의 마지막 revision 차이가 재등록 범위다.

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
| peer_stop | (선택) peer 릴레이 정지(예제 `cutover.args.example`은 `systemctl disable --now` — 정지와 함께 옛 호스트 자동 기동도 끈다). **실패는 치명** — 못 멈춘 peer는 아직 서빙 중일 수 있다. peer 호스트가 죽은 게 확실할 때만 `--peer-unreachable-ok` | exit≠0 |
| restore | `native_relay_restore.py --bump-seq N --owner native-relay`(유닛 active면 거부) | 건수 불일치 |
| fence | TXT → 자기 이름, DoH로 **연속 3회** 확인될 때까지 대기(≤300 s, 리졸버 TTL 창) | 미확인 |
| reprobe | peer·엣지 1회 재확인 — 복원하는 사이 peer가 살아났으면 **여기서 멈춘다**(두 번째 작성자 방지) | 어느 쪽이든 200 |
| start | `systemctl start native-relay` + 로컬 health 200(≤120 s — 유닛의 ExecStartPre가 옛 값을 한 번 읽어 실패해도 `Restart=on-failure` 30 s 재시도를 기다린다) | 미기동 — **DNS는 아직 옛 호스트** |
| enable | `systemctl enable native-relay` — 새 활성 호스트가 **재부팅 뒤 스스로 릴레이를 올리게**(대기 유닛은 disabled로 설치된다; 부팅마다 시작 측 펜스가 판정). 2026-11-07 순욱이 활성인데 disabled로 하루 운영된 빈칸의 수정 | 멈추지 않음 — 실패는 기록 + exit 3(릴레이는 이미 서빙 중이라 여기서 멈추면 DNS가 옛 호스트에 남는다) |
| dns | 호스트명별 CNAME → 자기 터널(`proxied`) | API 실패 |
| edge | 엣지 프로브 200(≤180 s) | — |
| client_hook | 봇·브리지 재지정 명령(반복 가능) | 실패는 기록 + exit 3(`complete-with-hook-failures`); 전환 자체는 끝난 상태 |

- 실패한 단계에서 멈추고 **되돌리지 않는다**. 기록 JSON(`state/cutover-<시각>.json`)에 어디까지 됐는지 남으므로
  운영자가 이어서 처리한다(예: fence는 바뀌었는데 start 실패 → 원인 수정 후 `systemctl start`, 그다음 dns부터 수동).
- 봇은 릴레이 주소를 env 파일 한 곳(`NATIVE_RELAY_URL`, 비밀 없음)에서 읽는다 — 유닛 drop-in `60-relay-url.conf`의
  `ExecStart=… ${NATIVE_RELAY_URL} …` + `EnvironmentFile=/etc/native-relay/bot-relay.env`(공명만 #451 방식 `relay.env`), Termux는 runit
  `run`이 `$PREFIX/etc/native-relay/bot-relay.env`를 읽는다(#699 P0-d; 없으면 `archive/native-mls/bot/deploy/install-node-bot-termux.sh`가 처음 한 번 만든다, #492). 재지정 훅 `deploy/native-relay/native-relay-repoint` v2(#702)는
  노드별 `repoint.conf`의 봇 목록을 하나씩 재시작하고 `steward_ready`를 확인한다 — `cutover.args`에 노드마다
  `--client-hook ssh -n -o BatchMode=yes <node> /usr/local/sbin/native-relay-repoint <새 릴레이 http URL>` 한 줄(오너 결정 D4). 한데 브리지
  (`ccc-hande-bridge`)는 릴레이 주소를 갖지 않고 봇과 Unix 소켓으로만 통신하므로 재지정 대상이 아니다. JWT 갱신
  (`jwt-refresh.sh`)은 공개 호스트명(`relay.<도메인>`)을 쓰므로 dns 단계를 따라간다.
- `--dry-run`은 판정·계획까지만, `--probe-only`는 판정만(워치독·cron에서 쓴다).
- 기록·stdout에는 토큰 값이 없다. 훅 명령과 stderr는 `Authorization`/`Bearer`/`token=`/`key=`/`secret=`/`password=`/`--token X`/
  URL userinfo 패턴을 **최선 노력으로** 가린 뒤 기록한다 — 완전하지 않으므로 훅에 비밀값을 인자로 넣지 않는 것이 원칙이다(경로·호스트명만).
- **남는 split-brain 창**: 옛 호스트가 재부팅해 자기 ExecStartPre가 옛 TXT 값(리졸버 캐시)을 읽으면 기동할 수 있고, 다음 정지 측
  확인(연속 3분)에서 진다 — 최대 약 TTL + 3분. TXT를 TTL 60으로 미리 만들어 두는 이유다. 전환 스크립트의 재프로브는 1회 샘플이라
  `activating` 중인 peer를 못 볼 수 있다; 정지 측 타이머가 그 창을 닫는다.
- 스냅샷 유닛의 `state/skipped-latest.json`은 다음 성공 스냅샷이 지운다 — 워치독은 이 파일의 존재만으로 "펜스에 막힘"을 판정해도 된다.

### 계획 이전 — 활성 호스트를 정상 상태에서 옮길 때 (#699, 2026-11-06 서서→순욱 실측)

`probe`는 옛 호스트가 살아 있으면 `not-down:healthy`로 거부한다(장애 대응용 설계). 계획 이전은 **옛 호스트를 먼저 멈추고** 같은
스크립트를 돌린다. 2026-11-06 실측: 중단 약 4분 12초, hook 12/12, 오너 앱·푸시 정상.

1. **사전**: 새 호스트 `--dry-run --probe-tries 1` = `not-down:healthy`, `--dry-run --skip-probe` = plan OK. 새 호스트의 릴레이 바이너리·drop-in·
   APNs 키가 옛 호스트와 같은지(유효 `ExecStart` 인자 비교), 양쪽 `cutover.args`의 hook 줄, 반대 방향(되돌리기) `cutover.args`와 DNS·Access
   토큰을 미리 확인한다.
2. **알림 feeder 일시 중지**(#703이 배포되기 전까지 필수): 봇은 notice 확인 프레임이 없어 feeder가 「소켓에 쓰면 삭제」한다. 릴레이가 멈춘
   동안 봇이 hook으로 재시작되면 그 사이 넘겨받은 알림은 사라진다(실측: 카드 알림 1건). 옛 호스트 중지 **전에**
   `hande-card-feeder`·`fleet-alerts-sender-hande`(서서), `bunjang-hande`(곽가), `insta-feeder`(대교, `sv down`)를 멈추고 6단계 뒤 다시 켠다
   (멈춘 동안의 알림은 각 큐에 남았다가 재개 때 나간다).
3. **옛 호스트**: `systemctl stop native-relay-snapshot.timer` 그리고 `systemctl stop native-relay` — 타이머를 멈추지 않으면 plan과
   confirm 사이에 새 아카이브가 도착해 토큰이 어긋난다. 릴레이를 먼저 멈춰야 plan의 `peer_snapshot`이 **마지막 메시지까지** 담는다.
4. **새 호스트**: `cutover.args --probe-tries 1`(plan — probe `relay-down` → peer_snapshot → 토큰). integrity ok, peer_snapshot exit 0,
   아카이브 생성 시각 ≥ 중지 시각을 확인한 뒤 `--confirm <토큰>`.
5. **확인**: 엣지 200, 노드마다 `native-relay-repoint --check` = 새 URL, 새 호스트 첫 스냅샷이 push 대상에 도착, 펜스 TXT = 새 이름.
6. **옛 호스트 정리**: `systemctl disable native-relay`(이제 대기 역할 — 자동 재부팅 때 기동 시도→펜스 거부→30 s 재시도 반복과,
   TXT 캐시 창의 split-brain 기동을 막는다; 되돌릴 때는 전환 스크립트의 enable 단계가 다시 켠다), `native-relay-snapshot.timer` 다시 켜기
   (펜스로 skip — 이제 대기 역할), 2단계 feeder 재개. 확인: 옛 호스트 `is-enabled` = disabled, 새 호스트 = enabled.

- **대화 채널이 이 릴레이를 거칠 때**(한데로 운영자와 대화 중인 에이전트): 위 전체를 대화와 분리된 유닛(`systemd-run --on-active=90s …`)으로
  돌리고 결과는 다른 채널(Matrix 플릿 알림)로 받는다 — 릴레이가 멈추면 대화도 멈추고, 그 노드 봇의 hook 재시작이 진행 중 답을 끊는다.
- Cloudflare proxied CNAME은 ttl을 1(auto)로 보관하므로 `dns_upsert(ttl=60)`는 같은 내용에도 `updated`를 낸다(무해 — 내용·proxied는 같다).
- 되돌리기: 몇 분 안·사용자 트래픽 전이면 옛 호스트 원본으로(새 호스트 stop → TXT·CNAME 원복 → 옛 호스트 start → hook 원복), 그 뒤에는
  옛 호스트의 반대 방향 `cutover.args`로 **데이터를 가지고** 전환한다.

### 전환 뒤 가족·봇 복구 (오너 결정 D3)
**기기는 멈추지도 알리지도 않는다**(위 「`--bump-seq`」의 실측). 손실 구간(마지막 스냅샷 시각 ~ 전환 시각)에 무엇이 있었는지는
사람이 확인한다. 계획 이전처럼 정지 뒤의 마지막 스냅샷으로 옮겼다면 손실 구간이 없고 아래는 필요 없다(2026-11-06 실측).
1. 손실 구간을 방에 알린다 — 그 사이 메시지를 못 받은 기기가 있을 수 있고 화면에는 표시가 없다.
2. 그 구간에 **구성원 추가·제거가 있었던 방**과 **새로 만든 방**을 가린다. 봇의 `room status`·기기 화면은 판단 근거가 못 된다(모두 정상으로
   나온다). 근거가 없으면 구성원이 여럿인 방은 옮기는 쪽이 안전하다.
3. 그 방들은 스튜어드 봇이 새 방을 열고 전원을 다시 초대한다(`native-mls-bot room create <방> <모드>` → 기기마다 `room invite <방> <기기>`,
   `bot/STEWARD.md`). 실측: 봇 3.4 s(3명), 웹 화면으로는 15~35 s. 예전 서술의 운영자 relay-app 기기는 폐기됐다.
4. **초대가 받아지지 않으면 다시 한다**: 복원 뒤에는 로비 키패키지가 한 칸 어긋나 있다. `room remove <방> <기기>` 뒤 `room invite`를 다시
   하면 다음 패키지로 간다(실측 0.8 s). 방 키패키지(기기가 「참여 요청」으로 올린 것)가 있으면 그것이 먼저 쓰여 이 문제를 피한다.
5. 손실 구간에 등록한 기기는 다시 등록한다. 봇은 재지정 훅으로 새 릴레이를 보고 있으므로 초대만 받으면 된다.
6. 이전 방은 "이력 보관"으로 둔다(릴레이의 `-reset-room`은 쓰지 않는다 — 영구 삭제). 기기에 봉인 보관된 이전 메시지는 계속 보인다.
7. 플릿 알림방은 **알림 봇이 직접 다시 만든다** — 아래. 필요한지부터 본다.

#### 플릿 알림방 `fleet-alerts` 다시 만들기 (#460 ④)

알림방은 relay host의 steward 봇이 만들고 오너 기기를 초대한 방이다(2026-10-27 설치, 오너 기기 2대 초대 epoch 2).

| 항목 | 값 | 근거 |
|---|---|---|
| 정책 actor / 기기 | `fleet` / `fleet-bot` | 봇 commit의 `members[].actor`는 기기 ID의 첫 하이픈 앞이고 릴레이가 정책 actor와 대조한다(DEVICES-V4 G-H3). `fleet-alerts-bot` 같은 기기는 actor `fleet` ≠ `fleet-alerts` → 403 `commit_actor_mismatch` |
| 봇 유닛 | `hande-fleet-alerts-bot.service`(`native-mls-bot <릴레이> steward fleet-bot --identity-file … --rooms-dir …`) | `repoint.conf.example`의 재지정 대상 |
| 필수 env | `NATIVE_MLS_BOT_ROOM_FRAMES=1`(= `--room-frames`) | 없으면 `notice`는 agent 방 이름일 때만 게시된다 — alert 방 알림이 버려진다(`bot/STEWARD.md` 「여러 agent 방」) |
| 송신 | `fleet-alerts-sender-hande.service`(ccc-node, outbox → `notice` 프레임) | Matrix sender와 이중 송신 — 그동안 Matrix가 폴백 |
| 방 모드 | 설치 때 `alert`(notice만 게시). ok/hold 응답기(ccc-node #2553) 적용 뒤에는 봇 로컬 설정 `agent`(2026-10-27 카나리) | `<rooms-dir>/<방>.mode` — 다시 만들 때 **이전 값과 같게** |

1. **필요한지 먼저 본다.** `native-mls-bot room status - --rooms-dir <dir>`(또는 `<dir>/health.json`의 `rooms[]`)에서 `fleet-alerts`가
   `joined:true`·`halted:false`이고 오너 기기가 새 알림을 받으면 다시 만들지 않는다(2026-11-06 계획 이전은 재참여 없이 정상이었다).
2. 송신을 멈추고 이전 모드를 적어 둔다 — 멈춘 동안의 알림은 outbox에 남았다가 6단계에서 나간다.
   ```bash
   systemctl stop fleet-alerts-sender-hande
   cat <dir>/fleet-alerts.mode
   ```
3. **방 id를 정한다.**
   - 릴레이에 이전 `fleet-alerts` 방이 남아 있으면(스냅샷 복원 — 보통의 D3) 같은 id는 쓸 수 없다: 봇의 새 그룹(epoch 0) 첫 commit이
     CAS에서 거부된다. 이전 방은 이력 보관으로 두고(`room close`·`-reset-room` 금지 — 닫힌 방은 다시 열리지 않는다)
     `native-mls-bot room mode fleet-alerts silent --rooms-dir <dir>`로 내린 뒤 **새 id**를 쓴다. 새 id는 앱 이름표(웹 `strings.js`
     `roomNames`, iOS `Strings+Names.swift`, Android `AgentActors.kt`)·ccc-node 송신과 hande 브리지의 방 설정(목록에 없으면
     `rejected: room-not-allowed`)을 함께 바꿔야 「🔔 플릿 알림」으로 보이고 알림이 그 방으로 간다 — 별도 PR·승인.
   - 릴레이에 그 방이 없을 때(빈 데이터로 새로 띄운 릴레이)만 같은 id `fleet-alerts`: 봇 유닛을 멈추고 `<dir>/fleet-alerts.state`·
     `.mode`·`.state.refused`를 보관 디렉터리로 옮긴 뒤 다시 켠다(steward는 아는 방을 다시 만들지 않는다 — `room already known to this steward`).
4. **만들고 오너 기기를 초대한다**(steward 실행 중, 봇 유닛과 같은 사용자). 오너 기기 = `native-devices -device-state … -inspect`의
   actor `owner` active 기기.
   ```bash
   native-mls-bot room create  <방> alert --rooms-dir <dir>
   native-mls-bot room invite  <방> <오너 기기> --rooms-dir <dir>   # 기기마다 한 번 — 앞 초대의 pending 이 풀린 뒤(echo → Welcome) 다음
   native-mls-bot room members <방> --rooms-dir <dir>
   ```
   `no key package for <기기> in room <방> or in the lobby`면 그 기기에서 앱을 한 번 열어 로비 키를 보충하고 다시 초대한다.
5. 2단계 모드가 `agent`였으면 `native-mls-bot room mode <방> agent --rooms-dir <dir>`. 유닛의 `NATIVE_MLS_BOT_ROOM_FRAMES=1`을
   `systemctl show -p Environment hande-fleet-alerts-bot`(또는 drop-in)으로 확인한다.
6. `systemctl start fleet-alerts-sender-hande` — 쌓인 알림이 나간다.
7. **검증**
   - 오너 기기에서 새 방에 알림이 보이고, 봇 저널에 `notice_acked`(room·seq)가 남는다. 이전 방(silent)에는 새 알림이 없다.
   - **ok/hold 회신**: action 급 알림 1건(ccc-node 테스트 알림)에 오너 기기에서 `ok <번호>`(또는 카드 [보내기]) → 응답기 reply 영수증 +
     ack 글 `#<번호> ✅ #<알림> ok 접수 …`가 한데·Matrix 양쪽 방에 게시되고 재통지가 멈춘다(`ALERT-REFS-V1.md` 예시, 2026-10-27 카나리와
     같은 판정). `hold <번호>`도 같다. 오너가 아닌 기기·봇의 글은 무시돼야 한다.

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
**함께** 요구하므로 스크립트로 하면 사실상 §복원 전체(DB도 그 시점으로 — `--bump-seq`와 「전환 뒤 가족·봇 복구」의 확인 절차가 따라온다)이고, `policy/`만
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

### g. 대화방 순서 — `actor_room_order` (#715)

| 열 | 내용 |
|---|---|
| `actor` (PK) | 정책 체인 기록의 actor(사람 단위, 기기 단위 아님) |
| `rooms` | 방 ID JSON 배열(≤ 64) — 순서 메타데이터만, E2EE 본문과 무관 |
| `revision` · `updated_at` | `PUT /v2/me/room-order` 의 CAS revision(저장마다 +1)과 마지막 저장 시각 |

`native-mls-v2.db` 안의 테이블이라 스냅샷에 같이 들어가고(`manifest.json` 의 테이블 건수 요약 대상은 아니다), 이 테이블이 없는 옛
스냅샷을 복원해도 릴레이가 기동 때 만든다(revision 0 → 클라이언트가 다음 목록 갱신 때 다시 시드). 복원으로 revision 이 되돌아가면
그 뒤 저장한 기기는 다음 `PUT` 에서 409 를 받고 서버 값을 채택한다. 행을 지우면 그 사람의 순서만 초기화된다.

## 비밀과 공개 저장소 규칙

이 저장소는 PUBLIC이다. 실제 호스트명·계정·키 경로·터널 ID는 호스트의 `snapshot.env`와 Family Wiki에만 쓴다.
ssh 개인키·APNs 키·CF 토큰 값은 어디에도 기록하지 않는다.

관련: #440(1단계 설계 코멘트 2026-10-19) · #412 · #426 · #420 ⑥ · #380 · #370 · `DECISION-2026-10-19-AGENT-CHAT-TO-HANDE.md` · `NATIVE-E2EE.md` · `TUWUNEL-OPERATIONS.md`(같은 틀의 Matrix 쪽 백업)
