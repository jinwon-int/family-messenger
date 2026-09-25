//! Persisted-format migration hook (#177 M2: "0.9.0 → next release").
//!
//! Every store format this facade has written has exactly one upgrade path to the
//! current one, applied once at load ([`upgrade`]). A later OpenMLS release that
//! bumps `CURRENT_VERSION`, or a codec change, adds one arm here plus one fixture
//! test that loads the previous format and keeps talking to a peer.
//!
//! Format 1 (pre-M2): `openmls_memory_storage` entries — JSON keys and values.
//! Format 2 (M2): [`crate::store::Store`] entries — the same key layout
//! (`label ‖ encoded key ‖ u16 BE storage version`) and values, CBOR-encoded.
use crate::store::{EPOCH_KEY_PAIRS_LABEL, LABELS, LIST_LABELS, OWN_LEAF_NODE_INDEX_LABEL};
use openmls_traits::storage::CURRENT_VERSION;

pub(crate) const FORMAT_CURRENT: u32 = 2;

type Entries = Vec<(Vec<u8>, Vec<u8>)>;

/// Upgrade entries persisted in `version` to [`FORMAT_CURRENT`]; `None` rejects.
pub(crate) fn upgrade(version: u32, entries: Entries) -> Option<Entries> {
    match version {
        1 => v1_to_v2(entries),
        FORMAT_CURRENT => Some(entries),
        _ => None,
    }
}

/// Transcode one complete JSON value to CBOR.
fn cbor_of_json(json: &[u8]) -> Option<Vec<u8>> {
    let value: ciborium::Value = serde_json::from_slice(json).ok()?;
    let mut out = Vec::new();
    ciborium::into_writer(&value, &mut out).ok()?;
    Some(out)
}

/// Split a v1 key into (label, inner key) after checking the version suffix.
/// Labels are not prefixes of one another, so at most one matches.
fn split_key(key: &[u8]) -> Option<(&'static [u8], &[u8])> {
    let (body, suffix) = key.split_at(key.len().checked_sub(2)?);
    if suffix != CURRENT_VERSION.to_be_bytes() {
        return None;
    }
    let mut found = LABELS.iter().filter(|label| body.starts_with(label));
    let label = found.next()?;
    if found.next().is_some() {
        return None;
    }
    Some((label, &body[label.len()..]))
}

/// First JSON value of `bytes` as CBOR, plus the unparsed remainder.
fn leading_value(bytes: &[u8]) -> Option<(Vec<u8>, &[u8])> {
    let mut stream = serde_json::Deserializer::from_slice(bytes).into_iter::<ciborium::Value>();
    let value = stream.next()?.ok()?;
    let rest = &bytes[stream.byte_offset()..];
    let mut out = Vec::new();
    ciborium::into_writer(&value, &mut out).ok()?;
    Some((out, rest))
}

fn cbor_u64(value: u64) -> Vec<u8> {
    let mut out = Vec::new();
    ciborium::into_writer(&value, &mut out).expect("u64 encodes");
    out
}

/// v1 `EpochKeyPairs` inner key = `json(group_id) ‖ json(epoch) ‖ json(leaf)`,
/// concatenated without a separator, so `…}50` is epoch 5/leaf 0 or epoch 50/…
/// OpenMLS writes these only for the group's own leaf, recorded under
/// `OwnLeafNodeIndex`; that fixes the split. Anything else is rejected.
fn epoch_key_pairs_key(inner: &[u8], own_leaf: &[(Vec<u8>, u32)]) -> Option<Vec<u8>> {
    let (group_cbor, digits) = leading_value(inner)?;
    let group_json = &inner[..inner.len() - digits.len()];
    let (_, leaf) = own_leaf.iter().find(|(group, _)| group.as_slice() == group_json)?;
    let digits = std::str::from_utf8(digits).ok()?;
    let epoch = digits.strip_suffix(&leaf.to_string())?;
    // Canonical JSON integers only: no sign, no leading zero (except "0").
    if epoch.is_empty() || !epoch.bytes().all(|b| b.is_ascii_digit()) || (epoch.len() > 1 && epoch.starts_with('0')) {
        return None;
    }
    let mut out = group_cbor;
    out.extend(cbor_u64(epoch.parse().ok()?));
    out.extend(cbor_u64(u64::from(*leaf)));
    Some(out)
}

fn v1_to_v2(entries: Entries) -> Option<Entries> {
    // Pass 1: the own leaf index per group (json(group_id) -> leaf), for the split above.
    let mut own_leaf = Vec::new();
    for (key, value) in &entries {
        if let Some((label, inner)) = split_key(key) {
            if label == OWN_LEAF_NODE_INDEX_LABEL {
                own_leaf.push((inner.to_vec(), serde_json::from_slice::<u32>(value).ok()?));
            }
        }
    }
    let mut out = Vec::with_capacity(entries.len());
    for (key, value) in entries {
        let (label, inner) = split_key(&key)?;
        let inner = if label == EPOCH_KEY_PAIRS_LABEL {
            epoch_key_pairs_key(inner, &own_leaf)?
        } else {
            cbor_of_json(inner)?
        };
        let value = if LIST_LABELS.contains(&label) {
            // A list of individually encoded items: transcode each, then the list.
            let items: Vec<Vec<u8>> = serde_json::from_slice(&value).ok()?;
            let items = items.iter().map(|item| cbor_of_json(item)).collect::<Option<Vec<_>>>()?;
            let mut list = Vec::new();
            ciborium::into_writer(&items, &mut list).ok()?;
            list
        } else {
            cbor_of_json(&value)?
        };
        let mut new_key = label.to_vec();
        new_key.extend(inner);
        new_key.extend(CURRENT_VERSION.to_be_bytes());
        out.push((new_key, value));
    }
    Some(out)
}
