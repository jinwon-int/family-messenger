# Private synthetic media API

The native prototype accepts attachment bytes with fixture room authorization.
This is **not E2EE or production file hosting**. The embedded UI can send attachments and open supported images/videos after
authorized integrity checks. Existing production services are unchanged.

## Storage choice and limits

For this bounded first implementation, metadata and payload BLOB are committed
in one SQLite row. This avoids a database/file rename transaction and separate
orphan-file recovery. No original filename is used as a path, and no upload
spool is written. New storage/runtime libraries are not required. The earlier
SQLite + media-directory design remains an option for larger production files;
this prototype does not establish its performance or final storage architecture.

Limits are 8 MiB per file, 128 MiB total ready/reserved bytes and 128 ready/reserved
objects. The HTTP adapter admits at most two uploads and two downloads at once.
Uploads are buffered in bounded memory outside the chat mutex and then verified
before one durable database write. Downloads snapshot a bounded BLOB and verify
its checksum before sending bytes. Go/SQLite may make internal copies, so these
request limits are not an exact memory/RSS budget. DB commit/read and hashing
still have costs; large-file throughput has not been benchmarked.

There is no automatic deletion, retention or garbage collection. Rejecting an
incomplete/invalid upload discards only uncommitted in-memory bytes. Existing
metadata/BLOBs and migration snapshots remain. Partial uploads are not resumable;
retry the whole payload with its original upload ID. No attachment is executed.

## Requests

All paths are under `/v1/rooms/{room}/attachments`, using the same explicit bearer
fixture authentication and strict same-origin/loopback gates as chat. No public
file URL, token-in-URL, CORS, range request or inline content serving is added.

`POST /v1/rooms/{room}/attachments` uses a raw body and these headers:

| Header | Contract |
|---|---|
| `Content-Length` | Required, positive, at most 8388608; chunked/unknown length is rejected |
| `Content-Type` | Lowercase valid MIME type without parameters; descriptive only |
| `X-Upload-ID` | 1–64 ASCII letters/digits/underscore/hyphen, scoped to room and actor |
| `X-File-Name` | UTF-8 percent-encoded display filename, e.g. `sample%20file.bin`; decoded max 180 bytes, no path separators/control/format characters |
| `X-Content-SHA256` | Lowercase 64-character hexadecimal SHA-256 of the actual bytes |

A successful first commit returns 201 with metadata (`id`, `room`, `actor`,
`client_id`, `filename`, `media_type`, `size`, `sha256`, `created_ms`). IDs are
random server-assigned 128-bit hexadecimal strings. Retry after a lost response
must repeat the original headers and full bytes: identical content returns the
same ID/metadata with 200. Changed metadata for the same scoped ID returns 409;
a body that does not match the declared digest returns 422, including on retry.
The retry also rechecks the stored BLOB: corruption returns 422 and is preserved,
never silently overwritten or acknowledged as healthy. Concurrent reuse of an
active ID returns 409 to retry later. Quota returns 507,
transfer capacity 429 and invalid length/metadata 400. Retries after membership
revocation return 403.

`GET /v1/rooms/{room}/attachments` lists only that room's committed metadata for
current members. `GET /v1/rooms/{room}/attachments/{id}` returns verified bytes
only for current members. An ID from another room is not usable. Downloads always
use `application/octet-stream`, `Content-Disposition: attachment`, `nosniff`, a
sandbox CSP, a content length and `X-Content-SHA256`; user MIME does not enable
HTML/SVG execution. Clients must check both full length and digest before using
any download. File extensions/MIME labels are not malware or semantic validation.

Upload reads use a two-second read-progress deadline and 30-second overall bound.
Membership is checked between reads and again before commit; a revoke/re-add
invalidates the old transfer lease. Downloads recheck membership/lease between
32 KiB chunks with two-second write deadlines and a 30-second overall bound.
The chat mutex is held only around each bounded write/ACL check, and queued
operations get a scheduling opportunity between chunks. Already written network
bytes cannot be recalled. Revocation/error after response headers causes a
truncated transfer, not a misleading JSON error appended to the file.

## Schema upgrade and recovery

The new binary accepts recognized schema 1 or 2 databases with the existing
application ID. Unknown state is rejected before SQLite recovery. Upgrading
schema 1 first creates a fresh mode-0600 recovery copy in a mode-0700 `snapshots/`
directory with `VACUUM INTO`, flushes the file/directories, then adds attachments
and changes `user_version` to 2 in one transaction. Existing messages/rooms/
members are retained. Fresh empty installations do not need a pre-upgrade copy.

