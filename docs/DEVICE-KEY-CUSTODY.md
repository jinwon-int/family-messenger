# Device key custody and recovery decision

Status: **candidate feasibility and integration design, not human-use activation**.
Keep the current messenger synthetic-only. A browser file-encryption roundtrip
cannot make its unprotected MLS provider/receipt snapshots suitable for family
keys. We have a concrete maintained candidate for explicit passkey-protected
archives, but do **not** select a drop-in live keystore implementation yet.

## Decision and candidates

Retain OpenMLS for messages. Keep all signing keys, group secrets, pending
commits, exact outbox bytes, cursors and cached plaintext under one durable
worker-state boundary. Do not replace messaging crypto with file encryption.
Do not move human provider snapshots through page code to make an experiment work.

| Candidate | What it supplies | Decision / remaining boundary |
|---|---|---|
| `age-encryption` 0.3.1 (typage), including its WebAuthn PRF recipient/identity | Maintained age file container, complete file authentication, standard passkey PRF integration with required user verification; upstream owns derivation/wrapping, not our code | Test as an **isolated archive/key-vault candidate**. Direct file operations call `navigator.credentials` in Window and require confirmation each time. Not a worker-only live storage adapter; no anti-rollback or actor/room authorization |
| libsodium `secretstream` | High-level authenticated stream with library-managed nonce/header/rekeying and final-tag verification | Suitable primitive/library to evaluate for record protection, but it does not supply device unlock, recovery, a keystore file format or app transaction semantics. No ad-hoc PRF/KDF/wrapping construction added in this unit |
| Android Keystore | Platform key-use authorization and non-exportable keys, optionally hardware-bound | Strong future native-app custody boundary. Requires an actual native bridge, hardware capability checks and lifecycle/recovery qualification. A web page/WebView does not automatically obtain this boundary; no SDK/NDK installation in this unit |
| Persisted non-extractable WebCrypto `CryptoKey` alone | Prevents direct key export through that API | Insufficient unlock/recovery boundary by itself: same-origin code can use a stored key, and browser-profile portability/OS protection is not guaranteed by `extractable:false`. Not selected as a human vault |

An Android hardware-backed wrapping key would not keep every OpenMLS provider
secret in hardware: unlocked provider state still needs application memory.
A native custody boundary must be designed and tested rather than inferred from
the presence of a Keystore API.

The candidate is pinned at upstream commit
`38b8b10cb22409de0eaa8a617a01f16dc2e3f9f4`, matching npm 0.3.1's `gitHead` and
lockfile integrity. The package declares BSD-3-Clause; its Noble/Scure dependencies
have MIT notices. It is referenced by the age author's implementation and primary
WebAuthn article. Bounded primary-source research did **not establish a complete
independent audit of this exact typage/WebAuthn stack**. Noble's historical audits
must not be presented as an audit of every current dependency or our integration.
The distributed `createCredential`, `WebAuthnRecipient` and `WebAuthnIdentity`
types are explicitly marked **`@experimental`** by upstream. This probe qualifies
those maintained library contracts only; it does not make that experimental API
a production-audited or stable keystore interface.

## Concrete blockers before a live adapter

1. **Custody and invocation.** WebAuthn credentials APIs are Window-exposed. The
   tested secure-context worker has no `navigator.credentials`. Typage's public
   WebAuthn classes invoke that API and derive/unpack file keys in their calling
   context. Directly decrypting an MLS snapshot in Window would violate our
   worker-only provider/key boundary. A separate, independently reviewed platform
   or library custody mechanism is required; a hand-written navigator proxy or
   raw-key handoff is not approved by this design. The probe uses unrelated dummy
   file bytes in Window and never imports an MLS provider.
2. **Per-operation authorization and transactions.** Direct WebAuthn file
   encryption/decryption needs user confirmation each time. The current worker
   persists every application/control operation. Holding an IndexedDB transaction
   across that prompt or asynchronous encryption is invalid. Caching a new secret
   or replacing this with custom key wrapping is not an implicit implementation
   choice. Qualify the library's unlock/session boundary and cancellation first.
3. **Authenticity and rollback.** age authenticates file integrity, but does not
   provide a monotonic record witness. Our proof successfully decrypts an older
   complete valid ciphertext. Public-recipient file encryption also does not
   authenticate who created a new encrypted record: do not treat anyone's ability
   to encrypt to a public recipient as trusted device-state authorship. Existing
   unkeyed state checksums are corruption checks only. An external monotonic
   witness is still needed for trustworthy active-state restore after whole-profile
   rollback; a malicious/rolled-back delivery service is not that witness.
