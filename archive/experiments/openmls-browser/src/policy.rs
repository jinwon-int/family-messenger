//! Policy v4 approval evidence (#177 §3.2·§3.6, `archive/native-mls/server/DEVICES-V4.md`):
//! the facade builds the canonical `ApprovalPayloadWire` bytes itself and signs the
//! domain-separated digest with the device's own Ed25519 key. The Go owner CLI
//! (`cmd/native-devices`) independently reconstructs the payload from the policy
//! chain and verifies the signature — identical canonical bytes are proven there,
//! not assumed here (byte-equal canonicalization is also pinned by a fixture test).
//!
//! Signing input = `"family-mls-v2/<action>\0" ‖ sha256(canonical payload)`; the
//! signer never signs arbitrary bytes. In v2 this is the ONLY policy signing surface
//! (§3.6: E2 add-device / E3 revoke evidence; no other labels are accepted).
use super::*;
use openmls_traits::signatures::Signer;

pub(crate) const ACTION_APPROVE: &str = "approve-device";
pub(crate) const ACTION_REVOKE: &str = "revoke-device";
const ACCEPTANCE_OUT_OF_BAND: &str = "out-of-band-fingerprint";
const ACCEPTANCE_TRUSTED: &str = "trusted-device-fingerprint";
const DOMAIN_PREFIX: &str = "family-mls-v2/";
/// Ed25519: 32-byte keys, 64-byte compact signatures (matches Go `crypto/ed25519`).
const KEY_HEX: usize = 64;
const KEY_BYTES: usize = 32;
const SIGNATURE_BYTES: usize = 64;

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes { out.push_str(format!("{byte:02x}").as_str()); }
    out
}

/// Exactly 64 lowercase hex chars → 32 raw bytes. Uppercase is rejected to mirror
/// the Go CLI (`DecodeSigningKey` round-trips the encoding, so `AB..` fails there).
fn decode_key_hex(encoding: &str) -> Result<[u8; KEY_BYTES], Rejected> {
    if encoding.len() != KEY_HEX { return Err(rejected(())); }
    let mut key = [0u8; KEY_BYTES];
    for (index, pair) in encoding.as_bytes().chunks(2).enumerate() {
        let high = (pair[0] as char).to_digit(16).ok_or_else(|| rejected(()))?;
        let low = (pair[1] as char).to_digit(16).ok_or_else(|| rejected(()))?;
        if !pair[0].is_ascii_lowercase() && !pair[0].is_ascii_digit() { return Err(rejected(())); }
        if !pair[1].is_ascii_lowercase() && !pair[1].is_ascii_digit() { return Err(rejected(())); }
        key[index] = (high * 16 + low) as u8;
    }
    Ok(key)
}

fn sha256(bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
    // The vetted provider path; small inputs only (keys and digests).
    RustCrypto::default().hash(HashType::Sha2_256, bytes).map_err(rejected)
}

/// Every canonical payload string must survive JSON serialization without any
/// escaping: identifiers are `valid_identity`, keys/fingerprints are lowercase
/// hex, actions/acceptances are fixed literals. This guard is what makes the
/// hand-rolled serializer byte-identical to Go's `json.Marshal` (which would
/// otherwise HTML-escape `<`, `>`, `&`).
fn canonical_safe(value: &str) -> Result<(), Rejected> {
    value.bytes().all(|byte| (0x20..=0x7e).contains(&byte) && byte != b'"' && byte != b'\\')
        .then_some(()).ok_or_else(|| rejected(()))
}

fn push_json_string(out: &mut Vec<u8>, value: &str) {
    out.push(b'"');
    out.extend_from_slice(value.as_bytes());
    out.push(b'"');
}

/// Fixed field order = canonical byte encoding; mirrors `devicepolicy.ApprovalPayloadWire`
/// exactly (`action, device_id, actor, subject, signing_key, fingerprint, acceptance,
/// base_revision`), compact, no spaces.
fn canonical_payload(action: &str, device_id: &str, actor: &str, subject: &str,
                     signing_key: &str, fingerprint: &str, acceptance: &str, base_revision: u64)
                     -> Result<Vec<u8>, Rejected> {
    for value in [action, device_id, actor, subject, signing_key, fingerprint, acceptance] {
        canonical_safe(value)?;
    }
    let mut out = Vec::with_capacity(192);
    out.extend_from_slice(b"{\"action\":");
    push_json_string(&mut out, action);
    out.extend_from_slice(b",\"device_id\":");
    push_json_string(&mut out, device_id);
    out.extend_from_slice(b",\"actor\":");
    push_json_string(&mut out, actor);
    out.extend_from_slice(b",\"subject\":");
    push_json_string(&mut out, subject);
    out.extend_from_slice(b",\"signing_key\":");
    push_json_string(&mut out, signing_key);
    out.extend_from_slice(b",\"fingerprint\":");
    push_json_string(&mut out, fingerprint);
    out.extend_from_slice(b",\"acceptance\":");
    push_json_string(&mut out, acceptance);
    out.extend_from_slice(b",\"base_revision\":");
    out.extend_from_slice(base_revision.to_string().as_bytes());
    out.push(b'}');
    Ok(out)
}

