# Account verification and application authority (synthetic integration)

[Version-2 public successor management](../archive/native-mls/server/SUCCESSORS.md) adds explicit private
candidate/decision records and atomic old-device retirement. It preserves v1
encoding, account/owner separation and the original admitted-device list.

This unit implements a CF-shaped JWT verifier and connects it to native room,
message, SSE and attachment admission through `chat.NewAccessHandler`. It is
**not deployed Cloudflare Access, a human login flow, or E2EE**. The default
`family-dev --synthetic-only` CLI uses public bearer fixtures. Explicit
`--auth-state` selects signed synthetic assertions exclusively, with private
persistent policy and live reload. The browser now discovers the explicit mode and bootstraps a verified principal
in signed mode. An isolated synthetic assertion proxy tests this handoff; no
human login or actual Cloudflare application is connected. Tests use
locally generated RSA keys and disposable loopback servers. No production
services, CF applications, human keys, chat databases or schemas change.

## Evidence and dependency choice

Official sources read 2026-09-09 KST:

- [CF application token](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/):
  identity assertions contain `type=app`, application `aud`, team `iss`, `sub`,
  `exp`, `iat`, `nbf`; signatures are RS256. The subject changes after deletion
  and re-enrollment in the CF organization. Service tokens have empty `sub` and
  `common_name`; they are a separate identity class.
- [CF validation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/):
  the origin receives `Cf-Access-Jwt-Assertion`; checking headers alone does not
  prove identity. Signing public keys are at the team's `/cdn-cgi/access/certs`.
