# Account verification and application authority (synthetic integration)

This unit implements a CF-shaped JWT verifier and connects it to native room,
message, SSE and attachment admission through `chat.NewAccessHandler`. It is
**not deployed Cloudflare Access, a human login flow, or E2EE**. The default
`family-dev --synthetic-only` CLI uses public bearer fixtures. Explicit
`--auth-state` selects signed synthetic assertions exclusively, with private
persistent policy and live reload. The browser still uses fixture headers, so
signed mode is currently an API test mode, not a browser login flow. Tests use
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
Cgo/GCC/libc requirements remain. No JS, JWKS client, cookie/session, frontend
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
There is no JWKS network fetch/cache/refresh or automatic enrollment. Unavailable/
unknown keys fail closed. Bounded trusted key acquisition/rotation is the next
unit; no request chooses a key source URL.

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
HTTP writer proves that a queued identity replacement stops download after the
already admitted chunk. Unit cases cover wrong signature/algorithm/issuer/audience,
missing/expired/future claims, duplicate JSON/header attacks, org/service tokens,
input cloning, expiry, known-key rotation and old-grant retirement. Existing
native/browser/media/migration tests remain in CI.

Next: bounded trusted key acquisition and a reviewed browser identity handoff,
then E2EE/key recovery and production/mobile/backup acceptance. The user has not
answered the E2EE preference question, so E2EE remains required before human use.

## Private durable policy (synthetic only)

`family-policy` is an offline local configuration writer. It has no HTTP endpoint,
network fetch or private signing key. It accepts a complete immutable proposal:

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
