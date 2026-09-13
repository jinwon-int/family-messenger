# 운영 서버에서 노드 실행부를 호출하는 SSH 시험

Matrix/암호화 상태는 운영 서버에 두고 AI·GitHub 자격 증명은 각 노드에 유지한다.
`fleet_remote.py`는 노드에서 worker 한 개를 감시한다. `fleet_matrix.py` 설정에
`"remote_worker": true`를 넣으면 부모가 5초마다 heartbeat를 전송하고, 최종 응답 후
원격 종료 증거도 확인한다. 이 설정 변경은 기존 상태를 자동 전환하지 않는다.

## 고정 호출

운영자가 검증한 SSH 별칭·실행 사용자·절대 경로를 설정에 기록한다. 요청 본문이나
첨부파일명을 SSH 명령 문자열에 삽입하지 않는다. SSH 설정은 BatchMode,
StrictHostKeyChecking=yes, ConnectTimeout=10, ServerAliveInterval=5,
ServerAliveCountMax=3을 사용하며 PTY를 만들지 않는다.

Linux 운영 호출은 **고정된 노드별 systemd service** 안에서 guardian을 실행한다.
예를 들어 개발 노드에서는 다음 고정 명령을 SSH로 호출하도록 구성한다.

```sh
systemd-run --quiet --pipe --wait --collect \
  --unit=family-matrix-worker-agent-a \
  --property=KillMode=control-group --property=RuntimeMaxSec=1200 \
  --property=TimeoutStopSec=25 --property=UMask=0077 \
  --property=StandardError=null \
  /path/to/ccc-python /path/to/fleet_remote.py -- \
  /path/to/ccc-python /path/to/fleet_worker.py \
  --workdir /path/to/pilot-workspace --codex-cli /path/to/ccc-codex
```

같은 unit이 남아 있으면 다음 실행은 실패해야 한다. 기존 unit을 자동으로 죽이고
새 작업을 시작하지 않는다. `--wait`의 반환까지 확인하며, systemd cgroup이
프로세스 그룹을 벗어난 자손도 정리한다. guardian의 process-group 검사만으로
모든 형태의 자손 정리를 보장하지 않는다. systemd 없는 Android/Termux는 별도 수명주기
검증 전 배포하지 않는다. systemd 서비스로 분리 생성한 외부 작업이나 이미 발생한
부수 효과가 취소로 되돌아간다는 뜻도 아니다.

## 연결 종료와 확인

- guardian은 `{ "type": "heartbeat" }`를 받아 20초 임대를 갱신한다. heartbeat는
  실제 worker에 전달하지 않는다. 임대 만료·EOF·SIGHUP/SIGTERM·출력 파이프 실패가 나면
  worker stdin을 닫고 최대 20초 정리를 기다린다. 남은 process group은 강제 종료한다.
- 출력은 최대 512KiB의 JSON 한 줄이며, 부모가 5초 동안 출력을 소비하지 않으면 종료한다.
  작업 입력은 기존 64KiB 한도를 유지하고 guardian 한 개에 turn 하나만 허용한다.
- 마지막 출력은 guardian만 생성하는 `remote_closed`다. 작업 ID, worker exit,
  group_empty, clean, 고정 reason을 포함하며 본문·자격 증명을 포함하지 않는다.
  임대 만료·강제 종료·신호 중단은 clean 성공으로 취급하지 않는다.
- 부모는 worker result와 종료 marker, SSH/systemd 명령의 성공 반환을 모두 확인한다.
  marker가 없거나 일치하지 않으면 결과를 성공으로 게시하지 않고 cleanup fault를 남긴다.
  uncertain worker의 정상 퇴역(exit 1)은 runtime_closed=true와 clean marker가 함께 있어야
  조정 가능한 uncertain 상태로 남긴다. 자동 재실행은 하지 않는다.

현재 실제 worker는 Codex read-only 시험용이다. 다른 provider와 쓰기 도구 정책의 동등성,
원격 단절 시 외부 작업의 결과 조정은 전체 플릿 수용 기준에 남아 있다.

검증: `python3 -m unittest discover -s tests -v`의 원격 프로토콜 검사는 실제 자식 프로세스로
EOF·heartbeat·임대 만료·SIGHUP·강제 종료·marker 없는 성공 거부를 재현한다.
운영 활성화 전에는 운영 서버→대상 노드의 실제 SSH/systemd 호출, provider 두 턴 재개와 종료,
합성 작업 중 연결 단절을 각각 확인한다. 사용자 Matrix 기기를 시험용으로 생성하지 않는다.
