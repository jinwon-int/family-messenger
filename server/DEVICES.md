# Synthetic first-device enrollment and browser trust gate

Current lifecycle qualification and planned successor semantics are documented in
[DEVICE-LIFECYCLE.md](../docs/DEVICE-LIFECYCLE.md). That library/design experiment
does not relax any enrollment or immutable tombstone constraint in this server.
The [version-2 successor policy](SUCCESSORS.md) now records public intent and
atomic predecessor retirement. Its candidates remain outside this device list;
it still cannot activate an additional or replacement device.

This implements a durable **public device directory** in the existing private
signed-account policy, plus an isolated browser trust gate using OpenMLS. It is
a step toward the requested application, not live CF login, human enrollment or
native E2EE delivery. The native server still handles synthetic plaintext rooms;
the small encrypted exchange in the proof is relayed by the test coordinator.

## Explicit first-device acceptance

An optional `devices` array in the version-1 policy contains:

```json
{"device_id":"alice-first","actor":"alice","subject":"person-1",
 "signing_key":"<64 lowercase hex characters>",
 "fingerprint":"<SHA-256 of the 32 raw public-key bytes, lowercase hex>",
 "status":"active","device_revision":1,
 "acceptance":"out-of-band-fingerprint"}
```

Use the existing `family-policy --synthetic-only --auth-state ... --input ...
--expected-revision ...` with a new immutable private proposal. No HTTP endpoint
registers devices. A CF assertion, room ownership or owner flag cannot enroll a
key. The acceptance marker records an explicit management declaration; software
cannot prove that a human actually compared fingerprints. The test obtains each
public key directly from its generating worker and supplies those pins separately
from the directory, emulating that ceremony with generated synthetic identities.
No actual human fingerprint UI or account setup is claimed.

Bindings include the exact enrolled subject and actor. Active devices require
that enrollment to exist; revoke the device explicitly when removing its account.
At most 32 devices exist, with unique IDs, actors and public keys. This phase allows
**one first device per actor for the entire retained history**, including tombstones.
Additional/replacement devices, trusted-device approval signatures, reactivation
and lost-device recovery are denied until their reviewed mechanism is implemented.
No homemade enrollment signing or messaging cipher is introduced.

The ID, actor, subject, key, fingerprint and acceptance remain immutable. The
only state change is `active/1` to `revoked/2`; deletion or resurrection is rejected.
Both each persisted history transition and a live authority replacement enforce
this. A fresh managed authority can load an already revoked final revision only
after validating the complete history. Account identity and owner execution
privileges retain their independent admission checks.

## Storage and directory admission

Existing no-device policy files retain their exact canonical encoding/checksum;
no chat schema or old file is rewritten. Device entries use the same private
0700 directory, 0600 single-link files, bounded exact JSON, immutable revision
chain, cross-process lock, CAS and file/directory fsync. Existing unknown/pending/
corrupt-file preservation and failed-reload suspension remain. Older binaries
reject the new `devices` field; never run an old binary on the new selected policy
expecting it to ignore devices. Entire valid historical-prefix rollback remains
undetectable after restart without an external witness, as documented in AUTH.md.

`GET /v1/rooms/{room}/devices` requires signed admission and current room membership.
Fixture bearer mode is denied. The response contains version, exact room and public
ID/actor/key/fingerprint/status/device revision only, never account subjects or
private keys. Devices of nonmembers are excluded; revoked member devices remain
visible as tombstones. No query-selected actor or HTTP mutation is supported.
The grant captures a cloned device snapshot during signature verification and
rechecks generation/expiry before the route. It holds the authority then chat lock
through the bounded directory response, so completed revocation cannot admit a
new operation using an old snapshot. A directory read grants no execution right.

## Browser/library validation and limits

