# Protected successor exchange experiment

After both protected custody declarations, explicit candidate/peer exchange
workers use the server's restricted handshake endpoint. They reopen existing
stores with `create:false`, own the accepted reservation before any await, and
never create another candidate KeyPackage. This remains an inactive synthetic
experiment, outside native application delivery and the product asset builder.

The candidate record advances from version 1 to version 2, retaining its exact
accepted package and reservation. The peer aggregate advances from version 2
to version 3, retaining the full source record (including its pending operation)
and replacing only the target with an explicit handshake record. Old validators
remain unchanged and reject these new versions; old entry points cannot resume
or reset them. No automatic reverse migration is provided.

The handshake record stores a validated public transcript prefix, group ID and
at most one pending public request. Provider changes and that request are sealed
in the same strict IndexedDB compare-and-swap transaction. Only after completion
may a worker POST that request. Missing stores, a wrong password, malformed state
or a failed local commit produce no POST. A failed or unknown POST retains the
same pending request and provider. Reopening either reconciles the exact server
slot or retries the exact saved request; it never regenerates a Welcome.

The peer creates a group and invites the exact accepted package. The candidate
loads its original saved provider, consumes the Welcome, verifies the expected
peer and group at epoch 1, and commits that state before preparing its empty ack.
Each invocation sends at most one public slot and returns public status only.
All reads and writes require current server authorization, bounded same-origin
responses, matching actor headers and monotone exact transcript slots. A final
fresh read precedes each local CAS. Expiry, revocation, lock and timeout retain
already committed state and prevent a successful late result. As with other
network operations, authorization can change after a completed server check;
there is no claim of atomicity across the server and browser database.

`exchange-recorded-inactive` means the restricted transcript is complete. The
empty ack is not remote proof of private key possession. No ordinary room is
activated, no device is enrolled, and no application send method is exposed.

Run the real paired browser proof with the identity-context WASM package and
schema-7 server/policy binaries:

```sh
python tests/native_encrypted_browser_smoke.py --exchange --exchange-candidate bob \
  --custody-order concurrent --bundle <identity-context-pkg> \
  --binary <family-dev> --policy-binary <family-policy>
```

Repeat with `--exchange-candidate alice`; custody order may be candidate, peer
or concurrent. Successful protocol writes use the uninstrumented store/worker.
Separate, hash-recorded test bundles inject transaction aborts and use disposable
library transitions on reopened protected states to prove bidirectional private
cryptographic continuity. Those proof transitions do not save ratchet changes or
expose provider bytes. The fixture also verifies unknown POST retry consistency,
lost replies, browser/server restarts, cross-tab retries, retained original
source/pending bytes, unchanged legacy ciphertext, malformed and stale receipts,
expiry/revocation, and rejection by old entry points.

Native activation, cryptographic possession receipts, lifecycle convergence,
human recovery ceremony, file/mobile acceptance and operational cutover remain
separate work. Production Matrix is unaffected.
