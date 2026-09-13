# Native messenger prototype

This Linux-only prototype tests our own storage and HTTP delivery contract. It is
**localhost-only and synthetic-data-only**. The default UI is plaintext with
three deliberately public test identities. Explicit signed mode and a separately
built [encrypted test UI](../archive/native-mls/server/ENCRYPTED-UI.md) are available; neither is human-use
authentication/E2EE acceptance.
Do not expose it through a proxy/tunnel or put real family messages in it.
Production Matrix services are not changed by building or running this code.

> **Frozen native MLS track (2026-09-13, decision D).** The `/v1/mls/*` transport,
> successor stages and compiled synthetic UI bundles described further down are no
> longer part of this build; their code, contracts and drivers live in
> [`archive/native-mls/`](../archive/native-mls/README.md). Schema migrations 3..12
> and the `mls_*` tables remain so existing databases open unchanged.

## Build and run

Use Go 1.27.x, a C compiler and Linux libc development headers. The direct external Go modules are `github.com/golang-jwt/jwt/v5` v5.3.1 (MIT)
and `github.com/mattn/go-sqlite3` v1.14.52 (MIT), with its bundled SQLite
(public domain, bundled SQLite 3.53.4). `go list -m all` currently contains **two external modules and
zero transitive Go modules**. SQLite is compiled into the app by cgo; a separate
SQLite server/package, Python, Docker, Matrix and Node.js are not runtime
requirements. The binary still depends on the host libc/loader. Go's standard
library and compiler have their own dependencies and BSD license; this is not a
claim of zero dependencies or a fully static executable. Distribute the
notices in `licenses/` with any binary copy.

From `server/`:

```sh
go mod download
go mod verify
go test -race ./...
go build -trimpath -o ../artifacts/family-dev ./cmd/family-dev
```

Prepare a **new empty** directory outside the checkout (absolute path, owned by
the current UID, mode 0700), then run:

```sh
mkdir -m 700 /absolute/new-synthetic-state
../artifacts/family-dev --synthetic-only --state /absolute/new-synthetic-state
```

Listen address is `127.0.0.1:18920`; other IPs are rejected. `--listen 127.0.0.1:0`
selects an ephemeral port. State files (including schema migration snapshots) must be regular, single-link, owned and
mode 0600. Symlinked paths, unsafe ancestors, unknown files/databases and a second
process using the same state directory are rejected. Files are preserved on exit;
there is no reset/delete command. Same-UID/root interference is outside this
prototype's filesystem boundary. SQLite may remove its own transaction journal
as part of committing; application data is not automatically deleted.

## Protocol v1 (experimental)

In default fixture mode, API requests require `Authorization: Bearer synthetic-alice` (or
`synthetic-bob`, `synthetic-charlie`). These strings are fixtures, **not secrets**.
The root page, `/app.js`, `/media.js` and `/app.css` are public synthetic assets embedded in the
binary. Browser API requests must be same-origin: an Origin header must exactly
match `http://127.0.0.1:<port>`, and Fetch Metadata may only be absent or
`same-origin` (`none` is accepted only for navigating static assets). Other
origins, cross-site/same-site requests and non-loopback Hosts are rejected.
The UI sends fixture bearer headers using fetch, including streamed SSE; it does
not put tokens in URLs. API clients without browser metadata remain supported.
Fixture requests omit cookies; there is no CORS, query-string token or production
login. Signed browser mode sends same-origin upstream cookies, while the app
verifies only the assertion header described in [AUTH.md](AUTH.md).

| Request | Behavior |
|---|---|
| `GET /v1/session` | Verified current actor/mode and explicit owner flag; no token/subject/email |
| `GET /health` | Authenticated synthetic-mode marker; not a disk/backup readiness check |
| `GET /v1/rooms` | List only rooms the authenticated fixture actor currently belongs to |
| `POST /v1/rooms` | JSON `{"id":"family","members":["bob"]}`; caller owns and joins the room |
| `PUT /v1/rooms/{room}/members/{actor}` | Owner adds a fixture actor; current members see all room history |
| `DELETE /v1/rooms/{room}/members/{actor}` | Owner revokes membership and existing streams; owner cannot remove self |
| `POST /v1/rooms/{room}/messages` | JSON `{"client_id":"unique-id","payload":"c3ludGhldGlj"}` |
| `GET /v1/rooms/{room}/messages?after=0` | Up to 100 messages ordered by room sequence; paginate using last seq |
| `GET /v1/rooms/{room}/events?after=0` | SSE history then live messages; `Last-Event-ID` overrides query cursor |

