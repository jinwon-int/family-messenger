//! Resident session (#177 §3.5, storage v2): the device and its store stay in WASM
//! memory between operations, and every operation hands back **only the changed
//! store entries** (the dirty set) instead of a full snapshot.
//!
//! Protocol with the JS worker (one IndexedDB transaction per operation, K3):
//!
//! 1. `apply(method, input)` → [`Step`] `{output, changes, epoch}`. The changes
//!    stay *in flight*; no further `apply` is accepted until 2 or 3.
//! 2. The worker writes `changes` + outbox/cursor in one IDB transaction, then
//!    calls `commit()`.
//! 3. If that transaction fails, `abort()` restores the pre-operation store and
//!    reloads the group, so the in-memory state again equals what is durable.
//!
//! A rejected operation (e.g. a forged or replayed ciphertext) is rolled back the
//! same way before the error is returned — OpenMLS may consume ratchet keys
//! before authentication fails, and those consumptions must not survive.
//!
//! Full serializations happen only in `open` (load) and `export`, counted by
//! `full_serializations()` so the M2 criterion "one message = at most one full
//! serialization" is measured, not assumed.
use super::*;

/// Wire framing for entries and changes: `u32 LE count`, then per entry
/// `u32 LE key_len ‖ key ‖ u32 LE value_len ‖ value`, where `value_len =
/// u32::MAX` (no value bytes) marks a deletion. Only `changes` may contain
/// deletions.
const DELETED: u32 = u32::MAX;
/// Largest framed entry set `open` accepts.
const OPEN_LIMIT: usize = 5 * staging::MAX_STATE;

pub(crate) fn frame(entries: &[(Vec<u8>, Option<Vec<u8>>)]) -> Vec<u8> {
    let size = 4 + entries.iter().map(|(k, v)| 8 + k.len() + v.as_ref().map_or(0, Vec::len)).sum::<usize>();
    let mut out = Vec::with_capacity(size);
    out.extend((entries.len() as u32).to_le_bytes());
    for (key, value) in entries {
        out.extend((key.len() as u32).to_le_bytes());
        out.extend(key);
        match value {
            Some(value) => {
                out.extend((value.len() as u32).to_le_bytes());
                out.extend(value);
            }
            None => out.extend(DELETED.to_le_bytes()),
        }
    }
    out
}

pub(crate) fn unframe(bytes: &[u8], allow_deletes: bool) -> Option<Vec<(Vec<u8>, Option<Vec<u8>>)>> {
    fn take<'a>(rest: &mut &'a [u8], n: usize) -> Option<&'a [u8]> {
        if rest.len() < n { return None; }
        let (head, tail) = rest.split_at(n);
        *rest = tail;
        Some(head)
    }
    fn word(rest: &mut &[u8]) -> Option<u32> {
        Some(u32::from_le_bytes(take(rest, 4)?.try_into().ok()?))
    }
    let mut rest = bytes;
    let count = word(&mut rest)? as usize;
    if count > staging::MAX_ENTRIES { return None; }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let key_len = word(&mut rest)? as usize;
        let key = take(&mut rest, key_len)?.to_vec();
        let value = match word(&mut rest)? {
            DELETED if allow_deletes => None,
            DELETED => return None,
            len => Some(take(&mut rest, len as usize)?.to_vec()),
        };
        out.push((key, value));
    }
    rest.is_empty().then_some(out)
}

/// Result of one operation; `changes` are in flight until `commit`/`abort`.
#[wasm_bindgen]
pub struct Step { output: Vec<u8>, changes: Vec<u8>, epoch: String }
#[wasm_bindgen]
impl Step {
    pub fn output(&self) -> Vec<u8> { self.output.clone() }
    pub fn changes(&self) -> Vec<u8> { self.changes.clone() }
    pub fn epoch(&self) -> String { self.epoch.clone() }
}

