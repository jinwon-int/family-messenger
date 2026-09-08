# Account verification and application authority (synthetic integration)

This unit implements a CF-shaped JWT verifier and connects it to native room,
message, SSE and attachment admission through `chat.NewAccessHandler`. It is
**not deployed Cloudflare Access, a human login flow, or E2EE**. The runnable
`family-dev --synthetic-only` CLI still uses explicitly public bearer fixtures;
it has no production-auth flag. The signed integration runs only on disposable
loopback HTTP servers in Go tests, with RSA private keys generated in memory.
No production services, CF applications, user keys, databases or schemas change.

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
Only alg/kid/typ headers are accepted; token-controlled jku/jwk/x5u/crit and unknown
keys are rejected. No URL is fetched while checking a request. Service-token
common_name is rejected even if a subject is present. Signed email/role/group
claims cannot promote the local actor or owner flag.

Pinned keys are supplied as trusted in-process public-key objects. There is no
JWKS network fetch/cache/refresh, public-key file loader, or automatic enrollment
in this unit. Unavailable/unknown keys fail closed. Before production, implement
bounded trusted key acquisition/rotation and durable enrollment/revocation
configuration, with recovery and malicious-network tests. No restart durability
of an in-memory enrollment change is claimed.

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

Next: durable enrollment/key acquisition and a reviewed browser identity handoff,
then E2EE/key recovery and production/mobile/backup acceptance. The user has not
answered the E2EE preference question, so E2EE remains required before human use.
