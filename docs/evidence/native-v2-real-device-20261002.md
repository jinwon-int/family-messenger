# #177 M4 실기기 증거 — 2026-10-02 (Firefox · Safari iOS · Android Chrome)

- 증거: `native-v2-real-device-20261002.json` (`real-device-evidence:v1`)
- 스켈레톤(서버 관측 원본, 바이트 불변): `native-v2-real-device-20261002-skeleton.json` — sha256 `8967ebe666e744fc…` (`session_log_sha256`과 동일)
- 키트 커밋: `dedeaf75a1f110830084de6c0b3f21c627130dde` · 번들: main `dedeaf7`을 핀 툴체인(rustc 1.91.1 · wasm-bindgen 0.2.126 · esbuild 0.27.2)으로 빌드, `bundle-sha256.txt` 일치(wasm `03fb77d7…` · js `32259cee…` · custody `b94b2180…`)

재검증:

```bash
python3 archive/native-mls/tests/real_device_kit.py validate \
  docs/evidence/native-v2-real-device-20261002.json \
  --skeleton docs/evidence/native-v2-real-device-20261002-skeleton.json
```

| 기기 | 실행 | 백그라운드 복귀 | 축출 재참여 |
|---|---|---|---|
| Firefox 153 | 공명(x86_64 베어메탈) Xvfb 창 모드, Playwright 자동화 | 탭 전환 30s → 해독 ✓ | ✓ 새 지문·재초대·재참여 |
| Android Chrome 149 | 공융 SM-G781N(Android 13) 물리 기기, adb DevTools 원격 조작 | 홈 이탈 34s → 해독 ✓ | ✓ |
| Safari iOS 18.7 | 오너 iPhone 15 Pro, 손으로 수행 | 홈 이탈 30s → 해독 ✓ | ✓ 2026-10-02 23:32~23:45 KST 별도 세션 — [native-v2-safari-eviction-20261002.md](native-v2-safari-eviction-20261002.md) |

진술(attestation)은 증거 JSON 본문에 있다. REAL-DEVICE.md §5대로 검증기는 실기기 여부를 증명하지 않으며, **Firefox·Android는 사람 손이 아닌 원격 자동화 조작**이었음을 진술에 그대로 적었다. UA 변조·에뮬레이터·headless 모드는 쓰지 않았다.