#[wasm_bindgen]
pub struct Session {
    device: Device,
    in_flight: bool,
    /// Group id at the last durable state (`None`: no group yet).
    baseline_group: Option<GroupId>,
    /// Loaded from an older format: the caller must replace every persisted
    /// entry with `export()` (keys are re-encoded, so old keys must go) and
    /// `commit()` once that transaction succeeded. Until then no `apply`.
    migrated: bool,
    full_serializations: u32,
}

impl Session {
    fn store(&self) -> &store::Store { self.device.provider.storage() }

    /// Would `open` accept the current store? (entry count, framed size)
    fn reopenable(&self) -> bool {
        let (count, bytes) = (self.store().len(), self.store().byte_size());
        count <= staging::MAX_ENTRIES && 4 + 8 * count + bytes <= OPEN_LIMIT
    }

    fn epoch(&self) -> String {
        self.device.group.as_ref().map(|g| g.epoch().as_u64().to_string()).unwrap_or_else(|| "none".into())
    }

    fn dispatch(&mut self, method: &str, input: &[u8]) -> Result<Vec<u8>, Rejected> {
        if input.len() > MAX_WIRE { return Err(rejected(())); }
        let device = &mut self.device;
        let output = match method {
            "key_package" if input.is_empty() => device.key_package_inner()?,
            "create" if input.is_empty() => { device.create_inner()?; vec![] },
            "invite" => device.invite_inner(input)?,
            "invite_with_commit" => device.invite_with_commit_inner(input)?,
            "join" => { device.join_inner(input)?; vec![] },
            "encrypt" => device.encrypt_inner(input)?,
            "decrypt" => device.decrypt_inner(input)?,
            "remove" => device.remove_member_inner(input, true)?,
            "remove_pending" => device.remove_member_inner(input, false)?,
            "commit" => { device.apply_commit_inner(input)?; vec![] },
            "merge_pending" if input.is_empty() => { device.merge_pending_inner()?; vec![] },
            "clear_pending" if input.is_empty() => { device.clear_pending_inner()?; vec![] },
            _ => return Err(rejected(())),
        };
        if output.len() > MAX_WIRE { return Err(rejected(())); }
        Ok(output)
    }

    /// Put the store back to its last committed state and reload the group
    /// object from it (the in-memory `MlsGroup` may hold consumed secrets).
    fn restore_committed(&mut self) -> Result<(), Rejected> {
        self.store().rollback();
        self.in_flight = false;
        if self.store().len() == 0 {
            // Aborted `create`: nothing durable exists; the session is unusable.
            self.device.retired = true;
            return Err(rejected(()));
        }
        self.device.group = match self.baseline_group.clone() {
            Some(id) => match MlsGroup::load(self.store(), &id) {
                Ok(Some(group)) => Some(group),
                _ => {
                    // Cannot happen for a committed state; refuse all further use.
                    self.device.retired = true;
                    return Err(rejected(()));
                }
            },
            None => None,
        };
        Ok(())
    }
}

#[wasm_bindgen]
impl Session {
    /// New identity. Its initial entries are in flight: persist, then `commit`.
    pub fn create(identity: &str) -> Result<Session, Rejected> {
        let provider = Provider::default();
        provider.storage().enable_journal();
        Ok(Session { device: Device::with_provider(identity, provider)?, in_flight: true, baseline_group: None,
            migrated: false, full_serializations: 0 })
    }

    /// Load from persisted entries (framed, no deletions) in store format
    /// `version`; format 1 is migrated in place (see `migrate`). An empty
    /// `group_id` means no group yet.
    pub fn open(identity: &str, public_key: &[u8], group_id: &[u8], version: u32, entries: &[u8]) -> Result<Session, Rejected> {
        bounded(entries, OPEN_LIMIT)?;
        let entries = unframe(entries, false).ok_or_else(|| rejected(()))?
            .into_iter().map(|(k, v)| (k, v.expect("no deletions"))).collect();
        let group_id = (!group_id.is_empty()).then(|| group_id.to_vec());
        let device = staging::restore(identity, public_key, group_id, version, entries)?;
        device.provider.storage().enable_journal();
        let baseline_group = device.group.as_ref().map(|g| g.group_id().clone());
        Ok(Session { device, in_flight: false, baseline_group, migrated: version != migrate::FORMAT_CURRENT,
            full_serializations: 1 })
    }

