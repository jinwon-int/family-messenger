# Encrypted custody UI — isolated synthetic boundary

`vault-chat.html` / `vault-chat.js` explicitly call the shared `serveChat(true)`
UI engine and the existing `vault-native-worker.js` storage entry. The direct
`chat.js` module entry continues to select the previous synthetic UI/store. No
old namespace, draft or browser profile is imported, renamed or deleted.

This unit is a runnable **test-proxy-served UI**. The Go embedded manifest pins
the updated shared chat engine for its default entry, but does not include the
new vault page, driver or sodium/age notices. A reviewed own-server vault asset
bundle/activation gate is the next unit; there is no production route or fallback.
The generated assertion proxy is loopback-only, exact-allowlist and not an actual
CF deployment. It supplies synthetic assertions to the real signed native APIs.

## Entry, identity and lifecycle

Opening defaults to unlocking an existing store. Creation requires the explicit
“new test device” checkbox, which clears on submission. The existing worker denies
creation over a full store or regeneration for a registered missing device.
Passwords are generated disposable 32–128 character inputs in this experiment,
cleared from the form at submission, dropped by the page after postMessage, and
never put in local/session storage or URLs. The root/private provider stays in the
worker. There is no automatic unlock or retained-password retry. Missing, locked,
corrupt or wrong-password state remains denied and preserved.

Every open checks `/v1/session`, signed mode and the matching expected actor header;
then the worker checks the room directory and independently accepted pins. CF
admission does not enroll a decrypting device or grant execution authority. The
new IDB namespace is `family-mls-vault-synthetic-ui-ACTOR-ROOM`, with the driver's
existing restrictions. Per-tab metadata-only drafts have a separate
`family-vault-ui-draft-v1:ACTOR:ROOM` prefix. Draft ID/type/size/SHA are public local
metadata; short-content hashes can be guessable. Payload/private state is not
stored there. No stronger metadata confidentiality is claimed.

Explicit lock, hidden/pagehide, room edits and failures terminate the worker,
cancel boot/request/poll/expiry timers and fetches, reject pending calls, drop
cached page results, clear protected DOM and revoke Blob URLs. A separate
origin-scoped BroadcastChannel locks cooperating vault tabs too, including a
same-actor sibling. Incoming locks do not echo; stale callbacks cannot lock a
replacement session. Legacy UI tabs are not members of this new channel.
Structured-clone/worker/boot failures retire immediately. There is no active
worker handle left waiting for a timeout after failure.

The worker keeps its 256-storage-operation/session bound, 15-second per-DB/KDF
locks, default scrypt18 and exact encrypted-state CAS. No crypto primitive,
provider, state schema or dependency changes. UI requests have a 30-second
watchdog (legacy 12 seconds), boot 10 seconds, and synthetic unlock lifetime five
minutes. Idle native sync backs off 3/6/12/15 seconds (handshake stays 1.5 seconds);
manual “check new messages” invokes the same bounded worker path. Revocation and
remote account changes are discovered by the next admitted operation/poll, not
instantly at the directory write. Idle revocation detection can include the
15-second interval plus bounded I/O. Active operations still enforce native
admission and candidate isolation. Limits do not become human/mobile acceptance.

## Delivery and evidence

Text and up-to-8-KiB opaque files retain immutable IDs, exact file reselection,
separate staged/native-accepted/self-echo states, safe text rendering, authenticated
worker results and bounded inert file downloads. No full photo/video preview is
added. The native commit/ack barrier, old-epoch receive while updating, actual MLS
sender/inner-frame/AAD checks, encrypted whole-record CAS and uncertain-outbox
freeze are unchanged. Only committed worker results reach the display.

```sh
# Reuse the pinned WASM/native binaries and locked age/sodium driver build from
# ../device-keystore/NATIVE-VAULT.md. Generated data only.
.venv/bin/python tests/native_encrypted_browser_smoke.py --vault-ui \
  --bundle artifacts/mls-remapped-pkg --binary artifacts/family-dev-plain-final \
  --policy-binary artifacts/family-policy-mls-fixed
```

The DOM suite uses two owned persistent browser profiles. It tests generated
text/file delivery, bad pins, exact reselection, actual browser SIGKILL after a
lost native reply, stable keys/history, tampered native log, room/account/revocation
handling, encrypted-only IDB, wrong password, active sibling lock, late bootstrap,
corrupt actual-database state, immediate clone-failure retirement and idle work.
Explicit restoration of saved **synthetic ciphertext** is only negative-test setup;
it is not an active-leaf recovery feature. New runtime assets are uninstrumented;
page-only worker faults and generated proxy response loss remain identified in
proof JSON. Screenshots, passwords, keys and browser profiles are not CI uploads.

Same-origin malicious code/OS compromise, physical memory zeroization, full valid
store rollback after restart, human recovery and replacement devices remain
unqualified. Human keys/data, real CF login/settings, Yukson cutover, all12 fleet
credentials and existing services/backups remain unchanged. No new dependency is
installed or copied into the product bundle by this unit.