`experiments/openmls-browser/web/trust-worker.js` is a separate **memory-only**
synthetic worker. It accepts two independently supplied immutable pins, checks
its own generated key, and fetches the actual signed native directory with the
expected actor header. Each check/create/invite/join/encrypt/decrypt operation
requires a fresh successful directory response matching the fixed room and both
pins. Body reads are bounded to 16 KiB/5 seconds, redirects rejected, and the
existing loopback Host/Origin boundary remains. Malformed worker commands also retire the worker; failed admission aborts the
fetch even when rejection happens before reading the body. Missing, extra, revoked, substituted
or conflicting bindings, identity failure and unknown input retire the worker;
there is no plaintext/fixture or automatic new-key fallback. A directory whose
public key and advertised fingerprint are both substituted still fails against
independent pins.

The own wrapper's `verify_device_package` parses with OpenMLS's exact TLS codec
and validates the KeyPackage/signatures before comparing its actual BasicCredential
and signing key to the expected pin. `invite_trusted` uses that function before
adding a member. `join_trusted` validates Welcome through OpenMLS, then requires
exactly the own and pinned peer credentials/keys in the authenticated group.
A valid Welcome from a different key using the right actor label is rejected and
the uncertain memory-only device is retired. Wire/identity/key and WASM memory
limits remain bounded. No private key is returned to the page or delivery host.

This does **not** join the staged IndexedDB adapter to a trusted-client lifecycle.
Pins, trust-worker state and the test's crypto group are not restored after browser
restart; a fresh disposable test needs new separately accepted synthetic identities.
Durable client pins/state, group-to-native-room binding, ordered Proposal/Commit/
Welcome delivery, exact-byte transport outbox/self-echo and multiple-device approval
remain the next integration work. Fresh directory checks cannot make an offline
client aware of withheld revocation, prevent a compromised server replaying a valid
old directory, or atomically authorize later delivery. Native policy/epoch admission
must cover that race. No full anti-fork/key-transparency claim is made.

## Reproducible qualification

Build the pinned Rust/WASM wrapper as in the experiment README and the two Go CLIs:

```sh
go -C server build -trimpath -o ../artifacts/family-dev-trust ./cmd/family-dev
go -C server build -trimpath -o ../artifacts/family-policy-trust ./cmd/family-policy
timeout 120s .venv/bin/python tests/native_device_browser_smoke.py \
  --bundle artifacts/mls-device-pkg --binary artifacts/family-dev-trust \
  --policy-binary artifacts/family-policy-trust
```

The proof uses two Chromium contexts and a loopback-only CF-shaped test proxy;
spoofed upstream identity headers are denied, generated signed assertions are
injected only upstream, and no JWT reaches JS/storage/URLs. Test-served main.js
selects the separate trust worker, and a test-only fetch-signal observer verifies
cancellation without reading keys/bodies; served hashes are recorded. Native restart,
policy reload and retained revocation are real processes. A second fresh private
auth history tests the valid-but-unaccepted inviter-key case; earlier state and
proposals remain retained. CI uploads verification JSON only, not private profiles,
keys or policy state. Four new Go groups cover immutable history/restart, concurrent
CAS and retired snapshots, strict/corrupt input retention, room/identity admission.
The prior native, 14 staged-persistence and 9 memory-only browser regressions remain.

No runtime module was added: Go remains 2 direct/0 transitive external modules;
WASM remains 8 direct/151 transitive external packages. Existing notices apply.
See `experiments/openmls-browser/device-evidence.json` for this version's source,
artifact and resource receipt; older experiment receipts are historical observations.
Production activation still requires device-state/transport integration, real CF
admission, protected keys/recovery, mobile and backup acceptance. Family rooms do
not automatically enroll bots; all 12 runtime credentials stay on their nodes.

## Durable synthetic client follow-up

[TRUSTED-STATE.md](../experiments/openmls-browser/TRUSTED-STATE.md) now joins
independent pins to staged crypto/outbox state across browser restart, with fresh
native directory admission. It retains the transport and human-use limitations
above; the original memory-only gate stays as a regression fixture.