    /// Run one facade operation. On success the changes are in flight; on
    /// rejection the state is rolled back and the session stays usable.
    pub fn apply(&mut self, method: &str, input: &[u8]) -> Result<Step, Rejected> {
        if self.in_flight || self.migrated || self.device.retired { return Err(rejected(())); }
        match self.dispatch(method, input) {
            Ok(_) if !self.reopenable() => {
                // What `open` could not load must never become durable (the old
                // snapshot `save` enforced the same bounds).
                self.restore_committed()?;
                Err(Rejected("state limit"))
            }
            Ok(output) => {
                self.in_flight = true;
                Ok(Step { output, changes: frame(&self.store().changes()), epoch: self.epoch() })
            }
            Err(error) => {
                self.restore_committed()?;
                Err(error)
            }
        }
    }

    /// Changes currently in flight (after `create` or `apply`).
    pub fn pending_changes(&self) -> Vec<u8> { frame(&self.store().changes()) }

    /// The in-flight changes are durable: they become the new baseline.
    pub fn commit(&mut self) -> Result<(), Rejected> {
        if !self.in_flight || self.device.retired { return Err(rejected(())); }
        self.store().commit();
        self.in_flight = false;
        self.migrated = false;
        self.baseline_group = self.device.group.as_ref().map(|g| g.group_id().clone());
        Ok(())
    }

    /// Persisting the in-flight changes failed: return to the last durable state.
    pub fn abort(&mut self) -> Result<(), Rejected> {
        if !self.in_flight { return Err(rejected(())); }
        if self.migrated {
            // The format rewrite failed: the old-format entries are still what is
            // durable, and nothing in memory changed. Stay migrated.
            self.in_flight = false;
            return Ok(());
        }
        self.restore_committed()
    }

    /// Every entry, framed — the one full serialization (backup / format upgrade).
    pub fn export(&mut self) -> Result<Vec<u8>, Rejected> {
        if self.in_flight || self.device.retired { return Err(rejected(())); }
        // Exporting is how a migrated session is rewritten: the caller replaces
        // every old entry with this output in one transaction, then `commit`s
        // (or `abort`s). Until then the rewrite is in flight.
        if self.migrated { self.in_flight = true; }
        self.full_serializations += 1;
        let entries: Vec<_> = self.store().entries().into_iter().map(|(k, v)| (k, Some(v))).collect();
        Ok(frame(&entries))
    }

    pub fn current_epoch(&self) -> String { self.epoch() }
    pub fn public_key(&self) -> Vec<u8> { self.device.signer.public().to_vec() }
    pub fn group_id(&self) -> Vec<u8> {
        self.device.group.as_ref().map(|g| g.group_id().as_slice().to_vec()).unwrap_or_default()
    }
    pub fn has_pending_commit(&self) -> bool {
        self.device.group.as_ref().map(|g| g.pending_commit().is_some()).unwrap_or(false)
    }
    pub fn migrated(&self) -> bool { self.migrated }
    pub fn format_version() -> u32 { migrate::FORMAT_CURRENT }
    pub fn full_serializations(&self) -> u32 { self.full_serializations }
    pub fn entry_count(&self) -> u32 { self.store().len() as u32 }
    pub fn store_bytes(&self) -> u32 { self.store().byte_size() as u32 }
}

#[cfg(test)]
impl Session {
    /// Live store entries without counting a serialization (test comparison only).
    pub(crate) fn store_entries_for_test(&self) -> Vec<(Vec<u8>, Vec<u8>)> { self.store().entries() }
}