IDs use 1–64 ASCII letters/digits/underscore/hyphen. Payload is base64 of 1–16384
arbitrary bytes, stored as a BLOB. Base64 is **not encryption**; ciphertext/device
key metadata and crypto envelope versions are future protocol work. Actor IDs
are taken from the fixture token, not message input. Content is never executed.

On first send, a transaction inserts the message and increments the room sequence;
201 follows a successful durable commit. Retrying the same `(room, actor,
client_id)` and payload returns the original message/200. Reusing that key with a
different payload returns 409; retry after revocation returns 403. Delivery itself
is at least once: clients persist their last applied room sequence and deduplicate
on reconnect. A cursor ahead of stored history is rejected (400), not held until
history catches up. A send whose response was lost must reuse its client ID.

State uses SQLite DELETE journaling with FULL synchronous commits, foreign keys,
one connection and a lifetime flock. This deliberately starts with a simple
single-process writer; WAL/backup migration is later work. Room creation and sends
are transactional; schema/application markers prevent reuse of unrelated DBs.
Revocations serialize with history/SSE writes. Already written network bytes
cannot be recalled. Stream writes have a two-second deadline while holding the
ACL lock; a slow client can therefore briefly delay other operations. This is a
bounded correctness-first prototype, not a performance result.

Limits: 32 rooms, 10,000 total messages, 24 KiB request JSON, 16 simultaneous SSE
streams, 100 messages per replay batch, 30-second stream lifetime and 10-second
keepalives. Reconnect normally after EOF using the last applied sequence. Capacity
returns 507 without deleting history; these are test limits, not a production
storage policy. The executable bounds header/body/idle reads and stream writes.
A [private synthetic media API](MEDIA.md) now stores bounded attachments in SQLite
with migration snapshots and room checks. The UI verifies synthetic image/video preview and playback. It has no mobile
background delivery, retention, disk monitor,
production authentication, E2EE, account/device revocation, production backup/restore,
or fleet execution adapter yet.

## Verification

```sh
# from the repo root, after building
python3 tests/native_smoke.py --binary artifacts/family-dev
```

The smoke test spawns its own ephemeral loopback server with synthetic data;
there is no option to target an existing deployment. It preserves
`artifacts/native-live-*/verification.json` and the synthetic DB/logs, checking
SIGKILL/restart, retry/conflict, outsider rejection, live SSE, reconnect replay,
revocation during a stream and revocation across restart. Unit/HTTP tests add
concurrent writers, pagination, room isolation, path/permission/lock rejection
and stream capacity/release. CI also runs the race detector and both 022/077
umasks. Existing Matrix tests remain while production still uses that stack.

Next: read state;
then reviewed account authentication and E2EE/key recovery before human use,
and transport binding to the existing fleet worker/guardian.

## Own browser UI

Open the loopback address after starting the binary. Select Alice/Bob/Charlie,
create a room and choose other fixture members. Two separate browser contexts can
send synthetic text and attachments ([media protocol](MEDIA.md)); room owners can add/remove members. HTML-like message text
is rendered with `textContent`, never as markup. Same-origin static scripts/styles
use a restrictive CSP and no external fonts, CDN, npm packages or frontend build.
The runtime dependency inventory is unchanged.

Each selected room has one abortable fetch/SSE stream. Actor/room changes cancel
old streams, clear the transcript and discard stale responses. Reconnect uses the
last fully validated/applied sequence with bounded backoff (0.5–8 seconds). A
25-second per-attempt watchdog aborts missing headers or complete frames (server
keepalive is 10 seconds). Healthy streams reset backoff so normal 30-second EOF
rotation does not accumulate an eight-second gap. Browser background throttling
can delay timers; this is verified for foreground Chromium. A page
reload replays from zero because transcript data is not cached; at most the latest
200 received messages stay in the DOM. Membership rejection stops reconnect,
clears the visible transcript and disables sending. The room list is refreshed
manually; it is not polled in the background.

