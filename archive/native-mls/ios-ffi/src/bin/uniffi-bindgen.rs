// `cargo run --features cli --bin uniffi-bindgen -- generate --library <cdylib> --language swift --out-dir <dir>`
// 바인딩 생성기는 이 크레이트와 같은 uniffi 핀을 쓴다(버전 불일치 방지).
fn main() {
    uniffi::uniffi_bindgen_main()
}