- [golang-jwt v5.3.1](https://github.com/golang-jwt/jwt/releases/tag/v5.3.1), latest
  release observed 2026-09-09, performs JWT/signature validation. Its documented
  algorithm allowlist is explicitly used. This is authentication, not a new
  messaging encryption protocol.

There are now **two direct external Go modules and zero transitive Go modules**:
`github.com/golang-jwt/jwt/v5 v5.3.1` and `github.com/mattn/go-sqlite3 v1.14.52`.
Both are MIT, with bundled SQLite public-domain code and Go's own license.
`licenses/golang-jwt.txt` preserves the added notice; go.sum pins module content.
Cgo/GCC/libc requirements remain. No JS, third-party JWKS client, cookie/session, frontend
framework or database-server dependency is added. No resource/performance budget
has been measured by this authentication unit.

## Verification policy

`access.New(Config)` clones explicitly trusted issuer/audience, pinned RSA public
keys and an enrollment list. Keys have 2048–4096-bit positive odd moduli and
exponent 65537, at most 16 keys. At most 32 people map unique subjects to unique
stable app actor IDs; at most one has the explicit owner flag. Empty enrollment
is allowed to deny everyone. CF issuer must be an exact HTTPS team origin under
cloudflareaccess.com with no path, credentials, port, query or fragment. This is
one team/application per authority; using another team requires explicit trusted
configuration replacement, not a claim-driven URL lookup.

Requests must contain exactly one assertion header, at most 8 KiB. In signed
mode, Authorization headers (even alongside a valid assertion), cookie-only
credentials and unsigned email headers do not provide a fallback. Static synthetic
assets remain public; all API paths still use loopback Host and exact Origin/
Fetch Metadata checks. The existing fixture mode is a separate constructor,
never a fallback after JWT validation fails.

Require RS256, JWT type, a known kid, valid signature, exact issuer, expected
application audience, exp, non-future iat/nbf, exp after iat, app token type and an
enrolled subject. Zero clock leeway is used. JWT-library parsing plus duplicate
**top-level** JSON field rejection avoids ambiguous identity/header interpretation.
Security claim names use exact-key MapClaims; noncanonical case-fold aliases
(including Unicode folds) are rejected, avoiding Go struct JSON case insensitivity.
Only alg/kid/typ headers are accepted; token-controlled jku/jwk/x5u/crit and unknown
keys are rejected. No URL is fetched while checking a request. Service-token
common_name is rejected even if a subject is present. Signed email/role/group
claims cannot promote the local actor or owner flag.

Pinned keys can be supplied in-process or through the private policy store below.
Explicit management-only key acquisition is described below. There is no
request-driven network fetch, background refresh or automatic enrollment.
Unavailable/unknown keys fail closed; no request chooses a key source URL.

## Authority and room membership are separate

The resulting Principal contains the configured app actor and owner flag. A
valid assertion for an outsider still receives 403 from room/history/media APIs.
Room creation/ownership is chat administration; owning a room does not make a
person the system operator. `Grant.RunOwner` rejects family principals regardless
of token claims. No fleet execution endpoint exists yet (it returns 404); actual
execution additionally needs task/room/node binding, approval/cancel policy and
a separately authenticated machine principal. CF service tokens are not silently
mapped to humans or workers. The current Store still has only the three synthetic
actors, so this constructor rejects other actor mappings at API admission; a
reviewed persistent actor/enrollment migration is required for actual accounts.

`Authority.Replace` validates/clones a full trusted configuration before atomically
replacing it. It invalidates **all** existing grants, even if a removed person or
key is re-added. This is intentionally conservative; unchanged accounts reconnect
and authenticate again. Replacement waits for previously admitted bounded state/
write operations, not network upload reads or a full stream. Lock order is
identity authority then Store. No replacement path takes a Store lock.

Identity is rechecked before ordinary state operations, upload reservation/check/
commit, each SSE replay batch and each 32 KiB download chunk. JSON request bodies
are read with a 24 KiB/5-second bound **before** the authority lock, then admission
is checked again. Upload network reads hold neither identity authority nor chat
mutex. A revoked or expired pending upload cannot commit; removing and re-adding
an account does not revive the old request grant. HTTP tests prove both cases.

Expiration prevents the next admitted operation; a state operation/chunk already
admitted may complete within its existing bounds. Chunk writes are bounded to two
seconds, ordinary replies to five seconds. Database contention/read/commit also
has cost: these are not an absolute end-to-end revocation latency SLA. Once trusted
replacement returns, no old grant can admit another operation or write chunk.
SSE notices retirement on the next data/heartbeat (10 seconds); already delivered
bytes cannot be recalled. Responses started before retirement end/truncate rather
than appending a misleading success or error body to file content.

## Runnable synthetic acceptance

From server/, with the documented Go/C toolchain:

```sh
go test -count=1 -v ./internal/access
go test -count=1 -v ./internal/chat -run '^TestAccess'
go test -race -count=1 ./...
```

The chat tests use actual loopback TCP listeners, generated signed assertions and
private temporary SQLite state. They verify room/message/media success, outsider
and room-admin rejection, spoofed owner claims, header/bearer fallback rejection,
unknown subjects, live account removal, interrupted uploads across revoke/re-add
and expiry, a slow JSON body during revocation, and SSE retirement. A controlled
HTTP writer and a deterministic between-chunk gate prove that a completed
identity replacement stops download after the already admitted chunk. The test
does not assume mutex fairness or goroutine scheduling order. Unit cases cover wrong signature/algorithm/issuer/audience,
missing/expired/future claims, duplicate JSON/header attacks, org/service tokens,
input cloning, expiry, known-key rotation and old-grant retirement. Existing
native/browser/media/migration tests remain in CI.

Next: production identity/enrollment acceptance and refresh scheduling,
then E2EE/key recovery and production/mobile/backup acceptance. The user has not
answered the E2EE preference question, so E2EE remains required before human use.

## Private durable policy (synthetic only)

`family-policy` is a local configuration writer. It has no HTTP endpoint or
private signing key. Its explicit `--fetch-keys` mode performs one management
network request; `--input` and `--inspect` remain offline. It accepts a complete immutable proposal:

```json
{"version":1,"issuer":"https://synthetic.cloudflareaccess.com","audience":"synthetic-app","keys":[{"kid":"synthetic-key","n":"BASE64URL_RSA_MODULUS","e":65537}],"people":[{"subject":"synthetic-subject","actor":"alice","owner":true}]}
```

The modulus placeholder must be replaced with a generated synthetic RSA public
modulus. The process test below creates a runnable fixture; do not substitute
human accounts/keys. JSON is bounded to 64 KiB, depth eight, exact unique field
names at every depth, with unknown/case aliases and null rejected. Configuration
limits above apply; an empty people list intentionally denies everyone. Existing
chat actors remain alice/bob/charlie. This does not add arbitrary account creation.

Create separate **new** mode-0700 auth and proposal directories owned by the
current UID. Put a complete candidate JSON in a mode-0600, single-link regular
file in the proposal directory, and never edit it in place while a reader uses
it. Symlinks, unsafe parents, foreign owners and nonprivate modes are rejected.
The tool does not create/repair directories or reset existing data.

```sh
# From server/, alongside the existing family-dev build:
go build -trimpath -o ../artifacts/family-policy ./cmd/family-policy
../artifacts/family-policy --synthetic-only --auth-state /absolute/auth \
  --input /absolute/proposals/candidate.json --expected-revision 0
../artifacts/family-policy --synthetic-only --auth-state /absolute/auth --inspect
../artifacts/family-dev --synthetic-only --state /absolute/chat-state \
  --auth-state /absolute/auth --listen 127.0.0.1:0
```

The auth directory is independent of chat SQLite and migration snapshots. The
writer holds a cross-process exclusive flock across reading, revision comparison
and commit. Initial expected revision is zero; subsequent changes must name the
observed revision. Concurrent writers with the same expected revision cannot
both succeed. No automatic conflict retry or merge occurs. Output contains only
revision and hash, not subjects or keys.

Each successful update adds `policy-000001.json`, etc., without replacing earlier
revisions. Records contain the full policy, its canonical SHA-256 checksum and
the previous record's raw-byte SHA-256. The checksum detects accidental semantic
corruption of the latest record too; this chain is **not** a signature or witness
against an authorized local writer rewriting history. At most 64 records of
64 KiB each are accepted. Capacity fails closed; there is no automatic pruning or
compaction. An empty regular private `lock` is the only other accepted file.

Writes use a private random pending file, file fsync, rename to the next unused
revision and directory fsync under the lock. Success means durable commit under
the filesystem's fsync guarantees. Failure after writing is explicitly uncertain:
inspect retained state before any retry. A crash can leave a pending file or a
new visible revision without a success response. Pending/unknown files, gaps,
corrupt chains, symlinks, hardlinks and mode drift are preserved and reject the
whole policy; the reader never falls back to an older record. No application
routine deletes, edits or automatically restores policy records.

The selected auth state is validated **before opening chat state** at startup.
Missing/empty/invalid selected state exits; it never switches to public fixtures.
The CLI rereads under the policy lock every second. An unchanged valid revision
keeps current grants. A new valid revision replaces authority and retires all
old grants, including after re-enrollment or key re-addition. Polling, a two-second
file-lock wait and already-admitted bounded operations mean disk commit is not
instant live acknowledgement. Check the `auth revision applied N` log and
application admission to confirm application. No token/body is logged.

A failed refresh suspends identity admission and retires grants. Restoring file
permissions or the same revision does **not** reactivate this running process:
it requires a valid strictly newer revision beyond any observed revision floor.
Managed lock order is policy, identity authority, then Store. Network request
bodies still run outside identity/Store locks. Recovery requires inspection,
retention of damaged material, and deliberate repair followed by a new valid
revision; no automatic recovery command is provided. A complete chain must
validate again at startup. The live failure latch is in memory: full offline
rollback to an otherwise valid old directory prefix cannot be detected after
restart without a separate monotonic witness. Same-UID/root interference is
outside this cooperating-writer boundary; production rollback protection and
operator recovery acceptance remain future work.

```sh
# Repo root; Python standard library + OpenSSL are test-only tools.
python3 tests/native_policy_smoke.py --binary artifacts/family-dev \
  --policy-binary artifacts/family-policy
```

This spawns only fresh loopback processes and generated RSA identities. It proves
signed room/message/media access, no bearer/email fallback, durable removal and
re-enrollment, real SIGKILL/server restart, failed reload/same-revision rejection,
corrupt startup preserving bytes, concurrent CLI compare-and-swap and retained
chat/media/history. Unit fault injection separately covers interruption after
file sync and after rename; it does not emulate storage hardware power loss.
Artifacts stay in `artifacts/native-policy-*`; generated private signing fixtures
are synthetic, private and test-only. CI uploads only verification.json from
these directories, not signing keys or auth/chat state. No runtime module was
added by persistence; OpenSSL/Python are not server runtime dependencies.

## Explicit trusted key acquisition and rotation

The [official CF validation documentation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)
was checked again on 2026-09-09 KST. It documents a six-week default rotation,
seven days of previous-key validity, and the current/previous JWKs in `keys` at
`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`. Its `public_cert` and
`public_certs` are alternative PEM presentations. We read only the JWKs; PEM
metadata does not select keys or URLs. These are provider policy facts, not our
application's refresh schedule or a guarantee against manual emergency rotation.

After a private synthetic policy has been initialized, management can explicitly
fetch from **its configured issuer**, then commit at the observed revision:

```sh
../artifacts/family-policy --synthetic-only --auth-state /absolute/auth \
  --fetch-keys --expected-revision 1
```

This mode is mutually exclusive with `--input`/`--inspect`; it takes no source URL,
request token, cookie, proxy or TLS-bypass option. Do not use human account policy
for this prototype. The ordinary verification path never initiates network I/O,
including for repeated unknown kids. There is no background refresh task and no
request-driven retry/cache revalidation. Each explicit CLI invocation attempts
at most one GET; repeated or concurrent invocations are trusted local management
actions, not an exposed refresh API. Schedule/monitor integration before production
remains unfinished. No automated job was installed by this change.

The dedicated Go standard-library HTTP client verifies system TLS roots and the
issuer hostname, requires TLS 1.2+, ignores proxy environment variables, refuses
all redirects, requests uncompressed JSON and accepts only HTTP 200 with no
content encoding. DNS, dial, TLS, headers and body share a three-second request
budget; response headers are limited to 8 KiB, body to 64 KiB and the entire key
set to 1–16 keys. Bodies/connections close on success and failure. The configured
CF team origin is validated before any request; request-controlled issuer/jku/
x5u fields cannot select a destination. Test-only dialing/root injection is an
unexported helper, not a CLI/runtime configuration option.

JWKs require exact `kid/kty/alg/use/n/e`, RSA/RS256/signature use, canonical
base64url modulus, exponent AQAB (65537), and the existing 2048–4096-bit key limits.
Duplicate top-level/JWK field names, case aliases, duplicate kids, empty/oversized
sets, private key fields and unsupported key types reject the whole response;
there is no partial acceptance. Bounded opaque PEM metadata is ignored, never
interpreted or fetched. RSA construction uses Go's standard types and signature
verification remains golang-jwt; no new cryptographic protocol or module is added.

The operation reads the current complete policy under its existing lock, checks
the caller's expected revision, releases that lock for network I/O, then commits
with the **same** expected revision. Issuer/audience, enrollment and owner flags
are cloned unchanged; only the key set and its acquisition times change. Any
concurrent policy update, including removing a person, makes the result conflict
rather than overwrite that decision. Fetch failures never change policy, advance
a revision or extend key validity. Existing unknown/interrupted/corrupt policy
state remains fail-closed and preserved. Commit uncertainty still requires
inspection, as documented above. Disk commit is not live application; the server's
next successful policy reload retires all old grants.

A successful fetch stores `keys_fetched_at` at the start of the attempt and
`keys_expire_at` exactly one hour later. Response Cache-Control cannot extend this
hard lifetime. This is an application lease, not a CF key/certificate expiry.
Verification and **every Grant.Run**, including owner execution and each native
media/SSE authorization boundary, require the current time within that lease.
Even a longer-lived JWT or a previously issued grant stops admitting operations
at key expiry. Previously admitted bounded operations may finish as documented.
Successful replacement uses exactly the fetched key set, so keys omitted by the
trusted endpoint stop validating after application; previous keys remain accepted
only if the endpoint still supplies them. Every applied revision retires grants,
even if key IDs/material are unchanged or a removed key is re-added.

During an outage an already acquired, unexpired snapshot remains usable until its
stored deadline. No successful fetch means no extension. At expiry all signed
admission denies, including after restart, with no fallback to old manual pins or
public fixtures. Managed status/logs describe structural policy application, not
key-service health; `GET /health` is an unauthenticated liveness marker and says
nothing about identity admission — probe `/v1/session` for that. Operator
recovery needs a successful fetch/new revision or another deliberate complete
policy decision. Trusted system time is required, as it already is for JWT expiry.

Older explicit manual pinned policies omit both lease fields and retain their
existing manual lifetime; adding zero-valued optional fields does not change their
canonical checksum or rewrite their records. Both timestamps must be present and
form the exact one-hour interval when nonzero. A deliberate trusted manual policy
can remove the lease, but no acquisition/verification failure does this. New
leased records are rejected by older binaries that do not understand the fields;
there is no automatic backwards rewrite or rollback. No chat schema changes occur.

### Acceptance evidence

```sh
# server/; all servers/certificates/identities are locally generated fixtures.
go test -race -count=1 ./internal/access -run 'Test(JWKS|TrustedKey|KeyFetch|FetchedKey|Acquisition|AcquiredKeys)'
```

Real TLS listeners validate the exact CF hostname using a generated local root
and test-only loopback dialing. Tests cover hostname/root rejection, redirect and
status rejection, header/body bounds, truncated/compressed/invalid JWKS, canceled
and stalled header/body requests, preserved issuer/audience/enrollment/owner,
unknown-kid request flooding without new fetches, changed key material with reused
kid, old-grant retirement, hard expiry, durable expired-state restart, no lease
extension on failure and fetch/revocation CAS races. Application through the real
PolicyStore/Managed authority is checked separately from disk commit. Existing
room/media HTTP, process and browser regressions remain enabled. The network
acquisition CLI has not been run against a real CF team; no production gate or
human login is claimed. The actual-process policy smoke also checks expired
lease metadata across SIGKILL/restart, subsequent explicit fresh-lease application
with preserved membership/media, and CLI stale-revision/mixed-mode rejection.
The lease in that process smoke is a generated private proposal, while the TLS
fetch itself is exercised by the Go tests. This unit adds no runtime dependency.

## Signed browser identity handoff (synthetic proxy acceptance)

The root HTML now embeds an explicit `fixture` or `signed` mode from the server
constructor. Missing/unknown mode leaves controls disabled. It is a UI hint, not
an authorization decision: changing the HTML or actor selector cannot bypass the
signed server's JWT/actor/room checks. Both modes retain the visible synthetic-only
and no-E2EE notice. No alternate hostname, CORS rule or public binding was added.

Signed mode hides/disables public actor selection and calls authenticated
`GET /v1/session`. The JSON contains only `mode`, stable app `actor` and explicit
local `owner`; `X-Family-Actor` also identifies the verified response principal.
It exposes no assertion, subject, email or upstream cookie. The caller still needs
an enrolled subject, a current signing-key lease and a valid JWT. A family actor
claiming owner in its token remains `owner:false`; room administration and future
operator execution remain separate. No fleet execution endpoint is added.

Browser requests in signed mode use same-origin credentials so an upstream CF
session cookie can reach that upstream gate. The app still does **not** authenticate
cookies or email headers; it validates `Cf-Access-Jwt-Assertion`. The browser never
reads, constructs, stores or places a JWT in a URL. Redirected fetches fail rather
than treating a login page as an API response. Actual Cloudflare login/navigation,
Access application policies and deployment remain unconfigured by this unit.
Fixture mode alone sends public fixture bearer values and omits cookies.

After bootstrap, every app UI request carries `X-Family-Actor` naming the last
verified actor. The API checks a present header is unique and matches the current
verified principal **before** admitting mutations. A changed upstream account
therefore cannot send an old tab's pending operation as the new account. This is
an additional browser binding, not proof of identity; ordinary signed API clients
may omit it and are still attributed only to their verified JWT. Identity response
headers are checked by the UI too. Pending records have separate fixture/signed
namespaces and retain the existing per-tab actor/room/client-ID binding. Nothing
migrates fixture pending messages into signed mode. Reload/re-authentication never
automatically executes a pending send; returning to its actor requires explicit
same-ID retry and exact file reselection when bytes were lost.

Bootstrap attempts have generations and abort controllers; a superseded response
cannot overwrite a newer principal. Identity refresh/denial aborts old requests and
streams, clears rooms/transcript, form drafts and Blob previews, and disables send/
create controls. Any signed 401/403 conservatively clears the whole active view
(including room denial); the user explicitly rechecks identity to list still
permitted rooms. There is no automatic fixture fallback or automatic re-enrollment.
A transport outage retains normal bounded stream reconnect behavior. Changes are
detected on the next checked operation/bootstrap; an already admitted stream or
chunk follows the existing expiry/replacement bounds. Already downloaded files or
previously seen bytes cannot be recalled. Browser background suspension can delay
local cleanup; full mobile/session acceptance remains future work.

```sh
# Repo root; builds described above. Test dependencies only: Python/Playwright,
# Chromium and OpenSSL. It spawns only its own loopback services.
.venv/bin/python tests/native_signed_browser_smoke.py \
  --binary artifacts/family-dev --policy-binary artifacts/family-policy
```

The test proxy is **not a deployable authentication proxy**. Locally generated
opaque HttpOnly cookies map to synthetic subjects inside the test process; there
is no login/control/token-issuing HTTP endpoint. Only generated server-side RSA
assertions are injected upstream. Client Authorization/CF identity headers are
rejected. Proxy/server bind loopback, preserve exact Host/Origin checking, and the
proxy closes retained upstream streams and joins workers on shutdown. Private
signing fixtures and policy state are not uploaded as CI evidence.

Two Chromium contexts prove signed text, real generated PNG decoding, MP4 playback
and byte-exact download; lost-response/reload same-ID retry; upstream account change
rejecting a prior actor's pending send; durable removal/re-enrollment and expired
bootstrap clearing tracked Blob URLs; absent identity with no fallback; a late old
bootstrap unable to replace a newer actor; and SIGKILL/restart history recovery.
A 390px layout and absence of browser JS errors are checked. The unchanged fixture
browser/media suite remains in CI. Evidence is retained under
`artifacts/native-signed-browser-*`; CI uploads only verification JSON/screenshots.
No human account is initialized, no production CF gate is claimed, and E2EE is
still required before human use.

## Public first-device bindings

[DEVICES.md](DEVICES.md) specifies the optional durable device policy, immutable
first-device/tombstone rules and signed room directory. CF admission alone does
not enroll a decrypting device. The browser/library proof remains synthetic.
