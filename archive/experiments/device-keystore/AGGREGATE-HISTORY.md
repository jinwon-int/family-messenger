# Read-only history from the complete device aggregate

This isolated synthetic worker boundary exports and reads the selected complete
`AggregateStore` format. It does not use the separate generic aggregate admission
precursor. Old single-room archives, native UI bundles, profiles and live custody
code are unchanged. There is no product recovery UI or Go asset activation yet.

`family-aggregate-history-v1` contains the original database name and the exact
committed outer state: version, actor, device scope, vault ID, revision, age
capsule, secretstream header and ciphertext. The exporter opens only an existing
version-1 aggregate database with exactly one `device/state` record, using a
readonly transaction. Unknown schema, missing state and creation markers deny;
no profile is created, upgraded, repaired or imported. Export may observe an
earlier coherent revision while a live sender advances later.

The reader reuses the existing age 0.3.1 single scrypt18 password container and
libsodium 0.8.4 secretstream FINAL authentication, with the original device-scoped
AAD. No cipher, nonce, password derivation or wrapping protocol is added. The
outer archive is canonical JSON with bounded base64. The 6 MiB archive limit
accommodates the existing 4 MiB serialized aggregate plus 17 ciphertext bytes,
24-byte header, at most 8192-byte capsule and JSON/base64 overhead. It does not
raise the two-context, 1 MiB/provider or combined 2 MiB binary live limits.

The caller supplies independently accepted database, actor, primary room, both
ordered room/group/pin descriptions and the immutable fork intent. Both rooms
must have native bindings and independently expected nonempty, different group
IDs. Partial or single-context aggregates are deliberately unavailable in this
reader version. The full aggregate validator checks every provider, receipt,
pending request, cached result, cursor and control state, including actual epoch
and the same enrolled signing key across contexts. The existing full native-v4
history validator then matches each room to the independent expectations.

Complete authentication and validation of **both** contexts precede any result.
Only accepted cached message frames, their room/group/pins and historical
cursor/epoch are returned. Unaccepted pending frames from either context are
excluded. Results are historical content, never executable fleet input. The
reader cannot send, enroll, fork a device, import an active provider/outbox,
restore a sender or change pins. It imports no native command dispatcher and
has no IDB or native HTTP operation. Module/WASM loads remain same-origin.

The archive contains the encrypted complete provider, including private key
material; it is not a history-only key backup. Its password/root compromise can
expose that backed-up state. Possession of an archive and password permits past
history reading offline after server revocation. Neither this authentication nor
a valid older archive provides rollback detection or current account authority.
No replacement-device recovery or conversation continuation is implemented.

The separate caller and one-shot workers retain the prior lifecycle contract:
10-second boot, 30-second caller request deadline, 15-second worker deadline and
the shared origin-wide `family-native-vault-kdf` lock. Close is terminal;
lock/hide/pagehide/clone failure terminates pending workers and discards late
callbacks. Archive view and backing allocation are bounded before cloning;
public expected metadata and the generated 32–128-character password are bounded
as well. After cleanup callbacks, terminal/generation state is rechecked; a
validated owned input clone is taken before worker boot, and bounds are checked
again at posting. Later caller mutations cannot change the admitted operation.
The consuming page must clear its own input strings, file references
and rendered results; JavaScript cannot erase immutable caller-owned strings.
Private provider/root/password never returns from the worker. No secret is
stored in page storage, URLs or logs. Same-origin hostile code, extensions, OS
compromise and physical memory erasure remain outside this boundary.

No new dependency or toolchain is installed. Existing age/sodium have two direct
and eight transitive runtime instances; OpenMLS has eight direct and 151
transitive WASM crates. The optional pinned identity-context WASM is used;
older default WASM and all 9/15/21/14 asset manifests stay unchanged. Existing
age/sodium/Cargo/Rust notices apply. Worker linear memory must stay below
128 MiB; scrypt18's approximately 256 MiB JavaScript scratch is accounted
separately. Heavy browser/KDF probes run serially.

## Reproduction

Use the verified existing Go toolchain to build `family-dev` and `family-policy`,
and the pinned optional identity-context bundle:

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --aggregate-history \
  --bundle artifacts/identity-context-build-smmbyhm5/candidate \
  --binary artifacts/family-dev --policy-binary artifacts/family-policy
```

The harness builds the original two reader/export workers using locked existing
esbuild and records their hashes. Generated test forgers are separately hashed
and never enter a product asset manifest. Tests use two actual native browser
clients, text/8 KiB file/control traffic, a source browser SIGKILL, a fresh reader
context, authenticated malformed-state fixtures and lifecycle/resource failures.
The source must retain byte-identical encrypted state and pending operations;
the reader must issue zero native requests and create zero IDB state. This is
worker qualification, not a human recovery or Yukson deployment acceptance.