/// `"family-mls-v2/<action>\0" ‖ sha256(canonical payload)` — byte-identical to
/// `devicepolicy.ApprovalMessage` (pinned by the fixture test).
fn approval_message(action: &str, canonical: &[u8]) -> Result<Vec<u8>, Rejected> {
    let digest = sha256(canonical)?;
    let mut message = Vec::with_capacity(DOMAIN_PREFIX.len() + action.len() + 1 + digest.len());
    message.extend_from_slice(DOMAIN_PREFIX.as_bytes());
    message.extend_from_slice(action.as_bytes());
    message.push(0x00);
    message.extend_from_slice(&digest);
    Ok(message)
}

/// Everything computed before any state is touched: validation, canonical bytes and
/// the signing input. A rejection here is pure — the device stays usable.
struct Prepared { canonical: Vec<u8>, signature_input: Vec<u8> }

fn prepare_approval(action: &str, device_id: &str, actor: &str, subject: &str,
                    signing_key: &str, acceptance: &str, base_revision: u64,
                    own_key: &[u8], own_identity: &[u8]) -> Result<Prepared, Rejected> {
    if action != ACTION_APPROVE && action != ACTION_REVOKE { return Err(rejected(())); }
    // Stricter than the Go decoder (which leaves `subject` unconstrained): a subject
    // outside the identifier charset is rejected here so the canonical bytes can
    // never diverge from the CLI's reconstruction. Synthetic subjects qualify.
    if !valid_identity(device_id) || !valid_identity(actor) || !valid_identity(subject) {
        return Err(rejected(()));
    }
    // approve-device (E2) is always trusted-device acceptance; revoke-device (E3)
    // evidence carries the target's recorded acceptance, supplied by the operator
    // from `-inspect` output. Anything else is refused before bytes are built.
    let acceptance = match (action, acceptance) {
        (ACTION_APPROVE, ACCEPTANCE_TRUSTED) => ACCEPTANCE_TRUSTED,
        (ACTION_REVOKE, ACCEPTANCE_OUT_OF_BAND | ACCEPTANCE_TRUSTED) => acceptance,
        _ => return Err(rejected(())),
    };
    if base_revision < 1 { return Err(rejected(())); }
    let candidate = decode_key_hex(signing_key)?;
    // 자기 승인 거부 (defense in depth; `VerifyApproval` rejects it again CLI-side).
    // `candidate` and `own_key` are both Ed25519 seeds here.
    if candidate.as_slice() == own_key || device_id.as_bytes() == own_identity {
        return Err(rejected(()));
    }
    let fingerprint = hex_encode(&sha256(&candidate)?);
    let canonical = canonical_payload(action, device_id, actor, subject, signing_key,
                                      &fingerprint, acceptance, base_revision)?;
    let signature_input = approval_message(action, &canonical)?;
    Ok(Prepared { canonical, signature_input })
}

/// Framed evidence returned to the caller:
/// `u32 LE canonical_len ‖ canonical ‖ 64-byte Ed25519 signature`.
fn frame_evidence(prepared: &Prepared, signature: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + prepared.canonical.len() + signature.len());
    out.extend((prepared.canonical.len() as u32).to_le_bytes());
    out.extend_from_slice(&prepared.canonical);
    out.extend_from_slice(signature);
    out
}

/// `(identity, signing key)` pairs, sorted by identity.
pub(crate) type Roster = Vec<(Vec<u8>, Vec<u8>)>;

/// Sorted `(identity, signing key)` pairs from group members.
pub(crate) fn roster_from_members(members: impl Iterator<Item = Member>) -> Result<Roster, Rejected> {
    let mut roster = Vec::new();
    for member in members {
        if member.signature_key.len() != KEY_BYTES { return Err(rejected(())); }
        let basic = BasicCredential::try_from(member.credential.clone()).map_err(|_| rejected(()))?;
        roster.push((basic.identity().to_vec(), member.signature_key));
    }
    roster.sort();
    Ok(roster)
}

/// Sorted `(identity, signing key)` pairs from leaf nodes (staged Add proposals).
pub(crate) fn roster_from_leaves(leaves: impl Iterator<Item = LeafNode>) -> Result<Roster, Rejected> {
    let mut roster = Vec::new();
    for leaf in leaves {
        let key = leaf.signature_key().as_slice().to_vec();
        if key.len() != KEY_BYTES { return Err(rejected(())); }
        let basic = BasicCredential::try_from(leaf.credential().clone()).map_err(|_| rejected(()))?;
        roster.push((basic.identity().to_vec(), key));
    }
    roster.sort();
    Ok(roster)
}

