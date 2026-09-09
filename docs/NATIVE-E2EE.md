# Native E2EE feasibility and integration decision

Status: **reviewable design, not implemented E2EE**. Evidence checked 2026-09-09.
Tracking: [family #16](https://github.com/jinwon-int/family-messenger/issues/16).

## Decision

Use RFC 9420 MLS as the first protocol to qualify, with **OpenMLS 0.9.0 as
an isolated experiment candidate**, not yet an approved production dependency.
Keep our Go delivery service, SQLite storage and own browser UI. Reusing a
maintained messaging cryptography library fits the owned-system requirement;
implementing a new ratchet, key schedule or WebCrypto message cipher does not.
Do not adopt an upstream messenger, copy its application code, or activate Matrix.

The next unit is a pinned, disposable OpenMLS browser feasibility experiment.
A native Rust roundtrip alone cannot qualify our browser product. If the exact
provider/features cannot build and run safely in a browser, record that failure
and reconsider the candidate; do not switch to plaintext or a homemade cipher.
This unit deliberately installs no crypto library and runs no encrypt/decrypt
proof. It completes the protocol choice, evidence inventory, application boundary
and executable-experiment acceptance plan before adding a Rust/WASM build surface.
Human use continues to require E2EE; the unanswered preference is not approval
for plaintext. All existing synthetic data, service configuration and backups stay
in their current formats.

## Candidate comparison and source quality

| Candidate | Primary evidence | Fit and decision |
| --- | --- | --- |
| OpenMLS | RFC 9420 implementation; MIT; active 0.9.0 release published 2026-08-25. SRLabs assessment available. Upstream explicitly lists WASM, Android and iOS as **unsupported, built but not tested in CI**. | First experimental candidate: transport-independent groups and independent core audit. Browser/provider and durable-state qualification remain blocking. |
| AWS mls-rs | Maintained source manifest 0.56.0; Apache-2.0 OR MIT; WASM support and configurable storage. Official security notice says no full third-party security audit yet. Web Crypto provider is experimental. | Reserve candidate if OpenMLS browser/provider qualification fails. RFC conformance and WASM support do not remove the audit/provider acceptance gap. |
| Signal libsignal | Official clients use Rust behind Java, Swift and TypeScript bindings. Node package 0.102.0 at inspected source, AGPL-3.0-only. README says outside-Signal use is unsupported and APIs can change. Node package ships native `.node` bindings. | Strong deployed protocol lineage, but its TypeScript surface is not a browser build. Native bridge/toolchain and licensing obligations make it a poorer fit for this browser-first minimal stack. No claim that AGPL forbids use. |

Pinned source and manifest observations are in
[evidence/e2ee-feasibility-20260909.json](evidence/e2ee-feasibility-20260909.json).
OpenMLS tag resolves to `3a3e35de3feeca8f6605143c464d5452ae584d43`.
The mls-rs version is a source-manifest observation: GitHub's latest-release
endpoint returned 404, so it is not presented as a verified published release.
Signal's source/package version likewise is not an npm distribution verification.

Primary references:

- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html), especially sections 3,
  12, 15 and 16: groups/epochs, application messages, authentication and delivery
  service assumptions, replay/compromise and metadata limits. MLS assumes a
  trusted authentication service and a largely untrusted delivery service.
