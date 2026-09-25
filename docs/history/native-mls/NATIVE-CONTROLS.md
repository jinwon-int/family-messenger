# Ordered synthetic native rekey controls

> **이력 문서** — [#177](https://github.com/jinwon-int/family-messenger/issues/177) M2b-3c(2026-09-26)에서 설명 대상 코드가 삭제되어 `archive/experiments/openmls-browser/NATIVE-CONTROLS.md`에서 옮겨 왔다. 본문의 경로·명령·증거 해시는 삭제 전 기준이며, 코드는 태그 [`archive-frozen-20260917`](https://github.com/jinwon-int/family-messenger/tree/archive-frozen-20260917/archive)과 삭제 커밋의 부모에서 볼 수 있다.

The native worker now supports creator-initiated MLS encryption rekeys for the
same independently pinned pair. It uses OpenMLS 0.9.0 public `self_update`,
`pending_commit`, `process_message`, `merge_pending_commit` and
`merge_staged_commit` APIs. Device **signing keys and enrollment pins do not
change**. Replacement devices, new members, removals, recovery and human-safe key
storage are outside this boundary. There is no custom ratchet or message cipher.
The Go transport, schema, authentication policy and production services are unchanged.

## State and ordered acceptance

`native-worker.js` requires the new `family-mls-native-control-synthetic-` namespace
and version-4 record. It does not open, migrate, reset or delete earlier version-3
native or version-2 trusted profiles. Fresh generated profiles and a separate
synthetic directory are used for the proof. Missing registered keys still deny
initialization; this namespace is not a way to replace an enrolled human device.

Alice calls `update` with an immutable `update-...` ID. A strict IDB transaction
loads the latest whole provider and stages `self_update` without merging. The
provider's pending commit and exact native request commit together. A same-ID
pending or completed retry returns the known operation; a different outstanding
operation cannot be overwritten. The record checks that a library pending commit
exists if and only if its retained native outbox is a commit. Snapshot save/load
revalidates the full pair and the pending state.

The library remains at the old epoch while the commit is pending. Peer application
messages accepted before the commit may still be processed, including in the same
native batch as the eventual own echo. Only an exact self echo, after all preceding
records, invokes `merge_pending_commit`. Own ciphertext is never processed as a
peer message. That merge, clearing the exact outbox and advancing the native
cursor/revision/epoch are committed atomically before output. A second tab sees the
latest receipts and cannot merge again. No network wait occurs inside IDB.

The peer runs `process_message` in a fully isolated provider candidate. It requires
an authenticated member sender, the independently pinned credential and signing
key, and a staged commit. Canonical metadata supplied through OpenMLS authenticated
data binds version, room, group, immutable control ID, creator actor/device,
kind, expected native revision/epoch and target device. Changing a valid outer ID
therefore fails even with a recalculated transport checksum. Every queued proposal
is rejected before merge; only a path rekey retaining the exact pair is accepted.
The resulting pair, own key and exactly one epoch increment are revalidated and
roundtripped through provider storage before the IDB candidate can commit.

Bob stages the native acknowledgement only after the peer merge is durable.
Acknowledgement IDs retain `control-ack` for epoch 1 and use `control-ack-N` later.
The ready/ack barrier prevents new application sends until acknowledgement enters
the native ordered log. This empty native acknowledgement is an authenticated
application control declaration, **not an MLS cryptographic receipt or protection
against a malicious server claiming delivery**. It cannot recall past plaintext.
The server still cannot validate opaque MLS data or infer successful client decryption.

## Failure and boundaries

A failed candidate never replaces committed crypto, pins, pending request or
cursor. Worker failure requires explicit reopen and fresh signed directory
admission. A response lost after native acceptance retries the same stored commit;
it never generates a second commit, merges early or restores an older ratchet.
A browser killed while the peer merge's IDB write is pending restores the whole
old record, and processing the original commit afterward succeeds.

A pending application accepted before a commit reconciles through its ordered
self echo. A never-accepted stale application or commit rejected by native CAS is
retained and marked retired without changing its bytes/provider. A peer commit
cannot silently discard any outstanding local outbox. Such a client remains
frozen pending a separate reviewed retirement/recovery lifecycle; this experiment
does not pretend to keep sending after that condition. There is no rollback,
automatic resend at a new epoch, or clear-pending/reset command.

Existing limits remain: 32 retained native records/messages, 8 KiB application
bytes, 64 KiB wire, 1 MiB provider and 2 MiB combined binary state. Control AAD is
bounded at 2 KiB in the Rust wrapper. Private synthetic IDB keys and cached messages
remain unencrypted at rest. The record checksum detects accidental corruption,
not malicious complete replacement or whole-profile rollback. Public directory
freshness is not a revocation oracle; native admission and existing failure rules
remain necessary. Family rooms do not acquire bots or owner execution authority.

## Reproduction and evidence

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --controls \
  --bundle artifacts/mls-control-pkg --binary artifacts/family-dev-mls-fixed \
  --policy-binary artifacts/family-policy-mls-fixed
```

The actual two-browser fixture verifies pending old-epoch traffic, ordered own
merge, two-tab same-ID staging/echo, authenticated metadata and ciphertext tamper,
peer merge abort on real owned-browser SIGKILL, restart and exact pending retry
after lost native reply, the ack barrier, repeat updates, prior-epoch commit replay
and new-epoch text/file delivery. Existing native tests also run after these
updates, including stale outbox retirement against an actual subsequent update.
No real accounts, CF settings, human data or production endpoints are used.

Served-only instrumentation can hold a pending IDB merge write; it is absent from
the source worker, and original/served hashes are separately recorded. Fixture
profiles are checked against the exact owned browser command line before SIGKILL.
CI uploads verification JSON only. See `native-control-evidence.json` for resource,
source and artifact hashes; original PR32 evidence remains historical.

No dependency or feature was added. OpenMLS core audit coverage does not imply
browser/provider/storage qualification for human use. Product UI integration,
protected keys/recovery, multi-room device lifecycle, real CF/mobile acceptance
and an isolated Yukson candidate remain before production cutover.