Before POST, the UI persists one immutable pending message ID/payload per actor
and room in **per-tab sessionStorage**. A lost response can be retried with the
same ID after reloading that tab; receipt of the corresponding committed event
or POST result clears it. Pending sends are never automatically re-executed by
reload. Closing the tab/clearing browser storage can lose that pending record;
this is not an offline mailbox or production durable device store. Public fixture
identity selection is not authentication. Browser storage contains synthetic
plaintext (base64 is not encryption).

```sh
# Test-only tooling; does not add Python/browser dependencies to the server.
python -m pip install -r requirements-native-test.txt
python -m playwright install chromium
python tests/native_browser_smoke.py --binary artifacts/family-dev
```

The test spawns only its own loopback server and two fresh Chromium contexts. It
verifies two-way text, safe markup rendering, real server restart/cursor replay,
a SIGSTOP stall before headers and during an open body with automatic recovery,
a committed POST whose response is deliberately dropped followed by same-ID retry
after reload, actor isolation, live membership removal, and a 390px layout without
horizontal overflow. Synthetic screenshots and a JSON receipt remain under
`artifacts/native-browser-*`. Playwright 1.62.0 and its Python/Chromium dependencies
are **test-only**; no claim is made about full Safari/Firefox/mobile background or
E2EE support. Do not initialize a human account in these disposable contexts.

## Signed account admission component

[AUTH.md](AUTH.md) describes the reviewed CF-shaped JWT/identity component and
real loopback HTTP tests for room/media admission and live retirement. The CLI
also supports an explicit private `--auth-state` for durable signed synthetic
policies; missing/invalid selected state fails without fixture fallback. The
browser uses the verified current actor in signed mode and retains the separate
public fixture selector only in fixture mode. This does not activate a Cloudflare
gate or implement a human login session. See AUTH.md for the policy CLI, reload
behavior, recovery limits and actual process acceptance.

The signed synthetic [MLS delivery boundary](../archive/native-mls/server/MLS-TRANSPORT.md) now provides
explicit reservations/group binding and a durable ordered opaque log. Existing
plaintext UI rooms remain separate from the explicitly selected synthetic encrypted
clients. These development modes do not qualify human-use E2EE or production login.

The separately selected [compiled custody UI](../archive/native-mls/server/VAULT-UI.md) embeds password-unlocked
synthetic encrypted storage at `/vault/`; human-use rollout remains gated.

The [two-device preparation boundary](../archive/native-mls/server/PREPARATION.md) adds an explicitly protected
new-conversation reservation. Both admitted devices must declare committed local
custody before native binding. Schema4 preserves a private prior snapshot; this
is a generated-data control prerequisite, not aggregate UI or human recovery.

The separate [compiled aggregate history profile](../archive/native-mls/server/AGGREGATE-HISTORY-UI.md)
serves the two-conversation `/aggregate/` chat and read-only `/aggregate-history/`
viewer from 20 pinned Go assets. It requires `synthetic_aggregate_history` and
explicit signed synthetic activation. Earlier asset modes and data are preserved;
archives never import an active sender or automatically resend pending messages.

[Successor reservations](../archive/native-mls/server/SUCCESSOR-RESERVATION.md) now allocate an immutable,
**inactive** replacement target through signed synthetic admission. Schema 5
snapshots prior v4 data before adding its reservation table. Both exact retries
and reads require current unexpired policy/source bindings; all ordinary native
routes deny these targets. Candidate activation is not yet
connected, and no existing UI silently selects this protocol.

[Paired successor custody declarations](../archive/native-mls/server/SUCCESSOR-CUSTODY.md) add per-role
immutable receipts and a separate readiness response. Schema 6 preserves a v5
snapshot and existing reservation bytes. Two declarations remain inactive;
paired private-client orchestration is described in [CLIENT-CUSTODY.md](../archive/native-mls/server/CLIENT-CUSTODY.md); activation and exact-package Welcome/ack remain.
See [verification evidence](../docs/evidence/server/successor-custody-evidence.json) for the synthetic
server/process scope and existing custody worker compatibility.

Paired experimental protected-store declaration orchestration and retry semantics
are documented in [CLIENT-CUSTODY.md](../archive/native-mls/server/CLIENT-CUSTODY.md). It does not activate a
successor or change production deployment.

The [restricted successor handshake relay](../archive/native-mls/server/SUCCESSOR-HANDSHAKE.md) adds ordered
exact-package/Welcome/ack slots after paired declarations. The opaque transcript
remains inactive; protected client integration and cryptographic completion are
still required before activation.
