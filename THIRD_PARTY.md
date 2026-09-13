# 구성요소와 출처

직접 작성한 코드·문서는 루트 [MIT License](LICENSE)를 따릅니다.
이 라이선스는 외부 코드·패키지·컨테이너·고지의 기존 라이선스를 변경하지 않습니다.

| 구성요소 | 출처 | 라이선스 |
|---|---|---|
| Synapse 1.160.0 | https://github.com/element-hq/synapse | AGPL-3.0 (해당 릴리스 원문 기준) |
| Element Web 1.12.27 | https://github.com/element-hq/element-web | AGPL-3.0 (해당 릴리스 원문 기준) |
| PostgreSQL 17 | https://www.postgresql.org/about/licence/ | PostgreSQL License |

이 저장소는 upstream 서버/클라이언트 소스를 복사하지 않고 공개 이미지를 버전/digest로 참조합니다.
직접 작성한 부분은 배포 설정, 초기화·계정 도구, 테스트, 가족용 HTML/SVG와 문서입니다.
Upstream의 라이선스·저작권 표시를 유지하며, 향후 해당 소스를 수정·배포할 때는 원래 라이선스의 소스 제공 등 의무를 적용합니다.
각 이미지에 포함된 다른 구성요소는 해당 이미지의 원래 고지와 라이선스를 따릅니다.

## Native prototype

`server/go.mod` and `server/go.sum` pin `github.com/mattn/go-sqlite3` v1.14.52
(MIT), including the SQLite amalgamation (public domain). The driver is linked
through cgo; Go standard library/toolchain (BSD) and the host libc/loader remain
dependencies. No Tinode, ntfy or Gotify code/assets were copied. See
[server/README.md](server/README.md) for the runtime/build inventory and limits.

## 암호화·브라우저 실험

OpenMLS/Rust 의존성의 버전·출처·라이선스는
`archive/experiments/openmls-browser/dependencies.json`과 `THIRD-PARTY-NOTICES.txt`,
`RUST-STDLIB-NOTICES.html`을 따릅니다. 기기 보관 실험의 age·libsodium 및 번들 의존성은
`archive/experiments/device-keystore/THIRD-PARTY-NOTICES.txt`, `SODIUM-NOTICES.txt`와 잠금 파일을 따릅니다.
생성된 WASM·브라우저 번들·서버 바이너리를 배포할 때에도 포함된 외부 라이선스와 고지를 유지해야 합니다.
