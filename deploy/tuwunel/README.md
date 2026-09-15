# deploy/tuwunel — 홈서버 배포 패키지

결정 D(`docs/DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md`)에 따라 Synapse/Element/Postgres 구성을 대체하는
단일 바이너리 홈서버 **Tuwunel**의 배포 파일이다. 절차와 검증 체크리스트는 [`docs/TUWUNEL-DEPLOY.md`](../../docs/TUWUNEL-DEPLOY.md).

| 파일 | 용도 |
|---|---|
| `tuwunel.pins.json` | 버전·릴리스 자산·sha256 고정값(업스트림 체크섬 미공개 → 유일한 무결성 기준) |
| `fetch-tuwunel.sh` | 자산 다운로드 → 크기·sha256 대조 → 바이너리 추출·해시 대조 → 설치. 불일치 시 삭제·exit 1 |
| `tuwunel.toml.example` | 가족 전용 설정(가입 토큰 전용, 게스트·연합 off, 방 암호화 기본, 100 MiB, `cf_connecting_ip`) |
| `tuwunel.service` | 강화 systemd 유닛(전용 사용자, `ProtectSystem=strict`, 정적 등록 토큰 경로) |
| `family-messenger-backup.service` / `.timer` | 매일 04:30(KST) 쌍 백업(관리방 온라인 백업+restic). restic 저장소는 환경 파일, admin 토큰 경로는 호스트 드롭인으로 조정. 절차는 [`docs/TUWUNEL-OPERATIONS.md`](../../docs/TUWUNEL-OPERATIONS.md) |
| `family-messenger-health.service` / `.timer` | 매시 헬스 점검(홈서버 노드): client API·필수 유닛·완료 백업 신선도. 상태 전환 시에만 관리방 통지(`scripts/health_check.py`) |
| `cloudflare-ingress.example.json` | client API·인증 미디어·well-known만 노출하는 터널 ingress |

이 디렉터리는 코드·문서만이다. 실제 운영 배포는 별도 승인 후 런북대로 진행하며, 여기에 실제 도메인·토큰·터널 ID를 쓰지 않는다.