Snapshot files are named `v1-before-media-{random-id}.sqlite`. A failed attempt
never overwrites or deletes a prior file. A partial snapshot may therefore remain;
**do not treat filename existence as proof of a valid recovery point**. Inspect
`PRAGMA integrity_check`, schema version and expected rows on a separate copy.
After four preserved attempts, automatic migration stops for inspection instead
of producing unbounded recovery files. Symlinks, hardlinks, unexpected entries,
wrong owners/modes, and orphan snapshots/journals with no recognized DB are rejected.

A schema-1 binary cannot read the upgraded schema-2 file. To roll back, stop the
prototype, preserve its current entire state directory, copy a verified pre-media
snapshot into a **new** private state directory as `messages.sqlite`, and start
the older binary there. The copy predates all post-upgrade messages/media; that
later data is still in the preserved original directory. No automatic destructive
restore is offered. These local snapshots are not encrypted/off-node backups and
are not a substitute for the future production backup/key recovery plan.

## Evidence

Go tests exercise checksum/retry/conflict, quota reservation, concurrent active
IDs, upload interruption without a chat lock, revoke/re-add leases, per-chunk
download revocation, corrupt BLOB rejection, snapshot preservation and schema
migration/reopen. Run:

```sh
python3 tests/native_media_smoke.py --binary artifacts/family-dev
# Optional: additionally verify rollback with a pre-media executable kept locally.
python3 tests/native_media_smoke.py --binary artifacts/family-dev --old-binary /absolute/old-family-dev
```

This spawns only disposable loopback processes with generated PNG, a generated
blue MP4 and synthetic binary data. It checks hashes, duplicate/conflicting
requests, room denial, SIGKILL during an incomplete upload, committed file
survival, revocation and snapshot restoration in a separate directory. Evidence
is preserved under `artifacts/native-media-*`. Browser preview/playback is verified separately by the test below.

## Browser attachment protocol and limits

`media.js` is embedded with the other assets; no new runtime/build libraries.
Each new UI payload is UTF-8 `\x1eFAMILY/1\n` followed by JSON, then the normal
wire base64. `{"type":"text","text":"..."}` escapes text even if it starts with
the reserved marker. `{"type":"attachment","attachment":{...}}` contains the
exact uploaded metadata object. Existing unframed UTF-8 remains literal text;
legacy bytes that start with the reserved marker occupy the new protocol namespace.
Invalid/unknown framed values show an unsupported-format placeholder. This is an
experimental UI envelope, not server validation or encryption: the server retains
opaque bytes. Other clients can send fabricated references; the UI checks room,
sender, exact canonical stored metadata, length and hash before using them.
Only the original uploading actor can present their attachment as their message
in this UI. Forwarding/captions are not implemented; text and files are separate.

One pending message per actor/room/tab is retained in sessionStorage. Before the
first upload the UI records an immutable upload ID, filename/type/size/SHA-256 and
separate message ID. A received upload response becomes an immutable message
payload in sessionStorage **before** POSTing the message. Upload success alone is
not displayed as message delivery. Explicit retry repeats the original IDs. If
reloaded before the upload response was saved, the same file must be reselected;
name, MIME, size and digest must match. If the message payload was already saved,
no file reselection or new upload occurs. A failed storage write stops progress;
closing the tab/clearing storage can lose the pending record. Successfully stored
but unsent attachments consume quota; no silent deletion/cancellation is offered.

Files are fetched with bearer headers, full length and SHA verified, then a fresh
membership check is made before creating a Blob URL. Exactly one preview/download
Blob (at most 8 MiB encoded bytes) and one media read are active per view; selecting
another file revokes the previous URL. Room/actor switches, revocation, and removal
of the preview message from the 200-message window clear it. Each download button
performs a fresh authorized read; URLs/credentials are never public server links.
Network reads have a 35-second deadline. Decoded image/video memory and browser
internal copies are additional costs, not an asserted 8 MiB total memory budget.

Only PNG/JPEG/WebP and MP4/WebM get image/video elements; other types (including
HTML/SVG) are download-only as octet-stream. CSP only adds `img-src blob:` and
`media-src blob:`; scripts, frames and objects remain restricted. Browser codecs
may reject unsupported content. Opening files in external programs is outside
this prototype. No antivirus or semantic file safety guarantee is claimed.
Already received/saved bytes cannot be recalled; SSE membership rejection clears
the live view, with foreground reconnect/heartbeat timing as in the README.

Run `python tests/native_media_browser_smoke.py --binary artifacts/family-dev`
with the test-only Playwright environment. It spawns its own loopback server and
two Chromium contexts: generated PNG decode, MP4 playback to ended, exact download,
interrupted/lost upload and lost message responses across reload with stable IDs,
wrong-file retry, forged metadata/cross-room envelope, modified download rejection,
active SVG exclusion, size limit, real restart/history, object URL cleanup, actor
switch/removal and 390px layout. Evidence is `artifacts/native-media-browser-*`.
This is not a real Android/iOS device or background playback qualification.
