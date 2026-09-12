# Native protected confirmation ceremony (synthetic only)

After actual saved-package Welcome exchange, `/confirmation-ceremony/` opens the
same protected stores with explicit actor, role, database, accepted request,
independently supplied canonical request digest, action, fresh password and
consent. Public files are untrusted scope hints. Authentication and the exact
current reservation/handshake remain enforced by the original workers. No new
keys, automatic scope selection, POST, retry, renewal or activation are added.

The original confirmation worker opens `create:false`, commits its private
transition before a POST and reconciles the immutable pending slot. Candidate
v2 becomes v3; peer v3 becomes v4. Full preceding source/provider/package/pending
bytes remain retained. No original store, validator, worker or server protocol
is changed. An unknown response never authorizes recreation or a new message.
Explicit reconciliation can send the same saved confirmation, so it is not
read-only. Lock/timeout/visibility retirement clears page credentials without
erasing committed custody. The uncertainty alert lasts for this page lifetime;
it is not a durable acknowledgement history after browser restart.

The public worker result has exact fields `committed, role, peer_verified,
phase, group_id, transcript_revision`. Only the selected role's result is shown:

| Role / revision | What is locally known | UI state |
| --- | --- | --- |
| candidate / 0 | Own ciphertext saved; no accepted receipt yet | candidate-saved |
| candidate / 1 | Own receipt retained; peer response not verified | candidate-recorded |
| candidate / 2 | Peer response verified and receive transition committed | candidate-verified |
| peer / 0 | Local context saved; candidate proof absent | awaiting-candidate |
| peer / 1 | Candidate frame verified; own reply pending | peer-reply-saved |
| peer / 2 | Candidate frame verified; own reply accepted and retained | peer-reply-recorded |

`peer_verified` is candidate revision 2 or peer revision >=1. A peer's accepted
reply cannot prove the candidate's final receive commit. Neither role's UI
result grants device admission. Providers/private keys never enter the page.
The original worker may send a pending slot and return a later revision within
one invocation; pending stages cannot be inferred from a failed invocation.

Profile12 (`synthetic_confirmation`, `--synthetic-confirmation-ui`) is a separate
22-file allowlist. It excludes preceding preparation/Welcome entrypoints and
bundled duplicate stores. This retains the existing 8KiB manifest, 2MiB file and
4MiB bundle limits; only old profile11 retains its already-qualified 12KiB
manifest exception. All eleven old manifests and asset bytes remain unchanged.
Explicit synthetic acknowledgement, signed auth-state, loopback bind and
mutually exclusive UI selection are required. The default binary has no payload.

The own-server proof first runs the real profile11 preparation, declarations
and Welcome DOM. It then explicitly restarts the same Go server with profile12,
retaining the same auth journal, server data and browser origin/private stores.
This is a generated operator fixture transition, not a new production profile
switching UI. Both profiles are separately pinned even in the dual-tag proof
binary. Normal confirmation actions use actual compiled page/worker bytes;
separate fixture aliases inject failed commits and inspect disposable private
cryptographic transitions. Public hints never seed private custody.

The old intact pair, candidate proposal creation and independent administrator
reservation/policy remain explicit fixtures. Full human creation/recovery,
global device enrollment, files, mobile and operational acceptance remain;
there is no production traffic, Matrix change or Yukson cutover in this unit.