4. **Real device acceptance.** Virtual authenticators emulate PRF/verification;
   they do not qualify biometric prompts, hardware extraction resistance, passkey
   provider sync, Android WebView support, background suspension or OS backups.
   A further optional virtual UV-failure/re-enable probe failed to reopen with
   `NotAllowedError` in the local browser. Independent raw WebAuthn calls also
   fail afterward, including non-PRF requests: this narrows it to browser/virtual
   authenticator request state, not demonstrated file-decryption damage. The exact
   cause remains unestablished; artifacts are retained and normal PRF success is
   not called lock/unlock recovery acceptance. Actual hardware and cancellation/lifecycle tests remain.

These blockers stop human-use keystore activation, not repository implementation
or independent review of this design. No existing profile is rewritten, reset,
re-keyed, silently trusted or interpreted as a new empty device.

## Required state machine for the subsequent implementation

States distinguish `locked`, `unlocking`, `open`, `unavailable`, `corrupt`,
`revoked`, and `recovery-required`. A missing PRF result, authenticator cancellation,
failed verification, unavailable credential or deadline does not mean a new device
should be created. Existing ciphertext/credential hints and recovery evidence stay
intact. Corrupt/unknown schema remains denied. Server/device revocation is a
separate authorization result even if the local file can still decrypt.

Before requesting unlock, bootstrap the signed principal and exact room/device
binding; an independently accepted first-device fingerprint remains necessary.
CF admission never selects a new decrypting key or grants room/fleet authority.
Pin the exact credential/RP identity rather than relying on a discoverable chooser
that could pick a login passkey. Credential IDs/RP hints may be stored as bounded
metadata; they are not app actor enrollment or proof of MLS signing-key ownership.
A synced passkey may be available on several devices, so passkey equality must not
silently mean that those devices share an active MLS leaf.

On unlock completion, recheck the current principal/device/pins, stored revision
and view generation before accepting any result. Late callbacks after lock, page
hide, account/room change or cancellation cannot reopen or publish plaintext.
Terminate the worker on lock and clear page views/Blob URLs. Do not promise physical
zeroization of JavaScript strings or browser memory. Locked clients may stage
bounded opaque inbound traffic, but cannot decrypt, acknowledge completed receive
or execute an AI task. No offline send bypass of fresh policy/epoch checks.

For asynchronous protection, the implementation needs a checked candidate/CAS
pattern, not `await` inside a live IndexedDB transaction:

1. Read the latest recognized protected record with its immutable revision; obtain
   fresh authorization outside the transaction. Unprotect/validate the full record
   through the accepted custody API, outside any IDB transaction.
2. Reconstruct a complete isolated OpenMLS provider. Produce a candidate including
   signing/provider state, accepted pins, exact immutable outbox, cached results,
   native cursor and control phase. Protect the **whole** record with a bounded,
   versioned codec; no plaintext ledger/cache alongside an encrypted signer.
3. In a strict read/write transaction, compare the exact prior protected record
   and revision again and atomically write the complete protected candidate and
   its matching metadata. No network, prompt or asynchronous crypto wait occurs
   inside that transaction. If another tab committed first, discard the candidate
   and release nothing; do not reuse its mutated provider or silently retry encryption.
4. Only transaction completion permits ciphertext release, self-echo completion
   or plaintext display. A crash/lost reply reopens the committed exact outbox.
   Preserve ordered native CAS/ack, old-epoch inbound processing before own commit
   merge, actual OpenMLS sender/AAD/inner-frame validation and stale-outbox freeze.

Cross-tab tests must cover concurrent unlock, lock propagation, competing
candidate writes, account switch during a prompt, abort before/after write,
response loss and process kill. Application revisions protect cooperating tabs;
they do not solve whole-valid-store rollback after restart.

## Recovery and device lifecycle

Recovery has two distinct products; neither is implemented by an age roundtrip.

- **Read-only history recovery:** an explicitly exported, complete encrypted archive
  may restore past readable history after independent key/identity verification.
  It must not import historical ratchets/outbox into an active sender. Treat its
  plaintext as sensitive and keep it outside executing fleet rooms/commands.
