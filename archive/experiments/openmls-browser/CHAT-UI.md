# Own encrypted synthetic chat page

`web/chat.html`, `chat.css` and `chat.js` connect an own browser UI to the existing
signed native API and version-4 durable crypto worker. Users can verify generated
device fingerprints, establish the fixed-pair room, send text and small files,
read committed history and reopen after interruption through ordinary controls.
No framework, new library, runtime daemon or Go/crypto change is introduced.

**Original PR34 proof boundary (retained):** the runnable test below serves an exact allowlist from a
loopback-only synthetic assertion proxy. Original UI/worker/WASM hashes are captured
before serving; UI bytes are not rewritten. This is not the Go binary's embedded
UI or a deployable authentication proxy. Existing legacy UI/assets are unchanged.
The subsequent [compiled native packaging](https://github.com/jinwon-int/family-messenger/blob/archive-frozen-20260917/archive/native-mls/server/ENCRYPTED-UI.md) adds
explicit signed synthetic activation; the production site and CF settings remain unchanged. Test profiles contain generated keys and messages
only, without protected at-rest keys or human recovery.

## Account, room and trust

The page bootstraps `/v1/session`, requires signed mode and an explicit Alice/Bob
principal with the same response actor, and supplies `X-Family-Actor` thereafter.
Unknown/fixture/failed bootstrap never falls back to fixture credentials. The
room must already be an authorized native MLS reservation; there is no UI policy
write or enrollment endpoint. Owner execution authority is not exposed here.

The native worker owns all crypto provider state and private keys. The page sees
only public own key/fingerprint and committed operation results. A user supplies
both independently accepted fingerprints; directory public material must match
these inputs before `pin`, and the worker revalidates the full binding against a
fresh signed directory. Inputs are not auto-filled from the directory. This is
an explicit **generated-data trust fixture**, not a human enrollment ceremony.
Existing pins restore from the worker; changed/revoked pins, missing registered
keys and wrong actor/room remain denied. No signing key replacement is supported.

Room editing immediately retires the old worker and clears the view before the
next connection. Reopen, page exit, hidden page, failed admission and worker error
terminate outstanding work and clear messages, selected input bytes and Blob
URLs. A generation check prevents stale callbacks from restoring an old view.
A hidden page requires explicit reconnect. Desktop Chromium viewport proof does
not establish real mobile/background lifecycle support.

## Sending, reconciliation and files

Send first writes only a small per-tab draft descriptor: version, actor, room,
immutable random operation ID, type, byte count and SHA-256. Neither plaintext
nor JWT/provider snapshots enter sessionStorage. SHA-256 identifies selected bytes;
it is not a new encryption or authentication scheme. The worker performs vetted
MLS encryption and atomically stores exact ciphertext/provider/outbox.

The page distinguishes durable encrypted staging, native server acceptance and
committed self-echo history. HTTP success alone never displays a completed local
message. If a native reply is lost, reopening loads the existing outbox and pulls
its exact accepted echo; a still-unaccepted stored operation has an explicit retry
button. If interruption occurred before the worker received the bytes, reopening
retains the descriptor and requires identical text/file bytes with the same ID.
A changed selection is denied. Text/file inputs are disabled during an active
send or durable pending operation, so completion cannot erase a newer draft.
When only a descriptor remains, these inputs stay enabled for exact reselection. Unknown/malformed descriptors are retained and
denied, not silently discarded or repaired. An actual accepted self echo clears
its matching tab descriptor. A retired stale outbox remains frozen as specified
in NATIVE-CONTROLS.md; there is no clear/reset/re-encrypt command.

Successful connections poll the ordered native log at a bounded 1.5-second cadence
with one UI pump at a time. Requests and worker calls have deadlines; an error
stops polling and requires explicit reopen. Initial KeyPackage/Welcome/ack controls
advance through the existing durable worker. A pending application is not blindly
resent by background polling. Timers, worker calls and fetches are retired on
identity/room/view transitions.

Text uses text nodes rather than HTML. Files are at most **8 KiB**, sent as existing
MLS application bytes; there is no new file cipher or separate plaintext upload.
Original filenames are not used as paths or active content. Download first obtains
a freshly admitted committed worker status, creates an application/octet-stream
Blob and uses an immutable synthetic filename. URLs are bounded by retained state
and promptly revoked on completion or view transitions. No HTML/SVG/image/video
preview or full-size attachment streaming is claimed. Past completed downloads
cannot be recalled by later revocation.

## Reproduction

```sh
.venv/bin/python tests/native_encrypted_browser_smoke.py --ui \
  --bundle artifacts/mls-control-pkg --binary artifacts/family-dev-mls-fixed \
  --policy-binary artifacts/family-policy-mls-fixed
```

The fixture drives two persistent Chromium profiles through DOM controls. It
covers independent fingerprint acceptance/rejection, actual native handshake,
encrypted text, inert small-file download/integrity, exact retry after lost reply,
interrupted pre-stage file reselection, receiver reload, ciphertext alteration
then original recovery, actor/room transitions, revocation, Blob cleanup, size
limits and 390-pixel layout. Synthetic screenshots stay local. CI uploads only
verification JSON, not profiles, keys, downloaded files or screenshots.

A disposable page hook drops one prepare command after descriptor persistence;
it does not retain the bytes or modify the production worker. Another tracks real
Blob URL creation/revocation. The generated test proxy can withhold/alter generated
native responses. `chat-ui-evidence.json` records source/served asset hashes and
proof paths. Native worker, WASM and server binaries are unchanged from PR33.

Compiled Go/static/WASM packaging is documented separately above. Remaining
work includes human key protection/recovery, device lifecycle, actual CF/mobile/backup
acceptance before Yukson production cutover. No family data or original fleet
credentials have moved, and Telegram remains the fallback.
