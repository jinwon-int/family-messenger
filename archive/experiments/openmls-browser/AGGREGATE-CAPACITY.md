# Aggregate capacity: measured ceiling of the device-vault namespace

Status: **measured qualification (#49 fifth slice)**. The numbers below come
from `tests/native_aggregate_capacity.py` driving the real bundled store in a
persistent Chromium context with signed admissions on every write (the
admission-contract slice). They are measured facts about the CURRENT format,
not promises about future formats. Synthetic loopback only.

## Measured ceiling (current format, label version 3)

| Dimension | Ceiling | Measured |
| --- | --- | --- |
| Conversation records | 2 per namespace (hard) | 2 sealed |
| Record payload | 65,536 bytes each (hard) | 2 × 65,536 sealed |
| Plaintext ceiling | 128 KiB raw records | 131,072 bytes |
| Sealed envelope (cipher, rev 2 at ceiling) | — | 175,198 bytes (1.337× raw) |
| Seal revisions | 512 per namespace (hard) | all 512 exercised |
| Seal latency (steady state) | — | mean 8.7 ms, p95 9.6 ms (sampled 64) |
| First seal (KDF + keygen) | — | ≈ 2.6 s (scrypt-18 dominant), second seal ≈ 0.6 s |
| Worker linear memory (WASM) | 128 MiB budget | 4 MiB observed |
| Worker operational budget | 256 writes per worker lifetime | restarts at the boundary are part of normal use |

## What the numbers mean

- **The plaintext ceiling is 128 KiB per namespace.** Growing beyond two
  records or 64 KiB per record is a format change: the envelope's
  `rooms`/`pins`/`records` shapes, the store's `ROOMS`/`RECORD` constants and
  the admission `rooms` grant all encode the current ceiling.
- **Seal cost is dominated by re-encrypting the whole aggregate**: one write
  re-seals everything (TAG-FINAL contract), so steady-state cost grows with
  the aggregate size, not the delta. At the current ceiling that is ~9 ms per
  revision — comfortable, but linear growth means a 10× ceiling needs an
  incremental or segmented seal design first.
- **512 revisions is the namespace's write budget.** At ~9 ms per seal the
  full budget costs ≈ 5 s of sealing over the namespace lifetime; the cap is
  enforced state-invariantly (a 513th admission is refused and the record
  stays untouched).
- **The first unlock after namespace creation carries the scrypt-18 KDF**
  (~2.6 s in this probe); subsequent operations reuse the unlocked root.

## Re-measuring

```sh
python tests/native_aggregate_capacity.py --synthetic-only --seal-sample 64
```

The receipt lands under `artifacts/aggregate-capacity-*/verification.json`
with the per-check booleans, the sampled seal latencies and the observed
worker linear memory. CI runs the same harness.
