# 상시 Matrix 연결부: 개발 노드 개인방 시험

`scripts/fleet_matrix.py`는 암호화 개인방의 텍스트 요청을 저장하고 별도 노드 실행부로
전달한다. 이 파일을 추가한 것만으로 운영 봇이 설치되지는 않는다. #10/#1602의
단계적 구현이며, 단체방·첨부·다른 provider·쓰기 작업의 실사용 정책은 후속 범위다.
worker CLI의 기본값은 Codex read-only / approval=never이고, 노드 하네스에 붙이는 플래그는
[FLEET-WORKER.md](FLEET-WORKER.md#하네스-플래그)에 있다. `worker_argv_family`를 두면 가족방만
다른(예: read-only) worker 인자로 실행하고 개인방은 `worker_argv`를 쓴다. 두 값 모두 저장
정책에 포함되므로 바꾸면 `saved-policy-changed`로 멈춘다(의도된 재확인 절차).
approval이 `never`가 아니면 worker의 승인 요청이 요청한 방의 `/approve`·`/deny`로 나간다.

운영 서버의 연결부에서 다른 노드의 실행부를 부를 때는 [SSH 실행 계약](FLEET-REMOTE.md)의
guardian·heartbeat·종료 확인과 `remote_worker: true`를 함께 사용한다.

## 설치와 최초 장치 신뢰

노드에 별도 venv를 만들고 `pip install -r requirements-matrix.txt`를 실행한다.
노드의 CCC Python/CLI 경로는 `worker_argv`에 절대 경로로 지정한다. AI 자격 증명은
기존 노드에 유지한다. 다른 노드의 환경이나 토큰을 복사하지 않는다.

1. 별도 비관리자 Matrix 봇 계정과 전용 장치 한 개를 생성한다. 사용자와 봇만 참여하는
   암호화 방을 만든다. 기존 가족방에 봇을 자동 초대하지 않는다.
2. 사용자가 실제로 사용하는 장치의 ed25519/curve25519 키를 신뢰할 수 있는 경로로
   대조한 후 pin한다. 임시 브라우저로 사람 계정에 로그인하여 crypto를 생성하지 않는다.
   사용자가 장치를 추가하면 자동 신뢰하지 않으며, 재검증 후 별도 상태 이전 절차가 필요하다.
3. 0700 설정 디렉터리에 0600 JSON을 저장한다. 예시에는 실제 토큰을 넣지 않는다.

```json
{
  "homeserver": "https://matrix.example.invalid",
  "account": "@agent:matrix.example.invalid",
  "device_id": "AGENT_DEVICE",
  "access_token": "PRIVATE_TOKEN",
  "pickle_key": "GENERATE_A_PRIVATE_RANDOM_KEY_AT_LEAST_24_CHARACTERS",
  "state_directory": "/var/lib/family-matrix-pilot",
  "owner": "@owner:matrix.example.invalid",
  "rooms": ["!PRIVATE_ROOM:matrix.example.invalid"],
  "devices": {
    "OWNER_DEVICE": {"ed25519": "43_BASE64_CHARACTERS", "curve25519": "43_BASE64_CHARACTERS"}
  },
  "not_before_ms": 1788825600000,
  "worker_argv": ["/path/to/ccc-python", "/path/to/scripts/fleet_worker.py",
                  "--workdir", "/path/to/pilot-workspace", "--codex-cli", "/path/to/ccc-codex"]
}
```

4. `fleet_matrix.py --config /private/config.json --initialize`로 새 봇 장치를 한 번
   초기화한다. 재시작은 같은 config와 같은 crypto/state를 사용한다. 토큰·장치·키·서버,
   소유자·방·실행 명령·기준 시각이 저장값과 다르면 중단한다. 암호화 상태가 남았는데
   식별 마커가 없는 경우 자동 재생성하지 않는다.
5. 예시 systemd 단위 `deploy/family-matrix.service.example`(2026-09-15 운영 반영본)의
   경로와 실제 실행 사용자를 노드에 맞춘다. PYTHONPATH는 telegram_bot.contracts 시임 import를
   위해 bridge 체크아웃을 가리킨다.
   실행 전 개인 상태의 암호화 백업과 가용 공간을 확인한다. 원본 설정·상태를 보존한다.
   배포 후 비밀을 출력하지 않고 health, 실제 암호화 왕복, 재시작 후 수신을 확인한다.

설정/상태의 마지막 디렉터리는 0700, 파일은 0600이며 symlink 경로를 거부한다.
한 계정의 상태는 한 프로세스만 잠근다. 재시작 중에도 crypto 저장소를 삭제하지 않는다.
표준 로그에는 메시지/토큰/승인 인수를 출력하지 않는다. private SQLite에는 복호화된
요청·답변·승인 설명이 있으므로 암호화 백업 대상으로 취급한다.

## 수신, 복구, 실행 경계

- `/sync` 원문을 private SQLite에 먼저 저장한다(최대 4MiB). 이후 SDK의 암호화 상태를
  갱신하고, 각 요청/거절/제어 처리를 기록한 뒤 sync token과 pending 제거를 함께 커밋한다.
  SDK 처리 직후 죽어도 같은 원문을 재처리한다. 이미 수락/거절한 event ID는 다시 실행하지 않는다.
- 타임라인 `limited`, 복호화 불가, 장치 키/집합 변화, 개인방 구성원 변화는 중단 사유다.
  자동 backfill이나 키 재생성으로 덮지 않는다. pending을 보존하고 누락 범위를 확인해야 한다.
  일반 네트워크 오류는 1~30초 backoff한다. 시작 실패는 systemd가 35초 간격으로 제한 재시도한다.
- 평문·타인·기준 시각 이전·수정·미지원 메시지를 작업으로 실행하지 않는다.
  허용된 장치가 보낸 검증된 암호화 텍스트만 처리한다. 실제 서버 구성원과 SDK 구성원도 대조한다.
- worker stdin은 수신 루프와 독립적이다. 일반 큐가 차도 승인/취소는 수신한다.
  거절된 일반 요청은 안내와 함께 영구 중복 기록을 남긴다.
- 결과는 worker 종료 확인 후 outbox에 기록한다. 작업당 새 worker를 사용하며,
  같은 대화의 저장된 provider session_id로 이력을 이어간다. 불확실한 결과는 자동 재실행하지 않는다.
- 답변을 UTF-8 12KiB씩 나누어 보내고 조각별 안정된 transaction ID와 성공 위치를 저장한다.
  SDK의 암묵적 전송 성공에 의존하지 않고, 모든 pin 장치의 키 공유 성공을 확인한 후
  암호화 이벤트를 전송한다. 공유 실패는 outbox를 보존하고 backoff 후 재시도한다.
  토큰을 바꾸면 서버의 중복 제거 범위도 바뀔 수 있으므로 자동 토큰 교체를 금지한다.

## 제어와 중단 확인

시작 안내의 `/cancel 작업번호`, 승인 안내의 `/approve 작업번호 승인번호` 또는
`/deny 작업번호 승인번호`를 같은 소유자의 같은 방에서 입력한다. 다른 방/작업/오래된
승인 번호는 거부한다. 제어 메시지는 전달 전에 기록하므로 장애 시 자동 재승인하지 않는다.
전달 안내는 실제 취소 완료를 뜻하지 않는다.

불확실한 작업은 확인 안내 후 `/ack 작업번호`로 대기를 해제할 수 있다. 이는 결과 확인을
기록하는 것이며 작업을 다시 실행하지 않는다. runtime 종료가 확인되지 않으면 모든 새 작업을
막는 `worker_cleanup_unconfirmed`도 남긴다. 이 경우 `/ack`만으로 서비스를 재개하지 않는다.
`worker_cleanup_in_progress`가 재시작 후 남은 경우도 동일하게 중단한다.
운영자가 해당 worker/runtime 프로세스 종료와 결과를 먼저 확인하고, private 상태를 백업한 후
원인을 해결해야 한다. 그 다음 아래 도구로만 차단을 해제한다. DB를 직접 편집하거나 초기화해서
이 제한을 우회하지 않는다.

### 운영자 차단 해제 도구

```bash
# 서비스를 먼저 멈춘다. 잠금을 쥔 프로세스가 있으면 도구가 거부한다(exit 2).
systemctl stop family-matrix-pilot.service
python3 scripts/fleet_matrix_state.py status  --config /private/config.json
python3 scripts/fleet_matrix_state.py unblock --config /private/config.json \
    --scope <status가 보여준 blocked_scopes 값> \
    --reason "worker pid 1234 종료·결과 대조 완료, 원인: ..."
```

- `--config` 대신 `--state <state_directory> --account <봇 계정>`을 줄 수 있다.
- `status`는 `worker_cleanup_unconfirmed`/`worker_cleanup_in_progress` 값과 차단이 귀속된
  scope(`blocked_scopes`), 불확실 작업이 남은 scope(`uncertain_scopes`)를 본문 없이 보여준다.
- `unblock`은 지정한 scope에 귀속된 차단만 지운다. 다른 scope, 차단이 없는 상태, 빈 사유는
  거부하고 아무것도 바꾸지 않는다. 성공 시 지운 키·scope·감사 번호·이전 값을 JSON으로 출력한다.
- 매 해제는 같은 SQLite의 `operator_audit` 표에 누가(`사용자#uid`, `SUDO_USER` 우선)·언제·
  어느 scope·왜·이전 값을 남긴다. 이 표는 삭제하지 않는다.
- 해제는 불확실 작업을 다시 실행하거나 상태를 바꾸지 않는다. 남은 불확실 작업은 서비스 재시작 후
  `/ack 작업번호`로 각각 확인한다. 예전 상태(값이 `true`만 있는 경우)는 불확실 작업의 scope로 귀속한다.

`meta.health`에는 시각·상태·본문 없는 중단 사유를 남긴다. systemd exit 78은 자동 재시작하지
않는다. SIGTERM 시 자식 stdin을 닫고 최대 25초 종료를 기다리며, systemd는 cgroup 전체를
40초 한도로 정리한다. 정리 중 중복 취소가 와도 별도 cleanup task를 끝까지 기다리고
불확실한 작업 기록을 남긴다. 정상 종료 확인 전 성공을 알리지 않는다.

시험 한도는 파일시스템 여유 256MiB 이상, inbox DB 128MiB 이하이며 초과 시 중단한다.
자동 삭제·이력 만료는 하지 않는다. 장기 운영용 보존/아카이브와 외부 경보는 후속 작업이다.

## 헬스 점검 (타이머)

봇 노드 운영자는 `deploy/family-matrix-health.service.example`+`.timer.example`(시간별)로
`family-matrix` 유닛 활성, 홈서버 client API 도달, sync 루프의 `meta.health` 신선도(기본 600초)를
점검한다. `scripts/health_check.py`는 stdout에 1행 JSON을 남기고 healthy면 exit 0, 아니면 1이다.
관리방 통지(`--alert-admin`, 전환 시에만 발화)는 봉인 admin 토큰이 있는 홈서버 노드 유닛이
담당하며, 관리방 밖 외부 경보는 후속 작업이다.

## 검증

`python3 -m unittest discover -s tests -v`는 SDK/계정 없이 상태·제어·worker 종료를 검사한다.
루프백 Tuwunel을 기동한 뒤 `python tests/tuwunel_smoke.py --credentials <0600 계정 파일>`은
실제 Matrix E2EE(megolm) 암호화 왕복을 검사한다(#104; verify.yml 루프백 통합이 같은 흐름).
Synapse 시대 드라이버 `matrix_frontend_smoke.py`는 `archive/synapse-stack/tests/`에 보존됐다. `--real-worker`는 명시적으로
허용된 CCC 노드에서 실제 read-only Codex 연결을 검사한다. 결과는 private `artifacts/`에 저장된다.
실제 사용자 장치나 운영 가족방을 시험 도구에 입력하지 않는다.

Cloudflare Tunnel과 Access 계정 인증은 별개다. 이 연결부는 Matrix 계정/장치/방 권한을
검사하며 Cloudflare Access를 생성하거나 변경하지 않는다.
