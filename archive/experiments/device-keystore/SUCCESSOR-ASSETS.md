# Compiled synthetic successor lifecycle

The `synthetic_successor` Go build and explicit `--synthetic-successor-ui` option
serve the handoff and lifecycle pages with their complete original worker graph.
Startup still requires `--synthetic-only`, loopback binding and explicitly chosen
signed `--auth-state`. Multiple UI selections fail. The ordinary binary contains
the small manifest but no successor asset payload; old bundles keep their pins.

Profile 7 contains exactly 23 public assets (under 4 MiB total): both pages, the
public handoff parser, lifecycle adapters, original compiled closure store, wire
validators, successor-lease WASM and required notices. It deliberately excludes
test drivers, instrumentation, general filesystem routes and old UI entrypoints.
Manifest source/URL/MIME/length/hash allowlists and canonical JSON are checked by
both build preparation and Go loading. Preparation retains existing, partial or
unknown outputs on error. No runtime directory is served.

Each asset fetch requires current signed actor admission. Same-origin CSP,
no-store, no-referrer, no-sniff and frame restrictions remain the shared server
contract. Static code access does not grant successor device authority: the
unchanged workers reopen actual protected custody and check current scoped
policy before any participation or closure operation. Users still explicitly
load/select requests and supply fresh credentials and consent. No new provider,
authorization, message send, automatic retry or recovery is introduced.

The paired compiled browser proof forwards normal lifecycle pages and worker
dependencies from the real Go service and compares every body with independently
read pinned source bytes. Both signed actors and unauthenticated denial cover
every asset route. The preceding custody ceremony remains a separate synthetic
fixture. Original raw fault entrypoints use a distinct fixture-store URL;
the explicit local commit failure uses a separately instrumented lifecycle
entrypoint. These paths cannot be mistaken for normally served compiled assets.

This is an explicitly selected synthetic preview, not a production deployment.
Global device directory, the complete human ceremony/recovery, files, mobile and
operational acceptance remain before a Yukson cutover.
