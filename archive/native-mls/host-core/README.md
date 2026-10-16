# native-mls-host — 호스트 중립 Rust 코어 (#366)

봇(`archive/native-mls/bot`, 공명 서비스 `native-relay-bot`)과 Android 앱(#338, uniffi Kotlin)이 **같은 구현**을 쓰도록
봇 크레이트에서 분리한 모듈. iOS는 #271 동결 계약(순수 Swift `FamilyMLSCore`)이라 대상이 아니다.

| 모듈 | 내용 | 출처 |
|---|---|---|
| `api` | v2 릴레이 타입 클라이언트·와이어 타입(`server.go` json 태그 그대로). 오류 타입 `RelayError`(봇은 `BotError` 별칭으로 사용) | `bot/src/api.rs` |
| `http` | `TcpStream` 위 최소 HTTP/1.1(평문 — 봇은 tailnet으로 릴레이 접속). 공용 인터넷용 TLS 전송은 아직 없음(Android 착수 시 별도) | `bot/src/http.rs` |
| `b64` | 릴레이 바이트 필드용 표준 base64 | `bot/src/b64.rs` |
| `policy` | 클라이언트 commit 정책(#263). 벡터 `archive/native-mls/tests/fixtures/commit-policy-vectors.json` 공유 | `bot/src/policy.rs` |

- 이동은 **동작 무변경**: 코드 본문 동일, `BotError` → `RelayError` 이름만 변경. 테스트 10개도 그대로 이동(api 3·b64 2·http 3·policy 2).
- 의존성은 봇과 같은 정확 핀(`serde =1.0.229`·`serde_json =1.0.151`·`sha2 =0.10.9`), `Cargo.lock` 항목은 전부 봇 잠금 파일에 이미 있던 버전.
- 이 크레이트는 MLS 파사드를 링크하지 않는다: 호스트가 파사드 출력(프레이밍된 바이트·stage 보고서)을 넘긴다.

```bash
cargo +1.91.1 test --locked          # 10 tests
```
CI: `.github/workflows/native-mls.yml` `native-mls-bot` job(경로 필터에 `archive/native-mls/host-core/` 포함).