- **Continuing conversations after device loss:** freeze/revoke the old device;
  enroll a new immutable device/signing key using a vetted same-actor trusted-device
  approval or explicit out-of-band recovery ceremony when every device is lost.
  Re-verify peer pins and establish new group epochs/rooms as required by OpenMLS.
  Never clone a backed-up active leaf or replay an old outbox as a new sender.

Additional/replacement devices stay denied under the current one-device policy
until that approval/removal/re-enrollment implementation is independently reviewed.
Do not erase tombstones to reuse a revoked ID. Family room membership and owner-only
execution/approval/cancel authority remain separate. Recovery does not add bots to
family rooms, grant owner authority or move any of the 12 nodes' original credentials.

A server backup contains only public enrollment/policy and opaque messages/media;
it cannot reconstruct missing user keys. A private archive may contain recoverable
history keys and therefore changes the confidentiality exposure of old messages:
its retention/location/recovery factors must be explicit. Passkey-provider sync is
not an independent backup acceptance test. A recovery secret must not travel in the
same backup, server directory, logs, URLs or CI artifacts. Key/credential loss must
have an honest unavailable result, not a plaintext fallback.

## Evidence and next implementation boundary

[The runnable probe](../experiments/device-keystore/README.md) tests a real pinned
library through two disposable Chromium principals and a no-PRF authenticator.
It proves generated byte encryption/decryption, different-key and tamper/truncation
rejection, reload of encrypted bytes/public hints, wrong RP rejection, no PRF fallback,
and the two concrete worker/rollback limitations. No human credential is created,
exported or loaded; CDP virtual authenticator keys never enter proof JSON.

Proceed next with a narrowly reviewed **worker-only unlock feasibility prototype**
that satisfies the Window/worker and prompt/session boundaries above. A standard
password-encrypted age archive decoded entirely in a worker is a separate
candidate worth measuring: the password is transient user input, never an MLS
key/provider returned to the page. Keep the library default password work factor
and measure memory/latency before selection; do not weaken it to pass a budget.
It would still need a reviewed per-record protection/session mechanism, complete
state CAS, recovery policy and same-origin compromise qualifications. No password
or recovery secret should be persisted in the page, server, logs or URLs. If browser APIs
cannot preserve those requirements, document the exact native keystore boundary
needed before shipping an Android client; do not quietly weaken key custody or
claim actual CF/mobile/Yukson acceptance. The existing synthetic messenger remains
runnable while this prerequisite is resolved. Full-size encrypted media and all12
real-runtime integration remain tracked separately in #16/#10/CCC1602.

A subsequent [worker password archive proof](../experiments/device-keystore/PASSWORD-WORKER.md)
confirms worker-only file APIs, bounded default-work admission, lock termination
and clean browser restart using generated bytes. The roughly two-second/default
256 MiB KDF per file leaves live per-record session protection and mobile resource
acceptance unresolved. No live keystore was selected or existing profile migrated.

## Primary sources consulted 2026-09-09

- [WebAuthn Level 3 Recommendation, 2026-08-25, PRF extension](https://www.w3.org/TR/2026/REC-webauthn-3-20260825/#prf-extension): outputs are credential-scoped PRF results; API exposure and extension support are separate from app authentication policy.
- [MDN WebAuthn extensions](https://developer.mozilla.org/en-US/docs/Web/API/Web_Authentication_API/WebAuthn_extensions#prf): browser/platform support varies; no-PRF output is not a success key. Compatibility tables do not qualify a user's authenticator.
- [Pinned typage README](https://github.com/FiloSottile/typage/blob/38b8b10cb22409de0eaa8a617a01f16dc2e3f9f4/README.md) and [WebAuthn source](https://github.com/FiloSottile/typage/blob/38b8b10cb22409de0eaa8a617a01f16dc2e3f9f4/lib/webauthn.ts): explicit credential hint, required user verification, per-operation confirmation, `navigator.credentials` calls and library-owned wrapping.
- [Age author's passkey design explanation](https://words.filippo.io/passkey-encryption/) and [age file specification](https://age-encryption.org/v1): file container/recipient contracts, not a device-state rollback service.
- [libsodium secretstream](https://doc.libsodium.org/secret-key_cryptography/secretstream): authenticated chunks/final tag and nonce/rekey management, not a complete keystore or enrollment system.
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore): non-exportable key use and optional hardware binding; hardware must support the selected algorithms and be checked.
