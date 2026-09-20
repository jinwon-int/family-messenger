# Native encrypted state driver (synthetic)

This is a new, explicit encrypted persistence entry for the existing native MLS
engine. `native-worker.js` exports `serveNative(storage)` and keeps its direct
worker/default plaintext fixture behavior. `vault-native-worker.js` supplies the
encrypted driver. No existing profile is migrated or interpreted as encrypted,
and the compiled Go `/encrypted/` UI still selects its previous plaintext fixture
store. New UI packaging/human enrollment are not complete.

The native engine retains its actual sender/pin checks, ordered native log,
KeyPackage/Welcome/ack and pending-commit old-epoch semantics. All provider values,
accepted pins, pending exact wire request and frame, receipts, cached messages,
receive cursor and control state form one protected record. The driver receives
private callbacks inside the worker; decoded provider/root bytes never reach the
page. Test-only internal digest instrumentation returns hashes, not private state.

## Stored state and binding

The new `family-mls-vault-synthetic-*` namespace has one `device` object store and
one `state` key. Explicit creation may create `{v:0,identity,room}` only; initializing
from that marker requires an init operation and no registered actor device in the
fresh signed directory. Unlock mode cannot create a missing database. Existing
full records cannot be replaced via create mode. Unknown files, stores, keys or
records remain intact and denied. No key regeneration, repinning or silent reset.

A version1 outer record has exactly identity, room, vault ID, local revision,
standard age capsule, secretstream header and ciphertext. The capsule protects
`[1,database,identity,room,vaultID,actualProviderPublicKey,rootKeyBytes]` using the
unchanged default password work factor. The library parser admits only the single
scrypt18 recipient before password work. Full capsule authentication/strict schema
precedes key use. Existing key-cache use requires the same capsule and vault ID;
a lower observed revision during a live session is denied. Fresh directory/pins
and the real provider public key must match after decoded state validation.

The whole native version4 payload uses canonical base64 for its binary provider,
with native validation preserving the 1 MiB provider and 2 MiB aggregate binary
state/ledger limit (the provider counts toward that aggregate).
The serialized envelope is capped at4MiB before secretstream protection. Native
fields are already bounded ASCII/base64/integers; this accommodates the base64
expansion plus bounded field names/metadata. Ciphertext is at most4MiB+17 and has
one24-byte header and one required FINAL chunk. Associated data binds the format,
database, actor, room, vault ID and local storage revision. No custom KDF, nonce,
cipher or key wrapping algorithm is introduced; age and secretstream high-level
APIs own those operations. Public-recipient encryption is not used as state MAC.

## Atomicity and lifecycle

A per-database Web Lock serializes cooperative operations. Under it, a readonly
IDB transaction reads the exact committed outer bytes; decrypt, full validation,
native candidate operation, encryption and fresh signed admission all occur
outside any active IDB transaction. A final strict readwrite transaction compares
all prior outer bytes/revision and exact key count before optionally writing the
complete encrypted candidate. Only completion permits a result. Changed state
from a bypassing writer rejects the candidate; no automatic re-encryption retry.
Unchanged snapshots/duplicate operations preserve ciphertext bytes. IDB aborts and
uncertain replies retain prior or committed complete state for explicit reopen.

A separate origin-wide Web Lock serializes password KDF work across databases.
Lock waits/operations have15-second abort signals, checked again before commit.
No server authority lock or IDB transaction is held during network body reads;
the cooperative per-database Web Lock remains held. Worker closure aborts controllers
and live transactions, wipes the reachable root buffer and closes IDB. Root state
handles remain library-owned; at most256 storage operations per session and the
combined OpenMLS+sodium128MiB WASM limit bound activity. JS password KDF scratch
(~256MiB) is separate from the WASM budget. A stale callback cannot publish a
successful result after retirement. Page ownership must terminate on lock/hidden
and protect against old timers affecting newly opened workers.

A successful library roundtrip is not whole-store anti-rollback: valid older
capsule/record pairs can still be restored after restart without an external
witness. Retained root-key compromise exposes historical records; no root forward
secrecy is claimed. Cooperative Web Locks do not constrain malicious same-origin
code, extensions or a compromised OS. Physical JS/string memory zeroization is
not promised. Human passwords, recovery/replacement devices, actual CF account
activation, mobile and backup acceptance remain prerequisites for Yukson cutover.

## Reproduce the isolated native boundary

Use the existing pinned WASM bundle and synthetic native/policy binaries (see
`../openmls-browser/NATIVE-DELIVERY.md`). Install only the locked candidate packages:

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix experiments/device-keystore
node experiments/device-keystore/node_modules/esbuild/bin/esbuild experiments/device-keystore/native-vault-store.js --bundle --format=esm --platform=browser --target=es2023 --minify --outfile=experiments/device-keystore/bundle/native-vault-store.js
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault --bundle artifacts/mls-remapped-pkg --binary artifacts/family-dev-plain-final --policy-binary artifacts/family-policy-mls-fixed
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault --controls --bundle artifacts/mls-remapped-pkg --binary artifacts/family-dev-plain-final --policy-binary artifacts/family-policy-mls-fixed
```

The generated assertion proxy remains test-only and loopback-bound. The page
fixture owns workers, terminates on lock/hidden/pagehide and broadcasts that lock
to cooperating tabs; no password is persisted. Test-served instrumentation holds
CAS/KDF/write boundaries and returns hashes of provider/outbox state, never private
bytes. The proof records original and instrumented asset hashes separately.
Corruption tests explicitly restore saved **synthetic encrypted** bytes to continue
negative checks; that is test setup, not a supported active-leaf recovery feature.
No live profile is deleted or reset. The lock command validates its full envelope
before acknowledgement; malformed lock still retires.

Dependencies are unchanged from the session-record candidate; see
`native-vault-inventory.json` and the retained license notices. The runtime bundle
includes age plus sodium WASM; it is not part of the Go default embedded bundle.
The Go manifest changes only to pin the native engine factory refactor. Its direct
worker path preserves prior synthetic behavior.

The native input boundary also rejects sparse arrays before normalization, so a
missing file byte cannot silently become zero and enter the exact outbox. A valid
lock response removes the caller handle immediately; reopening does not depend on
a timeout or an explicit cleanup of a closed worker.

Recorded final control proof has 31 assertions and a 60,502-byte encrypted whole
record, 24-byte header and 456-byte capsule. Combined OpenMLS+sodium linear memory
peaked at 5,636,096 bytes; browser/JS heap and the separately admitted 256 MiB KDF
scratch are excluded. The driver bundle is 585,011 bytes / 206,769 gzip. These
measurements describe generated two-member state, not worst-case records or mobile
acceptance. See `native-vault-evidence.json` for exact receipts and limitations.

The follow-up [isolated custody UI](../openmls-browser/VAULT-UI.md) supplies explicit
unlock/lock and actual DOM delivery/restart tests for this unchanged driver. Its
vault assets are still test-proxy-served; native Go packaging is a separate gate.
