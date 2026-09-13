# 홈서버 0단계 격리 평가 — Tuwunel vs continuwuity (2026-09-13, yukson)

기준: `docs/DECISION-2026-09-13-MATRIX-CRYPTO-STACK.md` "홈서버 선정 — 1주 평가".
범위: yukson(`vps5`, 12 vCPU, 32 GiB, `/opt` 862 GiB free) `/opt/family-messenger-eval/`(0700) 안에서만. 운영 `family-messenger-*` 컨테이너·터널·포트 무변경(종료 시 재확인: synapse/element/postgres Up 4 days, tunnel active). 두 서버는 127.0.0.1:28008(Tuwunel) / 28018(continuwuity)에만 바인딩, 종료 후 LISTEN 0. 모든 계정·토큰은 `eval-*.invalid` 일회용. 증거 파일: `<eval>/{tuwunel,continuwuity}/{hs_eval.run.log,cycle.log,state.json.results.json,*.toml,*.log}`, 스크립트 `hs_eval.py`, `admin_cmd.py`, `cycle_*.sh`.

## 비교표

| 항목 | Tuwunel 1.9.1 | continuwuity 26.8.1 |
|---|---|---|
| **a. 다운로드·체크섬** | **확인함(자체 해시만)**. GitHub release `v1.9.1-release-all-x86_64-v3-linux-gnu-tuwunel.zst` sha256 `93900dab…4503`(33.4 MB) → 바이너리 107,045,776 B(102 MiB), 정적 링크(`ldd: not a dynamic executable`). 같은 릴리스 `.deb`(sha256 `1706674d…294c`)를 `dpkg-deb -x`로 풀어 `/usr/sbin/tuwunel` sha256 `e365ba0c…acea` == zst 추출본 **일치**(교차 검증). 릴리스에 SHA256SUMS·서명 없음, GitHub attestation API 0건 → 공식 체크섬/서명 **미지원** | **확인함(자체 해시만)**. Forgejo(`forgejo.ellis.link`) `conduwuit-linux-static-amd64` 109,290,256 B(104 MiB), sha256 `43bcf0e4…d02d`, 정적 링크. 체크섬·서명 파일 없음 → **미지원**. GitHub 미러는 v26.7.2까지·자산 없음(릴리스 호스트는 Forgejo) |
| a. 라이선스 | Apache-2.0 (GitHub API + deb `copyright`) | Apache-2.0 (GitHub API) |
| a. 릴리스 주기(최근 5) | 1.9.1 09-12 · 1.9.0 08-19 · 1.8.3 08-05 · 1.8.2 07-17 · 1.8.1 07-10 (2~5주) | 26.8.1 08-22 · 26.7.3 08-11 · 26.7.2 07-30 · 26.7.1 07-27 · 26.6.2 07-12 (1~3주; README "every week or two") |
| a. 보안 공지 경로 | SECURITY.md: GitHub private vulnerability reporting(advisories) 우선, 관리자 4명 E2EE DM, PGP 이메일 | SECURITY.md: 관리자 3명 E2EE DM, `security@continuwuity.org`; 최신 릴리스만 지원. 26.8.1 노트에 "security fix (SEC30)" |
| **b. 최소 설정** | **확인함**. `tuwunel.toml`: `allow_registration=true`+`registration_token_file`(토큰 없으면 401), `allow_guest_registration=false`, `allow_federation=false`, `allow_encryption=true`, `encryption_enabled_by_default_for_room_type="invite"`, `max_request_size="100 MiB"`(문자열 단위 허용), url_preview 허용목록 3종 `[]`, 127.0.0.1:28008. 미지원 키(`allow_check_for_updates`)는 WARN 후 무시 | **확인함(일부 미지원)**. 동일 구성, `max_request_size=104857600`(바이트 정수). **게스트 knob 없음**(요청은 403으로 차단됨), **방 기본 암호화 knob 없음**. 주의: 첫 계정은 설정 파일 토큰이 **거부**(`M_FORBIDDEN Invalid registration token`)되고 stdout/로그에 평문으로 출력되는 자동 생성 토큰만 통과; 첫 사용자 생성 후에는 파일 토큰 정상 동작(실측) |
| **c. 자원(60초 유휴)** | RSS **153,872 KiB(150 MiB)**, 스레드 602. 테스트 후 176 MiB(HWM 338 MiB). DB 디렉터리: du 76M(WAL 선할당) / apparent 805K; 20 msg+120 MiB 미디어 후 143M | RSS **213,932 KiB(209 MiB)**, 스레드 75. 테스트 후 244 MiB(HWM 413 MiB). DB: du 75M / apparent 626K; 테스트 후 143M |
| **d. 클라이언트 API** | **확인함**. `.well-known/matrix/client` → 404 `M_NOT_FOUND`(기본; `[global.well_known] client=` 설정 시 제공). 토큰 없는 가입 401 flows=`m.login.registration_token`; 게스트 403 `M_GUEST_ACCESS_FORBIDDEN`; UIAA 토큰 가입 2명 OK; `createRoom(private_chat, m.room.encryption megolm)` OK, **암호화 미지정 private_chat도 자동 암호화**(knob 효과); join OK; 20 msg 20/20(0.02 s); `/sync` 양쪽 20/20; 30 MiB 업로드 0.13 s·90 MiB 0.38 s, 인증 다운로드(`/_matrix/client/v1/media/download`) 200 + sha256 일치; **비인증 legacy `/_matrix/media/v3/download` 403**; 120 MiB → 서버가 조기 종료(BrokenPipe), curl 확인 **413** | **확인함**. `.well-known/matrix/client` → 404("not configured to serve well-known client information"). 가입(dummy auth) 400 `M_INVALID_PARAM`/무인증 401 flows=token; 게스트 403; 토큰 가입 2명 OK; 암호화 방 OK; **암호화 미지정 private_chat은 비암호화(404)**; 20/20; sync 20/20; 30 MiB 0.09 s·90 MiB 0.42 s, 인증 다운로드 해시 일치; **비인증 legacy 다운로드 200(전체 바이트 제공)**; 120 MiB → 413 |
| **e. 백업·복원** | **확인함(내장 검증·복원)**. `!admin server backup-database` → "Done. Currently have 1 backups." / `list-backups` → `#1 … 1005087 bytes, 60 files` / `verify-backup` → "all files present". 복원: `kill -TERM` → `mv db db.pre-restore && mkdir db` → `./tuwunel -c tuwunel.toml --restore-backup --maintenance --execute "server shutdown"`(rc=0, **330 ms**, 로그 "Restored database backup backup_id=1") → 시작 → `/messages` **20/20, 원본 event_id 20/20 일치**, 비밀번호 로그인·기존 토큰 유효. 미디어는 백업에 없음(문서대로) → `cp -a db.pre-restore/media/. db/media/` 후 30/90 MiB 200 | **확인함(수동 복원)**. `!admin server backup-database` → done / `list-backups` → `#1 … 802109 bytes, 57 files`; verify 명령 없음. 복원은 문서(maintenance)의 수동 절차: `cp backups/shared_checksum/*.sst db/; mv ######_s*.sst → ######.sst; cp backups/private/1/* db/`(104 ms) + media 복사 → 시작 → `/messages` 20/20, event_id 20/20, 로그인 OK, 미디어 200 |
| **f. 재시작** | SIGTERM 정지 **37 ms / 25 ms**; 시작(exec→`/versions` 200) **236 ms**; 최초 빈 DB 시작 시 리스너 오픈 +350 ms | 정지 **38 ms / 26 ms**; 시작 **259 ms** |
| **g. 관리 표면** | **확인함(HTTP API + admin 방 + CLI)**. 첫 가입자=admin, `#admins:` 방(서버 계정은 `@conduit:`). `!admin users {create-user,deactivate,list-users,…}`, `!admin rooms list`(3방), `!admin media delete --mxc`(삭제 후 404). **Synapse Admin API** 실측: `GET /_synapse/admin/v1/rooms` 3방, `GET v2/users` 2명, 비관리자 토큰 403, `POST v1/deactivate/@evalc` 성공→로그인 `M_USER_DEACTIVATED`, `v2/users?deactivated=true` 필터 OK. `PUT v2/users/@evalc`(생성)는 **사용자는 생성·로그인 가능하나 `admin:false` 포함 시 500 `M_UNKNOWN`("was never an admin")** — 거친 부분. `registration_shared_secret`→`/_synapse/admin/v1/register`(문서, 미실측). `--execute`, `admin_execute`, `admin_signal_execute`(SIGUSR2), `--console` | **확인함(admin 방만)**. `/_synapse/admin/*` → 404 `M_UNRECOGNIZED`. `!admin users create evalc <pw>` OK(응답에 비밀번호 평문 회신), `!admin users deactivate` OK→`M_USER_DEACTIVATED`, `users list` 6명, `rooms list` 3방, `token list`(파일 토큰 표시), `media delete --mxc` OK(이후 400). `--execute`/`admin_execute`/SIGUSR2/`--console` 동일 |
| g. Python 스크립트성 | Bearer 토큰 + `requests` 한 줄. 구조화 JSON | Matrix 세션으로 admin 방에 메시지 보내고 회신 텍스트 파싱(`admin_cmd.py`로 구현, 회신 0.5~1 s). 가능하지만 텍스트 파싱 |
| **h. CF 터널 배치** | `ip_source="cf_connecting_ip"`(문서가 cloudflared 명시; 미설정 시 leftmost 헤더 스캔=위조 가능, 반드시 설정). `[global.well_known] client/server` 미설정 시 404 → 엣지/cloudflared가 제공하거나 설정. deb에 강화 systemd 유닛(ProtectSystem=strict, SystemCallFilter…)+AppArmor 프로필 동봉 | `accepted_ip_sources=["cf_connecting_ip"]`(문서: 연결 IP 신뢰 검사 없음 → 127.0.0.1 바인딩 필수). well-known 동일 knob. 비인증 미디어 제공이 켜져 있어 엣지 캐시/링크 유출 고려 필요 |

