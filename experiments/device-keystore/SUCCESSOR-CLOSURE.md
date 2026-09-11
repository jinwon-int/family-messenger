# Persistent target participant closure

Either current participant can permanently close an explicitly activated
synthetic successor target, even after its original replacement intent expires.
The first valid request wins. The second participant need not be online or
consent. This closes only that target and does not enroll or revoke a global
device, change administrator policy, or delete keys and retained messages.

The new `/closure` GET/POST route requires the current activated successor,
current account/administrator/peer/source bindings, the exact immutable paired
enrollment digest in policy, and a matching saved reservation. It has no fallback
to an old lease or expired intent. Revoked policy denies even receipt reads;
protected local state and the server tombstone remain retained. Existing earlier
retirement tombstones continue to deny persistent use.

The signed semantic frame is
`["family-successor-closure",1,"persistent-target",role,SHA256(enrollment)]`,
where `enrollment` is the canonical complete paired server enrollment record.
The existing isolated signer uses its `family-successor-lease-v1\0` outer domain.
Enrollment, lease and earlier retirement signatures cannot authorize closure.
The request is deterministic from the immutable record and existing identity;
an unknown POST never causes generation of a new intent or request identifier.

Candidate v7 / peer v8 store a fresh closure request or observed receipt in a
terminal record. Separate closure workers reopen with `create:false`, validate
the complete original enrollment including its actual protected provider, and
commit under the existing local lock and compare-and-swap before POST. They sign
with the already saved enrolled provider. The full original source, original
KeyPackage, former provider and enrolled provider, counters, messages and pending
ciphertext stay frozen. Earlier enrollment workers reject this terminal format.
A public receipt cannot reconstruct missing private enrollment custody.

Schema 12 adds a mandatory closure slot for every reservation and a private
schema-11 migration snapshot. Under the same store mutex as message admission,
the first verified participant request becomes an immutable tombstone. Both
persistent enrollment and channel routes then reject access, including retries
of previously accepted messages. A valid request from the other participant
observes the first winner without replacing it. Missing or malformed closure
rows fail closed. SQL state, administrator policy and browser CAS remain separate
transactions; there is no distributed atomicity claim. A message already admitted
before server closure may remain in history. Local closure blocks that device
before remote closure; it cannot promise that the other participant is blocked
until the server commits. Current authority is rechecked for every server action.

Browser proof variants use both participants as the first closer after real
server expiry and a real prior Welcome/confirmation/enrollment exchange. They
retain an actual pending encrypted message, inject local commit failure, lost
POST/reply, malformed/domain-substituted/oversized/redirected responses, timeout,
worker/server restart, old-store rollback and policy revocation. Instrumentation
reports only hashes of complete retained protected records; original workers are
also executed. Server tests cover unilateral closure, exact immutable retries,
concurrent message admission, malformed/missing tombstones and schema migration.

This is still the synthetic 64-message scoped channel. Global device directory,
human recovery, files, mobile and operational acceptance remain before Yukson
cutover. No production service or traffic is changed by these experiments.