- [OpenMLS pinned README](https://github.com/openmls/openmls/blob/3a3e35de3feeca8f6605143c464d5452ae584d43/README.md)
  and [WASM instructions](https://github.com/openmls/openmls/blob/3a3e35de3feeca8f6605143c464d5452ae584d43/book/src/user_manual/wasm.md):
  `js` feature, secure randomness/time from the host, supported-target caveat.
- [OpenMLS 0.9.0 release](https://github.com/openmls/openmls/releases/tag/openmls-v0.9.0):
  Rust 1.91 minimum; changed storage representation and explicit migration
  support. Latest release is not the same as the audited revision.
- [Maintainer audit announcement](https://blog.phnx.im/openmls-independent-security-audit/)
  and [complete SRLabs assessment, v1.2, 2026-03-11](https://blog.openmls.tech/SRL-OpenMLS_security_assurance_assessment.pdf).
  The report scopes the core, traits and basic credentials; crypto/storage
  providers and example client/delivery service were outside its review scope.
  Its detailed findings include acknowledged state/storage divergence and
  accepted allocation risk. We do not label the whole proposed browser stack
  audited, or the later 0.9.0 release free of findings. The announcement's broad
  remediation summary does not replace the detailed scope/status table.
- [mls-rs project/security notice](https://awslabs.github.io/mls-rs/),
  [pinned manifest](https://github.com/awslabs/mls-rs/blob/8f1b43f447a792ff9307f1c2c7f54da63914870e/mls-rs/Cargo.toml).
- [Signal pinned README](https://github.com/signalapp/libsignal/blob/b3f7ecc2f6c5b5246fa9d24b891579f17fa47893/README.md)
  and [Node manifest](https://github.com/signalapp/libsignal/blob/b3f7ecc2f6c5b5246fa9d24b891579f17fa47893/node/package.json).

## Dependency and resource budget

The installed native runtime remains two direct Go modules, zero transitive Go
modules: jwt/v5 5.3.1 and sqlite3 1.14.52, both MIT. Go/cgo/GCC/libc remain;
there is no new server service, JS framework, npm runtime or crypto package.
Local preflight found about 77 GiB available, Node 22.22.2/npm 10.9.7 and no
Rust/cargo/wasm-pack on PATH. No large toolchain install was performed.

The candidate experiment would directly use `openmls = 0.9.0`,
`openmls_rust_crypto = 0.6.0`, `openmls_basic_credential = 0.6.0` and
`tls_codec` for wire serialization, with matching `wasm-bindgen` glue/tooling.
Traits or storage crates become additional direct dependencies if the wrapper
imports them. The receipt inventories their upstream manifests, features and
hashes; this is a proposed surface, **not a resolved application lockfile**.
The selected OpenMLS helper crates declare MIT. Full transitive licenses must
be resolved and notices retained before distributing the experiment bundle.

The RustCrypto provider includes AES-GCM, ChaCha20Poly1305, SHA/HMAC/HKDF,
Ed25519, P-256/P-384, randomness, HPKE and ML-DSA dependencies even though our
first profile only needs the RFC mandatory suite. Its HPKE declarations enable
`experimental`; that needs an exact feature/algorithm and advisory assessment,
not an assumption that unused algorithms disappear. Do not enable draft MLS/PQ,
virtual clients, unchecked conversions, content-debug or crypto-debug features.
The upstream workspace lock has **485 packages (468 registry entries)**, including
other providers, targets, optional features and development tools. That is
neither the browser dependency count nor a transitive license approval.

Before building: choose a pinned official Rust toolchain meeting the manifest
minimum, verify its published checksum, install under an isolated work/toolchain
path, and pin the WASM target/glue version. Use locked crate checksums, not a
moving git/main or arbitrary downloaded bundle. No global package upgrades.
Report `cargo metadata`/target feature tree, direct versus transitive crates,
license expressions/notices and advisories separately from build tools. Record
compiler/target versions, downloads, build disk usage, final WASM/JS raw and
compressed bytes, cold start and peak memory. **All these resolved/bundle cost
measurements are pending**, not zero. A provisional experiment stop budget is
5 GiB additional disk and 128 MiB per client WASM memory; exceeding it triggers
measurement/reconsideration, not silent production sizing or weakened tests.

Browser runtime would need WASM, secure randomness, stable storage and Web Workers;
Node would only build/test assets. Any narrow CSP `wasm-unsafe-eval` requirement
must be demonstrated; never add general `unsafe-eval`, CDN scripts or broad CORS.
Test two real Chromium contexts first, then Firefox/Safari and actual Android
WebView/browser. OS background suspension, storage eviction and locked-device
recovery cannot be inferred from desktop headless Chromium. A future native
Android shell also needs Android SDK/NDK/JDK and an OS key-storage binding;
OpenMLS's target build alone does not qualify that surface.

## Identity, devices, groups and authority

CF Access verifies account admission; our explicit enrollment maps its stable
subject to an app actor. Neither a CF login nor a BasicCredential string proves
that a new encryption key belongs to that person. Add a separate authenticated
device registry, binding actor ID, immutable device ID, credential signing key,
version, status and enrollment evidence. It contains public material only.
A client checks the MLS credential/signature key against its accepted device
binding, not against untrusted sender labels in HTTP or encrypted text.

For the first device, require an explicit verified key fingerprint ceremony with
the person/operator outside the new server-supplied directory. For additional
devices, require approval by that actor's already trusted device and an explicit visible
key-change confirmation; CF account access alone cannot add a decrypting device.
The exact maintained signing/verification mechanism and enrollment transcript
are a separate reviewed implementation gate, not custom crypto specified here.
Persist accepted bindings locally. Server substitution or conflicting bindings
must stop the affected room and display verification required. There is no
claim of a deployed global key-transparency service. Loss of every trusted device
requires explicit recovery/re-enrollment, never silent trust in replacement keys.

One MLS leaf per device; DM is a group with all explicitly approved devices of
the two people. A family group is separate. Actor membership and device membership
must both pass; a person owning several devices does not acquire extra room or
operator privileges. Start the disposable experiment with Alice/Bob/outsider,
one device each, then Alice's second device and removal. Use validated,
short-lived, single-use KeyPackages and consume them durably; test Welcome replay
and group-ID collision, not just application-message decryption.

Use random independent group IDs, with an immutable accepted binding to the app
room. Authenticate the app room, sender actor/device and immutable message ID
inside the MLS application content; compare to the outer route and credential.
Do not treat a valid ciphertext from a different room as an authorized message.
External joins, arbitrary self-add, and draft extensions are disabled initially.
Accept membership commits only after validating both MLS and app device/room
policy; an authenticated member is not automatically allowed to add a stranger.

Removing an actor first blocks server admission and retires active grants. Then
an authorized remaining device must commit removal of **all** that actor's leaves
and establish a new epoch. Freeze sends during the transition; account revocation
alone cannot revoke secrets already possessed. A replacement device must not
inherit the revoked device ID/state. An offline client cannot know an unseen
revocation: production sends require a fresh server policy/epoch check, and fail
closed when it cannot obtain one. A compromised delivery/auth service can still
withhold status or fork views; independent binding checks reduce substitution,
not every denial/fork attack. Revocation never recalls already decrypted content.

## Durable state, retry and offline history

MLS state is device-local secret material, separate from server policy and chat
SQLite. Never put it in sessionStorage, URLs, logs or server plaintext backups.
A dedicated worker owns a device's crypto state. For browsers, use an explicit
single-writer lease/transaction across tabs; a second tab cannot concurrently
advance the same ratchet. IndexedDB is a candidate persistence mechanism, not
already implemented atomic storage or a secure enclave. Same-origin malicious
scripts and a compromised browser/device can read or use keys. Storage eviction
requires recovery/rejoin, not regenerating a device under its former identity.

An outbound operation must atomically persist the library's new crypto state
and immutable serialized ciphertext/outbox record **before any network send**.
After a lost response, retry the exact bytes and same client ID. Do not re-encrypt
text or files on retry, reuse an earlier ratchet snapshot, or silently generate a
new ID. Receiving must atomically persist library state, replay bookkeeping,
locally retained message material and the applied stream cursor before acknowledging
or displaying completion. Plain HTTP sequence dedup does not replace MLS checks.
Self-echo handling must use the library contract and durable outbox identity.

If storage fails or commit outcome is uncertain, retire the in-memory group,
stop sends and retain diagnostic state without logging keys. Resume only from a
known committed transaction; do not merge a partial state or reuse a rolled-back
counter. If a membership commit wins while old-epoch ciphertext is durably queued,
a fresh policy/epoch check must reject delivery under the old epoch. Preserve and
retire that pending item without ratchet rollback, changing its bytes under the
same ID, or silently re-encrypting it. A deliberate new send after catch-up is a
new operation with a new ID; the old outcome must be reconciled first. Test this
race with an actually persisted outbox and a removed recipient.

The OpenMLS provider can perform multiple writes per operation, so the
wrapper must stage all of them in one application transaction with the outbox/
cursor and discard its mutated object on failure. **Whether a WASM/IndexedDB
adapter can meet this synchronous-provider contract is a concrete blocker**;
first prove a disposable staged-provider transaction design, then fault-inject
before and after every durable boundary. No persistence guarantee from the core
audit is assumed. Use self-describing, versioned state codecs and explicit,
backup-preserving upgrades; 0.9.0 storage changes make blind serialization unsafe.

Server delivery needs ordered durable MLS control events (Proposal/Commit/Welcome)
as well as application ciphertext. Current text POST/SSE alone is insufficient:
add room/epoch CAS, stale-commit rejection and reliable targeted Welcome delivery
without inventing another cryptographic protocol. Concurrent commits resolve by
library-supported handling of the accepted order; never automatically merge
conflicting crypto snapshots. Offline clients replay control events in order
before encrypting, with bounded past epochs/skipped generations and resource limits.
A gap beyond retained state requires a visible rejoin, not plaintext fallback.
Transport duplicates/out-of-order events must not advance a ratchet twice.

Historical server ciphertext is not a readable history archive after keys are
erased. Decide and disclose history retention explicitly: newly added devices get
future messages by default, with no automatic old epoch-secret export. Retaining
local decrypted history or a recovery archive reduces the protection of forward
secrecy for that archived content. Bound retained past epoch secrets separately
from a user's archive. A server backup restores delivery data, not erased keys.
A maintained encrypted device-transfer/backup format and OS-protected local key
storage remain separate blockers. Do not improvise a password KDF or escrow all
room keys to the owner. Recovery acceptance must cover loss of one/all devices,
old backup rollback and revoked devices; restoring an old crypto snapshot must
force reconciliation or fresh-device rejoin before any send.

## Text, files, metadata and bots

Encrypt text and attachment display metadata as MLS application data. For the
first **small synthetic opaque-file proof**, encrypt the entire bounded byte array
as MLS application data through the library API. No exported-key plus custom
AES/nonce construction. This establishes byte fidelity only, not an 8 MiB file
protocol. Large attachments need either measured bounded MLS application messages
in opaque storage or a separately vetted attachment/streaming construction. Do
not invent chunk encryption, key wrapping or nonce derivation to meet a deadline.

The existing 16 KiB message and 8 MiB attachment limits include protocol overhead:
MLS Commit/Welcome/tree sizes and encrypted files may exceed them. Before native
integration, define separately bounded control/ciphertext records and quotas;
measure worst-case devices/groups and reject oversized input before parsing.
Do not silently increase every limit or advertise the old plaintext file capacity
as encrypted-file capacity. No partial unauthenticated plaintext preview.

For future opaque file storage, send a generic filename/MIME, hash and size of
**ciphertext**, and keep original filename/type/plaintext integrity information
inside the encrypted attachment description. Bind file identity/digest to room,
sender and message. Authenticated download, quotas and authorization still apply.
The current MEDIA.md envelope exposes original names, types, hashes and synthetic
plaintext; it stays explicitly legacy/synthetic. Introduce an explicit new room
mode and versioned ciphertext envelope with no downgrade. Preserve existing DBs,
files, snapshots and pending IDs; no silent migration or reinterpretation.

| Observer | Intended visibility after implementation |
| --- | --- |
| Yukson delivery host, proxy/CF | Account admission, room/device routing, IP/timing, approximate sizes, ciphertext and access records; not message/file plaintext or device private keys merely by storing/forwarding traffic. |
| Approved family devices | Plaintext of groups/epochs they join; saved content remains accessible after removal. |
| Fleet node explicitly invited to a work room | Plaintext needed for approved work, through that node's own crypto device. Its AI provider can receive task content under the existing runtime's policy. |
| Other fleet nodes or bots | No automatic family-room membership, key distribution or plaintext access. |

The web asset delivery host is an additional trust boundary: a compromised host
can serve malicious JS that steals plaintext/keys at endpoints. CSP and CF
admission do not solve that. Signed/reproducible release distribution and an
independently verifiable native client are future hardening options, not guarantees
provided by WASM. Metadata hiding and post-quantum security are not claimed.

Decryption does not authorize execution. Owner-only task/approval/cancel controls
must bind the authenticated actor/device, room, task, target node and generation,
then pass the existing worker/guardian admission contract. Family chat privileges
and room administration cannot grant execution. All 12 nodes keep credentials on
their original nodes; only explicitly invited bot devices receive work-room keys.
Telegram remains the fallback throughout qualification.

## Acceptance sequence and stopping conditions

1. **Library/browser experiment (next bounded unit).** Resolve/pin dependency and
   license graph; verify isolated tools; build own minimal wrapper around public
   library APIs with no upstream app copying. Two disposable real browser contexts
   create/join a group, encrypt/decrypt synthetic text and a small opaque file.
   Test tamper, wrong group, nonmember, replay and removal/new epoch; assert no
   plaintext result on rejection. Preserve exact versions, hashes, size/memory
   evidence and proof JSON. No server/CF/human state. Failure to satisfy browser,
   provider or memory constraints is a reported blocker, not a production library
   selection. A passing roundtrip is still not product E2EE.
2. **Device-state transactions.** Implement staged provider and durable outbox/
   inbox/cursor with multiple tabs, crash/rollback, storage failures, replay,
   self-echo, key-package single use and version migration tests. Independently
   review before binding real native HTTP/SSE.
3. **Synthetic owned transport integration.** Device registry/trust ceremony,
   room/group binding and ordered control events; two actors/multiple devices,
   offline epoch catch-up, concurrent commits, revocation/expired CF admission,
   exact-byte lost-response retries and encrypted file limits/metadata tests.
4. **Human-use acceptance.** Actual CF gate and enrollment/refresh, E2EE recovery/
   backup, mobile browser and release-integrity acceptance, then an explicitly
   approved pilot. Separate Seoseo work-room binding/owner approval/cancel proof
   precedes the remaining 11-node rollout and eventual cutover.

These are acceptance gates, not implemented features or new approval requests.
No human keys/accounts, production E2EE, Cloudflare changes or cutover occur in
this design unit. The existing 57 Go groups, 74 Python tests and synthetic browser
proofs establish the previous plaintext/admission contracts only.

## Isolated browser experiment result

The subsequent [OpenMLS browser experiment](../experiments/openmls-browser/README.md)
provides a pinned runnable memory-only Chromium proof and dependency/license/cost
evidence. It does not implement device trust, durable crypto state, native
transport integration or production E2EE; the remaining acceptance gates above
still apply.

## Staged browser persistence result

The subsequent [synthetic state adapter](../experiments/openmls-browser/PERSISTENCE.md)
reconstructs the full provider for each candidate operation and commits its state,
exact-byte retry ledger and receive cursor in one IndexedDB transaction before
release. Two persistent Chromium clients qualify confirmed-commit process crashes,
in-flight process crashes, controlled precommit aborts, concurrent retries and
corruption rejection. This is an isolated storage prerequisite; native transport,
self-echo/control cursor integration, device trust, human key protection and recovery
still need qualification. Existing synthetic database formats are not migrated.

## Native device-directory qualification

The [first-device implementation](../server/DEVICES.md) persists explicit public
bindings/tombstones in signed policy and checks native room admission. A separate
synthetic browser worker validates independent pins and actual MLS credentials
for invitation/Welcome. Durable client pins, trusted staged-state integration,
control transport and human enrollment/recovery remain outstanding.

## Durable trusted-state qualification

[The trusted-state adapter](../experiments/openmls-browser/TRUSTED-STATE.md)
atomically retains independent pins, local room/group identity and complete MLS
state/outbox across actual browser crashes. Signed native admission is checked
outside IDB and matched against the latest transaction record. Native ordered
control/room binding and ciphertext delivery remain the next integration gate.

The [native transport boundary](../server/MLS-TRANSPORT.md) now reserves explicit
MLS-only rooms and persists ordered opaque control/application events with fixed
device bindings, CAS and restart/retry semantics. Its process proof uses generated
opaque bytes, not actual encrypted application messages. Joining the trusted staged
browser, outer authenticated framing and control/outbox/cursor remains next.

[Native encrypted delivery](../experiments/openmls-browser/NATIVE-DELIVERY.md)
now joins initial trusted group setup and application ciphertext to the native
log in two disposable browsers. Actual MLS sender/inner/outer binding, full-state
outbox/cursor and crash retry are checked. This remains a synthetic worker proof;
subsequent commits, product UI and human-use acceptance remain outstanding.

The subsequent fixed-pair encryption rekey adapter is documented in
[Native controls](../experiments/openmls-browser/NATIVE-CONTROLS.md). It retains
old-epoch inbound processing until the accepted ordered own commit, using vetted
OpenMLS pending/merge APIs. It does not replace signing keys or add devices, and
does not complete the human-use acceptance gates.

An own synthetic encrypted chat UI now exercises the durable native worker through browser controls. See [CHAT-UI.md](../experiments/openmls-browser/CHAT-UI.md) for the isolated test-serving boundary; this is not a deployed human-use UI or completed CF/key-recovery gate.

The encrypted test UI can now be built into the native server through a fixed hash-pinned manifest and explicit signed synthetic activation. See [ENCRYPTED-UI.md](../server/ENCRYPTED-UI.md). This does not complete human-use key protection, recovery or actual CF/mobile/backup acceptance.