## 권고

**Tuwunel을 1순위로 확정**(결정문서 가정과 일치). 근거(실측):
1. **복원 드릴 품질** — 검증(`verify-backup`)·복원(`--restore-backup`, 330 ms, 설정 파일로는 거부되어 재실행 사고 방지)이 내장. continuwuity는 문서의 수동 `.sst` 이름 변경 절차이며 무결성 검증 명령이 없다.
2. **`admin.py` 연동** — Synapse Admin API(HTTP+Bearer)를 그대로 쓸 수 있어 계정 생성·비활성화·방·미디어 관리가 JSON으로 끝난다. continuwuity는 admin 방 텍스트 왕복이 유일한 경로.
3. **가족방 안전 기본값** — `encryption_enabled_by_default_for_room_type`(private_chat 자동 megolm 실측), 게스트 knob, **비인증 legacy 미디어 다운로드 403**. continuwuity는 셋 다 없음/열려 있음.
4. **자원** — 유휴 RSS 150 MiB vs 209 MiB, 정지 <40 ms·시작 <300 ms 양쪽 동급.
5. **운영 포장** — deb에 강화 systemd 유닛·AppArmor 동봉, 릴리스 노트에 마이그레이션·백업 경고가 명시적.

continuwuity는 **대안으로 유지 가능**: 기능은 모두 "확인함"이고 릴리스 주기가 더 짧다. 다만 첫 사용자 토큰이 로그에 평문 출력되고 파일 토큰이 첫 계정에 거부되는 동작, 수동 복원, HTTP 관리 API 부재가 우리 운영 방식(무인 스크립트)과 맞지 않는다.

