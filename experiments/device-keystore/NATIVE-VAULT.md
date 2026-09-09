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
with native validation preserving the1MiB provider and2MiB aggregate ledger limit.
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
No actor lock is held during network body reads. Worker closure aborts controllers
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
