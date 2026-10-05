# ios-ffi — 파사드의 세 번째 호스트 (스파이크 A, #271 §3·§12-A)

> **상태: 스파이크.** 브라우저(WASM 워커)·봇(native Rust)에 이어 **iOS(Swift)** 가 같은 OpenMLS 파사드
> `archive/experiments/openmls-browser` 를 링크할 수 있는지, 그 비용(빌드 시간·바이너리 크기)은 얼마인지를 잰다.
> 설계 전문 [#271](https://github.com/jinwon-int/family-messenger/issues/271), 독자 트랙 설계 [#177](https://github.com/jinwon-int/family-messenger/issues/177).

## 무엇이 들어 있나

| 파일 | 역할 |
|---|---|
| `src/lib.rs` | `MlsDevice` 객체(uniffi): `new / import_state / export_state / public_key / fingerprint / dispatch(method, bytes)`. **MLS 로직 0줄** — 와이어 프레이밍·AAD·commit 검사·record 코덱은 전부 파사드 |
| `tests/host_roundtrip.rs` | 봇 `tests/native_facade_link.rs` 의 두 시나리오를 FFI 객체로 반복 + 거부 시 스냅샷 롤백 검사 (host, `cargo test`) |
| `build-xcframework.sh` | macOS: iOS 기기·시뮬레이터 staticlib → `FamilyMLS.xcframework` + Swift 바인딩 + sha256 목록 |
| `uniffi.toml` | Swift 모듈명 `FamilyMLS` / FFI 모듈 `FamilyMLSFFI` |
| `src/bin/uniffi-bindgen.rs` | 바인딩 생성기(같은 uniffi 핀) — `--features cli` |

호스트 계약(봇과 동일): 연산 전 `export_state` 스냅샷 → 파사드 거부 시 스냅샷으로 복원. **영속·봉인·잠금은 호스트(Swift) 책임**이다 — #271 §4(App Group + Data Protection + Keychain 봉인 키, App↔NSE `flock`). 이 크레이트는 디스크·네트워크·키체인을 모른다.

## 빌드·검증

```bash
# Linux/macOS 공통 — host 게이트
cargo +1.91.1 test --locked
# Linux 에서도 가능한 1차 신호 — iOS 타겟으로 타입체크(링크 없음)
cargo +1.91.1 check --locked --lib --target aarch64-apple-ios
# macOS — xcframework + Swift 바인딩
./build-xcframework.sh          # → out/FamilyMLS.xcframework, out/swift/FamilyMLS.swift, out/xcframework-sha256.txt
```

CI: `.github/workflows/native-mls-ios.yml` (ubuntu host 게이트 ≤15분 · macOS 빌드 ≤25분, `archive/native-mls/ios-ffi/**`·`archive/native-mls/ios/**` 경로 필터). 예산 규칙은 결정 E 규칙 2.

## 의존성 (#177 원칙 5)

| 크레이트 | 핀 | 라이선스 | 왜 |
|---|---|---|---|
| `family-mls-browser-experiment` | path | 레포 | 파사드(세 호스트 공용) |
| `uniffi` | `=0.32.2` | MPL-2.0 (미수정 사용) | Rust↔Swift 바인딩 생성. 대안 = 수동 `extern "C"` + Swift 래퍼(의존 0, 바이트 버퍼·오류 전달을 손으로). 스파이크 결과(크기·빌드 시간)로 택한다 — #271 §3 |
| `sha2` | `=0.10.9` | MIT/Apache-2.0 | 지문 = sha256(공개키) (DEVICES-V4). 파사드 그래프에 이미 있는 핀 |

전체 전이 라이선스 고지(`THIRD-PARTY-NOTICES.txt`)·`dependencies.json` 은 **스파이크 통과 뒤** 파사드와 같은 형식으로 생성한다(여기서는 `Cargo.lock` 만 커밋).

## 증명하지 않는 것

- 정책 메서드 4개(`members`·`members_after_pending`·`policy_fingerprint`·`sign_approval`)는 #275 L2 에서 `dispatch` 에 더했다. 바이트 규칙은 파사드 `policy_wire`(durable lane `Session::dispatch` 와 같은 함수)가 소유한다. `tests/policy_wire.rs` 는 승인 서명을 고정 벡터 `../tests/fixtures/ios-ffi-approval-vector.json`(합성 키, 테스트 전용)과 바이트 단위로 비교하고, Go `server/cmd/native-devices/approval_vector_test.go` 가 같은 벡터를 `-add-device` 로 수락하는지 검사한다. 재생성: `FM_REGEN_APPROVAL_VECTOR=1 cargo +1.91.1 test --locked --test policy_wire`.
- durable lane `Session` 의 HMAC record 체인·store 는 노출하지 않는다(영속은 호스트 몫, #271 §12-B).
- 실제 iOS 앱에서 승인 화면 → CLI 까지의 사람 경로(L3·파이널라이저 범위).
- iOS 기기에서의 **실행**(시뮬레이터 단위시험까지만 CI). upstream OpenMLS 는 iOS 를 "built, not tested in CI" 로 표기한다.
- 프로세스 간 단일 작성자·원자 영속·NSE 예산 — #271 §12-B/D.
- 릴레이 통신·CF Access·푸시 — #271 §12-C/D.