/// Wire framing for `members`: `u32 LE count`, then per member
/// `u32 LE identity_len ‖ identity ‖ 32-byte signing key`, sorted by identity.
pub(crate) fn frame_members(roster: &[(Vec<u8>, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend((roster.len() as u32).to_le_bytes());
    for (identity, key) in roster {
        out.extend((identity.len() as u32).to_le_bytes());
        out.extend_from_slice(identity);
        out.extend_from_slice(key);
    }
    out
}

impl Device {
    /// The identity bytes of this device's basic credential.
    fn own_identity(&self) -> Result<Vec<u8>, Rejected> {
        match BasicCredential::try_from(self.credential.credential.clone()) {
            Ok(basic) => Ok(basic.identity().to_vec()),
            Err(_) => Err(rejected(())),
        }
    }

    /// The post-commit roster of the current group (read-only, no ratchet material).
    pub(crate) fn members_inner(&self) -> Result<Vec<u8>, Rejected> {
        let group = self.group.as_ref().ok_or_else(|| rejected(()))?;
        Ok(frame_members(&roster_from_members(group.members())?))
    }

    /// Review M2: the roster the group will have once the *pending* commit
    /// (`invite_with_commit` / `remove_member_pending`) is merged — current
    /// members minus its removes plus its adds. `members()` stays at the old
    /// epoch until `merge_pending`, so the outer v2 relay member list must be
    /// built from this one. Without a pending commit it equals `members()`.
    pub(crate) fn members_after_pending_inner(&self) -> Result<Vec<u8>, Rejected> {
        let group = self.group.as_ref().ok_or_else(|| rejected(()))?;
        let Some(pending) = group.pending_commit() else { return self.members_inner(); };
        let removed: Vec<LeafNodeIndex> = pending.remove_proposals().map(|p| p.remove_proposal().removed()).collect();
        let mut roster = roster_from_members(group.members().filter(|m| !removed.contains(&m.index)))?;
        roster.extend(roster_from_leaves(pending.add_proposals()
            .map(|p| p.add_proposal().key_package().leaf_node().clone()))?);
        roster.sort();
        roster.dedup();
        Ok(frame_members(&roster))
    }

    /// Signing only after pure preparation; an Ed25519 signature consumes no
    /// uncertain state, so only an actual signer failure retires (via `run`).
    fn sign_prepared(&mut self, prepared: &Prepared) -> Result<Vec<u8>, Rejected> {
        let signature = self.signer.sign(&prepared.signature_input).map_err(rejected)?;
        if signature.len() != SIGNATURE_BYTES { return Err(rejected(())); }
        Ok(frame_evidence(prepared, &signature))
    }
}

#[wasm_bindgen]
impl Device {
    /// sha256(public key) as lowercase hex — the out-of-band comparison value
    /// (DEVICES-V4.md `fingerprint`), byte-identical to the Go CLI's
    /// recomputation from the enrolled public key. Never the key itself.
    pub fn fingerprint(&self) -> Result<String, Rejected> {
        if self.retired { return Err(rejected(())); }
        let digest = sha256(self.signer.public())?;
        Ok(hex_encode(&digest))
    }

    /// Current group roster, framed (see `frame_members`): replicated into the
    /// outer commit JSON for the relay's membership enforcement and checked by
    /// the sender after merge (outer list == post-commit MLS membership).
    pub fn members(&self) -> Result<Vec<u8>, Rejected> {
        if self.retired { return Err(rejected(())); }
        self.members_inner()
    }

    /// Roster after the pending commit merges (M2); the list to replicate into
    /// the outer commit JSON *before* POSTing it. Same framing as `members`.
    pub fn members_after_pending(&self) -> Result<Vec<u8>, Rejected> {
        if self.retired { return Err(rejected(())); }
        self.members_after_pending_inner()
    }

    /// Build and sign one approval payload. `action` is `approve-device` (E2,
    /// fixed trusted-device acceptance) or `revoke-device` (E3, the target's
    /// recorded acceptance). Returns framed canonical bytes + signature; the
    /// harness hands them to the owner CLI as private evidence. Rejections from
    /// malformed input leave the device usable.
    #[allow(clippy::too_many_arguments)]
    pub fn sign_approval(&mut self, action: &str, device_id: &str, actor: &str, subject: &str,
                         signing_key: &str, acceptance: &str, base_revision: u64) -> Result<Vec<u8>, Rejected> {
        if self.retired { return Err(rejected(())); }
        let prepared = prepare_approval(action, device_id, actor, subject, signing_key,
                                        acceptance, base_revision, self.signer.public(),
                                        &self.own_identity()?)?;
        self.run(|s| s.sign_prepared(&prepared))
    }
}

/// sha256(signing key bytes) as lowercase hex, from a candidate's public key —
/// the value a human compares out-of-band (new-device screen ↔ trusted-device
/// screen ↔ CLI `-enroll-first` output). Same digest the payload pins.
#[wasm_bindgen]
pub fn policy_fingerprint(signing_key: &str) -> Result<String, Rejected> {
    let key = decode_key_hex(signing_key)?;
    Ok(hex_encode(&sha256(&key)?))
}
