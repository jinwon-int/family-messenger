# Public successor request handoff

The isolated `/successor-handoff/` page adds file import and explicit browser-local
list storage to the existing protected lifecycle UI. A handoff is JSON containing
`{version:1,scopes:[{identity,role,database,reservation}]}`. The preceding synthetic
ceremony supplies the exact accepted public reservation and local database name;
this page does not create a ceremony, identity, directory or private custody.

Import accepts at most eight descriptors and 32 KiB. Exact allowlists reject
unknown fields at every level, including credentials, providers, URLs and raw
packages. Only public signing keys and the original package digest occur in the
descriptor. Shape validation does not verify the fingerprint or grant authority:
the unchanged lifecycle worker checks the exact reservation against authenticated
protected storage and current server policy. Historical expiry remains a valid
hint so a participant can explicitly observe or close a persistent target.

No list is read on page startup. Users explicitly import or load, then select
scope and action and enter fresh credentials and mutation consent. Saving only
writes the versioned public-list localStorage key after an explicit click. A
new import does not overwrite the saved list. Lists are untrusted, including
same-origin concurrent changes; no storage event selects a scope or launches a
worker. Missing storage or write failure is reported without changing custody.
Public room/device metadata in this list is not encrypted.

Imports first lock the old action and clear selections. A generation invalidates
late file reads after another import/load, manual lock, cross-tab lock, page hide
or navigation. Interrupting an in-flight or unknown operation leaves a separate
visible uncertainty warning throughout this page lifetime; replacing/loading
public lists cannot acknowledge that earlier operation. Successful import displays an unverified-list message. Neither
import nor save claims current participation or possession. Providers, passwords,
pending messages and tombstones remain in unchanged protected stores.

The separate paired handoff browser proof starts from actual protected custody,
uses file input and buttons instead of page API injection, reopens saved lists
after actual browser crashes, rejects malformed/extended/duplicate descriptors,
and shows that a substituted target fails actual custody validation with zero
POST and unchanged saved state. All prior UI/enrollment/closure proofs remain.
No production asset activation, traffic or cutover is included.
