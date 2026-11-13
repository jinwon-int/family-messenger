# Termux(aarch64 Android) 노드에 봇 설치 (#492 ②)

systemd 노드는 `install-node-bot.sh`(root), Termux 노드는 `install-node-bot-termux.sh`(Termux 사용자)를 쓴다.
Termux에는 systemd와 root가 없으므로 봇은 runit 서비스, JWT 갱신은 crontab이고, 봇과 한데 브리지(ccc-node
`install-hande-bridge-termux.sh`)가 같은 uid라 응답기 소켓은 0600 그대로 쓴다.

## 1. 바이너리 — `aarch64-unknown-linux-musl` 정적 빌드

봇은 TLS·C 의존성이 없어 musl 정적 빌드가 Android에서 그대로 돈다(동적 링커 없음).

- **CI 산출물**: `Native MLS track` 워크플로의 `native-mls-bot` job이 봇 관련 변경마다
  `native-mls-bot-aarch64-unknown-linux-musl-<sha>` 아티팩트(바이너리 + `native-mls-bot.sha256`, 14일)를 올린다.
  릴리스가 아니다 — 배포 전 sha256을 확인한다.
- **직접 빌드**(크로스 C 툴체인 불필요, 링커는 고정 툴체인의 `rust-lld`):

  ```bash
  rustup +1.91.1 target add aarch64-unknown-linux-musl
  cd archive/native-mls/bot
  CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
    cargo +1.91.1 build --release --locked --target aarch64-unknown-linux-musl --bin native-mls-bot
  # → target/aarch64-unknown-linux-musl/release/native-mls-bot (ELF64 aarch64, PT_INTERP 없음)
  ```

## 2. 설치

선행: CF Access 서비스 토큰 env `~/.config/native-relay/bot-service-token.env`(0600,
`CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET`) — 값은 어디에도 출력·기록하지 않는다.

```bash
bash install-node-bot-termux.sh --node <node> \
  --relay-url http://<릴레이 tailnet>:18921 --relay-public-url https://<릴레이 호스트> \
  --binary ./native-mls-bot [--attachments [--caption-secs N]] [--no-start] [--dry-run]
```

| 만드는 것 | 위치 |
|---|---|
| 상태·바이너리·로그 | `~/.native-relay-bot/{bin,bot,rooms,logs}` 0700 (`--attachments`면 `attachments/`) |
| JWT 갱신 | `bin/jwt-refresh.sh` + crontab `17 */12 * * *` (중복 추가 안 함) |
| 릴레이 주소 | `$PREFIX/etc/native-relay/bot-relay.env` (`NATIVE_RELAY_URL`, 비밀 없음) — **없을 때만** 만든다. 있으면 유지하고, 다른 `--relay-url`은 거부 → 바꾸기는 `native-relay-repoint`(#699, #702) |
| 신원 | `bot/identity.json` 0600 — `install-node-bot.sh`와 같은 부트스트랩(8초 `session` → `extract-identity` → state 파기), 있으면 유지 |
| 서비스 | `$SVDIR/native-relay-bot/{run,finish,log/run}` — 바뀐 `run`은 `run.bak-492-<UTC>`로 먼저 백업, `--no-start`면 `down` |
| 등록 후보 | `bot/enrollment.json` 0600 `{actor, device_id, signing_key, subject}` |

**설치 순서와 무관하게 등록 후보가 써진다.** 공개키는 `native-mls-bot identity-public-key <node>-bot
--identity-file …`(#492 ①)로 오프라인 계산하므로 응답기 소켓(브리지)이 아직 없어도 된다. 이 서브커맨드가 없는
구 바이너리면 svlogd `logs/current`의 `steward_ready` 줄로 폴백하고, 그것도 없으면 실패로 끝난다(바이너리를
올리거나 봇을 띄운 뒤 다시 실행). `enrollment.json`은 릴레이 호스트로 옮겨 `native-devices -enroll-first`에
넣는다(운영자, 승인). 등록 전 봇은 403을 받으며 재시도한다(정상).

다시 실행해도 안전하다: `--binary`·`--relay-url` 없이 돌리면 기존 바이너리·env·신원·cron을 그대로 쓰고
`run`·`enrollment.json`만 다시 쓴다. 단, 첨부를 켠 노드는 `--attachments`(와 `--caption-secs`)를 같이 줘야
`run`에서 첨부 env가 빠지지 않는다(빠지면 백업이 남는다).

되돌리기: `SVDIR=$PREFIX/var/service sv down native-relay-bot; rm -rf $PREFIX/var/service/native-relay-bot`,
crontab의 `jwt-refresh.sh` 줄 삭제. `~/.native-relay-bot`(신원)은 남긴다.

## 3. 테스트

`install-node-bot-termux.test.sh` — 리눅스에서 가짜 `PREFIX`/`HOME`, stub 봇(구 바이너리 모드 포함)·curl·
crontab·sv로 돌린다. CI `native-mls-bot` job이 봇 관련 변경마다 실행한다.