## 열린 위험
- **공급망**: 두 프로젝트 모두 릴리스 체크섬·서명·attestation을 공개하지 않는다. 배포 시 다운로드 sha256을 저장소에 고정하고(위 값), Tuwunel은 deb↔zst 교차 일치를 반복 확인할 것.
- **Tuwunel `PUT /_synapse/admin/v2/users` 500**: 사용자는 생성되지만 응답이 500이라 `admin.py`가 실패로 오판할 수 있음(`admin` 필드 생략으로 회피 가능성, 미검증). 업스트림 이슈 확인 필요.
- **미디어는 온라인 백업 밖**(양쪽 공통): `db/media/` 별도 백업 필수. 복원 시 Tuwunel은 빈 `media/`를 먼저 만들어 단순 `cp -a src dst`가 건너뛰어짐(실측) — `cp -a src/. dst/` 형태로 스크립트화.
- **CF 업로드 한도**: `max_request_size` 100 MiB는 Cloudflare 무료/Pro 플랜의 요청 본문 한도(100 MB) 경계. 90 MiB는 로컬에서 통과했지만 터널 경유는 미검증.
- **미검증 항목**: `well_known.client` 실제 제공(404 기본만 확인), `registration_shared_secret` 경로, `--execute "users create-user"` 무인 생성, federation off의 외부 트래픽 부재(설정 수용만 확인), 장기 메모리·컴팩션, 두 포크 간 DB 마이그레이션(Tuwunel 1.9.1 노트에 conduwuit DB "adopt" 언급, 미실측).
- **Tuwunel 1.9.x 마이그레이션**: 1.8.x→1.9 첫 기동 시 리스너 오픈 전에 DB 마이그레이션 실행, 강제 kill 시 손상 가능(릴리스 노트) → 업그레이드 전 백업 자동화 필요.
- **서버 계정 이름** 양쪽 모두 `@conduit:<server>` — 가족 UI에서 표시명 처리 필요.
- 유휴 스레드 602개(Tuwunel)는 저사양 노드에서 재측정 필요. 본 측정은 12 vCPU/32 GiB 호스트 값.
