# 의존성·프로세스·자원 사용량 기록

OWN-SYSTEM.md 구현 순서 1번의 기록 의무("직접/간접 패키지 목록과 서버 프로세스 수를
기록한다")와 #16 체크리스트 항목을 이행하는 기준 기록이다. 이 문서는 성능·용량
주장이 아니라 측정 시점의 사실 기록이며, 각 수치 옆에 환경과 방법을 함께 적는다.
기록 갱신은 `scripts/resource_report.py`로 재측정해 이 표를 바꾸는 방식으로 한다.

- 최초 측정: 2026-09-09 (커밋 `ce0f461`)
- 운영 스택 측정 환경: 전용 운영 서버 — 읽기전용 `docker stats`/`docker exec psql`/`du`
- 프로토타입 측정 환경: 개발 서버(2 vCPU) — 합성 데이터 루프백 스모크
- 실제 가족 기기·모바일·백업 복원 시점의 사용량은 이 기록에 없다.

## 구성요소별 직접·간접 의존성

재생성: `python3 scripts/resource_report.py census --root .`

| 구성요소 | 직접 | 간접 | 비고 |
| --- | --- | --- | --- |
| 네이티브 서버 (Go, `server/`) | 2 — `github.com/golang-jwt/jwt/v5` v5.3.1, `github.com/mattn/go-sqlite3` v1.14.52 | go.sum 고유 모듈 2 (직접 2와 동일 — 간접 모듈 추가 없음) | `server/go.mod`, `server/go.sum` |
| 브라우저 MLS 실험 (WASM) | 8 | 151 (락 전체 외부 패키지 197) | `experiments/openmls-browser/dependencies.json` 고정 기록(패키지별 라이선스·해시 포함). 소스 그래프 기준이며 도달가능성 분석이 아니다 |
| Matrix 브리지 시험 (Python) | `matrix-nio[e2e]==0.25.2` | 해당 SDK 의존 그래프 | 운영 런타임 의존성이 아니라 기존 Matrix 연결부 시험용이다 |
| 브라우저 검증 (Python) | `playwright==1.62.0` | 해당 도구 의존 그래프 | 검증 전용이며 메신저 런타임 의존성이 아니다 |

고정 컨테이너 이미지(digest 고정, `compose.yaml`):

- `postgres:17@sha256:67f41722…ad5675` — 상한 512 MiB
- `ghcr.io/element-hq/synapse:v1.160.0@sha256:78de1d10…477b205f` — 상한 1 GiB
- `vectorim/element-web:v1.12.27@sha256:7050130b…682d013019e` — 상한 192 MiB

고정 툴체인(CI가 해시·버전으로 고정): Go 1.27.1(`server/go.mod`), Rust 1.91.1 +
wasm-bindgen 0.2.126(MLS 실험), Node 22.22.2, Python 3.11(verify)/3.12(MLS 실험).

## 서버 프로세스 수

| 배포 형태 | 프로세스 구성 |
| --- | --- |
| Matrix 운영 스택 (현재 운영) | 컨테이너 3개: postgres, synapse, element. 호스트 쪽 Cloudflare 터널·caddy는 운영 노드 구성 소속이며 이 레포가 관리하지 않는다 |
| 네이티브 프로토타입 (`server/`) | 프로세스 1개(단일 Go 바이너리, loopback 전용). 합성 서명이 필요한 시험에서 `family-policy`가 별도 프로세스 1개로 추가된다 |

재생성(운영 스택): `docker compose -p family-messenger ps` — 2026-09-09 기준
running 3, 컨테이너 내 프로세스 수(PIDs) 각각 11/18/13.

## 실측 기록

### Matrix 운영 스택 — 운영 서버, 2026-09-09

`docker compose -p family-messenger stats --no-stream --format '{{json .}}'` 두 차례:

| 컨테이너 | 메모리 사용/상한 | 메모리 % | CPU % (두 샘플) |
| --- | --- | --- | --- |
| synapse | 432.8 MiB / 1 GiB | 42.3% | 0.24–0.25% |
| postgres | 63.9 MiB / 512 MiB | 12.5% | 0.03–5.74% |
| element | 10.4 MiB / 192 MiB | 5.4% | 0.00% |

postgres CPU 샘플 편차는 docker stats의 순간 값 성격 때문이며 별도 원인 근거는 없다.

보관량(같은 시점, 읽기전용): Postgres DB 15 MB, pgdata 볼륨 71 MB,
media_store 60 KB, 사용자 3, 방 2. 호스트 디스크 1 TB 중 864 GB 가용.
이 규모는 운영 초기 가족 사용량이며 용량 계획의 근거로 쓰려면
`scripts/check_storage.py` 상시 점검 값과 함께 봐야 한다.

### 네이티브 프로토타입 — 개발 서버(2 vCPU), 합성 루프백, 2026-09-09

`python3 scripts/resource_report.py watch --grace-seconds 0.5 -- python3 tests/native_smoke.py --binary artifacts/family-dev`
를 세 차례 실행한 결과(본문 없는 JSON 출력):

| 항목 | 값 |
| --- | --- |
| 서버 프로세스 최대 RSS (VmHWM) | 10.4–11.1 MB (세 실행) |
| 동시 서버 프로세스 수 | 1 (재시작 증명의 두 인스턴스를 순차 실행 — 관측 고유 PID 1–2) |
| 하위 트리 CPU 합계 (getrusage, 스모크 구동기+서버) | 약 0.24초 / 실행 0.8–0.9초 |
| 바이너리 크기 | family-dev 14.1 MB, family-policy 10.1 MB (trimpath 빌드) |

RSS는 서버 프로세스의 커널 기록 누적 최댓값이라 신뢰할 수 있고, CPU 합계는
구동기 Python을 포함한 하위 트리 값이라 서버 단독 값과 다르다. 루프백 합성
부하이며 처리량·지연·동시 사용자 주장으로 읽지 않는다. 브라우저(WASM) 메모리
측정은 이미 `experiments/openmls-browser/IDENTITY-CONTEXT.md` 비용 절에 기록돼
있어 여기서 반복하지 않는다.

## 한계

- 이 기록은 측정 시점 스냅샷이다. 의존성·이미지·툴체인은 다음 변경 시 갱신한다.
- 모바일 기기, 실제 가족 동시 사용, 백업 복원 중 부하는 미측정이며 #2·#3의
  수용 검사 항목으로 남아 있다.
- 네이티브 프로토타입 수치는 합성 데이터 루프백이고 E2EE 활성 경로와 실제
  첨부 워크로드를 대표하지 않는다.
