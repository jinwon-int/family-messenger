//! Storage v2 (#177 §3.5): an OpenMLS 0.9 `StorageProvider` owned by this crate.
//!
//! Vendored from `openmls_memory_storage` 0.6.0 (MIT, Copyright (c) OpenMLS
//! Authors) — `src/lib.rs` from `impl MemoryStorage` onward — with exactly these
//! mechanical changes, so the diff against upstream stays auditable:
//!
//! 1. **Codec**: the local `serde_json` module below is a CBOR (RFC 8949) shim.
//!    Every upstream `serde_json::…` call site now encodes keys and values as
//!    binary, self-describing CBOR (OpenMLS 0.9 does not support
//!    non-self-describing formats). Decoding rejects trailing bytes.
//! 2. **Dirty set**: the key/value map is a [`Journaled`] map that remembers the
//!    original value of every key touched since the last [`Store::commit`],
//!    so a caller persists only what changed (no full snapshot per operation) and
//!    can [`Store::rollback`] a rejected operation in place.
//! 3. [`LABELS`]/[`LIST_LABELS`] and two label constants are `pub(crate)` for the
//!    format-1 migration hook (`crate::migrate`). The two `entry()` helpers (`append`, `remove_item`) use `get` + `insert`,
//!    `thiserror` / `log` / `test-utils` code is removed, `MemoryStorage` is renamed
//!    [`Store`], and `values` is private — nothing outside reads its internals.
//!
//! Upstream semantics (key layout, list handling, deletes) are otherwise unchanged.
#![allow(unexpected_cfgs)]

use openmls_traits::storage::*;
use serde::Serialize;
use std::{collections::HashMap, sync::RwLock};

/// CBOR stand-in for the upstream `serde_json` calls (see module docs, change 1).
mod serde_json {
    #[derive(Debug)]
    pub struct Error;

    pub fn to_vec<T: serde::Serialize + ?Sized>(value: &T) -> Result<Vec<u8>, Error> {
        let mut out = Vec::new();
        ciborium::into_writer(value, &mut out).map_err(|_| Error)?;
        Ok(out)
    }

    pub fn from_slice<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, Error> {
        let mut cursor = std::io::Cursor::new(bytes);
        let value = ciborium::from_reader(&mut cursor).map_err(|_| Error)?;
        if cursor.position() as usize != bytes.len() {
            return Err(Error);
        }
        Ok(value)
    }
}

/// Every (non-draft-feature) label this store writes, for `crate::migrate`.
pub(crate) const LABELS: &[&[u8]] = &[
    KEY_PACKAGE_LABEL, PSK_LABEL, ENCRYPTION_KEY_PAIR_LABEL, SIGNATURE_KEY_PAIR_LABEL,
    EPOCH_KEY_PAIRS_LABEL, TREE_LABEL, GROUP_CONTEXT_LABEL, INTERIM_TRANSCRIPT_HASH_LABEL,
    CONFIRMATION_TAG_LABEL, JOIN_CONFIG_LABEL, OWN_LEAF_NODES_LABEL, GROUP_STATE_LABEL,
    QUEUED_PROPOSAL_LABEL, PROPOSAL_QUEUE_REFS_LABEL, OWN_LEAF_NODE_INDEX_LABEL,
    EPOCH_SECRETS_LABEL, RESUMPTION_PSK_STORE_LABEL, MESSAGE_SECRETS_LABEL,
];
/// Labels whose value is a list of individually encoded items (`append`).
pub(crate) const LIST_LABELS: &[&[u8]] = &[OWN_LEAF_NODES_LABEL, PROPOSAL_QUEUE_REFS_LABEL];

/// One change produced by an operation: the new value, or `None` for a delete.
pub type Change = (Vec<u8>, Option<Vec<u8>>);

/// Key/value map that journals the pre-image of every key it mutates.
#[derive(Debug, Default)]
struct Journaled {
    map: HashMap<Vec<u8>, Vec<u8>>,
    /// key -> value before the first mutation since the last commit/rollback.
    journal: HashMap<Vec<u8>, Option<Vec<u8>>>,
    /// Off for stores nobody commits (the memory-only `Device` and the per-call
    /// snapshot API), so their journal cannot grow with every key ever touched.
    enabled: bool,
}

impl Journaled {
    fn touch(&mut self, key: &[u8]) {
        let Self { map, journal, enabled } = self;
        if *enabled && !journal.contains_key(key) {
            journal.insert(key.to_vec(), map.get(key).cloned());
        }
    }

    fn get(&self, key: &[u8]) -> Option<&Vec<u8>> {
        self.map.get(key)
    }

    fn insert(&mut self, key: Vec<u8>, value: Vec<u8>) -> Option<Vec<u8>> {
        self.touch(&key);
        self.map.insert(key, value)
    }

    fn remove(&mut self, key: &[u8]) -> Option<Vec<u8>> {
        self.touch(key);
        self.map.remove(key)
    }
}

#[derive(Debug, Default)]
pub struct Store {
    values: RwLock<Journaled>,
}

impl Store {
    /// Rebuild a store from persisted entries. Duplicate or empty keys/values are
    /// rejected. The journal starts empty: loading is not a change.
    pub fn from_entries(entries: impl IntoIterator<Item = (Vec<u8>, Vec<u8>)>) -> Option<Self> {
        let mut map = HashMap::new();
        for (key, value) in entries {
            if key.is_empty() || value.is_empty() || map.insert(key, value).is_some() {
                return None;
            }
        }
        Some(Self { values: RwLock::new(Journaled { map, journal: HashMap::new(), enabled: false }) })
    }

    /// Start journaling (resident sessions only): from now on every mutation is
    /// reported by [`Store::changes`] and undone by [`Store::rollback`].
    pub fn enable_journal(&self) {
        self.values.write().unwrap().enabled = true;
    }

    /// Every live entry, sorted by key. This is the one full serialization; the
    /// per-operation path is [`Store::changes`].
    pub fn entries(&self) -> Vec<(Vec<u8>, Vec<u8>)> {
        let values = self.values.read().unwrap();
        let mut entries: Vec<_> = values.map.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        entries.sort_by(|a, b| a.0.cmp(&b.0));
        entries
    }

    pub fn len(&self) -> usize {
        self.values.read().unwrap().map.len()
    }

    /// Total bytes of live keys and values.
    pub fn byte_size(&self) -> usize {
        self.values.read().unwrap().map.iter().map(|(k, v)| k.len() + v.len()).sum()
    }

    /// Keys whose value differs from the pre-image since the last commit/rollback,
    /// sorted by key. The journal is kept: follow with [`Store::commit`] once the
    /// changes are durable, or [`Store::rollback`]. Rewrites to the same bytes and
    /// insert-then-delete of a fresh key are not changes.
    pub fn changes(&self) -> Vec<Change> {
        let values = self.values.read().unwrap();
        let mut changes: Vec<Change> = values
            .journal
            .iter()
            .filter_map(|(key, before)| {
                let now = values.map.get(key).cloned();
                (&now != before).then(|| (key.clone(), now))
            })
            .collect();
        changes.sort_by(|a, b| a.0.cmp(&b.0));
        changes
    }

    /// Accept the current state as the new baseline (empties the journal).
    pub fn commit(&self) {
        self.values.write().unwrap().journal.clear();
    }

    /// Restore every pre-image recorded since the last commit/rollback.
    pub fn rollback(&self) {
        let mut values = self.values.write().unwrap();
        let journal = std::mem::take(&mut values.journal);
        for (key, before) in journal {
            match before {
                Some(value) => values.map.insert(key, value),
                None => values.map.remove(&key),
            };
        }
    }
}

impl Store {
    /// Internal helper to abstract write operations.
    #[inline(always)]
    fn write<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
        value: Vec<u8>,
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let mut values = self.values.write().unwrap();
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());


        values.insert(storage_key, value.to_vec());
        Ok(())
    }

    fn append<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
        value: Vec<u8>,
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let mut values = self.values.write().unwrap();
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());


        // fetch value from db, falling back to an empty list if it doesn't exist
        let mut list: Vec<Vec<u8>> = match values.get(&storage_key) {
            Some(list_bytes) => serde_json::from_slice(list_bytes)?,
            None => vec![],
        };
        list.push(value);
        values.insert(storage_key, serde_json::to_vec(&list)?);

        Ok(())
    }

    fn remove_item<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
        value: Vec<u8>,
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let mut values = self.values.write().unwrap();
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());


        // fetch value from db, falling back to an empty list if it doesn't exist
        let mut list: Vec<Vec<u8>> = match values.get(&storage_key) {
            Some(list_bytes) => serde_json::from_slice(list_bytes)?,
            None => vec![],
        };
        if let Some(pos) = list.iter().position(|stored_item| stored_item == &value) {
            list.remove(pos);
        }
        values.insert(storage_key, serde_json::to_vec(&list)?);

        Ok(())
    }

    /// Internal helper to abstract read operations.
    #[inline(always)]
    fn read<const VERSION: u16, V: Entity<VERSION>>(
        &self,
        label: &[u8],
        key: &[u8],
    ) -> Result<Option<V>, <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let values = self.values.read().unwrap();
        let storage_key = build_key_from_vec::<VERSION>(label, key.to_vec());


        let value = values.get(&storage_key);

        if let Some(value) = value {
            serde_json::from_slice(value)
                .map_err(|_| MemoryStorageError::SerializationError)
                .map(|v| Some(v))
        } else {
            Ok(None)
        }
    }

    /// Internal helper to abstract read operations.
    #[inline(always)]
    fn read_list<const VERSION: u16, V: Entity<VERSION>>(
        &self,
        label: &[u8],
        key: &[u8],
    ) -> Result<Vec<V>, <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let values = self.values.read().unwrap();

        let mut storage_key = label.to_vec();
        storage_key.extend_from_slice(key);
        storage_key.extend_from_slice(&u16::to_be_bytes(VERSION));


        let value: Vec<Vec<u8>> = match values.get(&storage_key) {
            Some(list_bytes) => serde_json::from_slice(list_bytes).unwrap(),
            None => vec![],
        };

        value
            .iter()
            .map(|value_bytes| serde_json::from_slice(value_bytes))
            .collect::<Result<Vec<V>, _>>()
            .map_err(|_| MemoryStorageError::SerializationError)
    }

    /// Internal helper to abstract delete operations.
    #[inline(always)]
    fn delete<const VERSION: u16>(
        &self,
        label: &[u8],
        key: &[u8],
    ) -> Result<(), <Self as StorageProvider<CURRENT_VERSION>>::Error> {
        let mut values = self.values.write().unwrap();

        let mut storage_key = label.to_vec();
        storage_key.extend_from_slice(key);
        storage_key.extend_from_slice(&u16::to_be_bytes(VERSION));


        values.remove(&storage_key);

        Ok(())
    }
}

/// Errors thrown by the key store (upstream variants kept verbatim).
#[allow(dead_code)]
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum MemoryStorageError {
    UnsupportedValueTypeBytes,
    UnsupportedMethod,
    SerializationError,
}

impl std::fmt::Display for MemoryStorageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::UnsupportedValueTypeBytes => "The key store does not allow storing serialized values.",
            Self::UnsupportedMethod => "Updating is not supported by this key store.",
            Self::SerializationError => "Error serializing value.",
        })
    }
}

impl std::error::Error for MemoryStorageError {}

const KEY_PACKAGE_LABEL: &[u8] = b"KeyPackage";
const PSK_LABEL: &[u8] = b"Psk";
const ENCRYPTION_KEY_PAIR_LABEL: &[u8] = b"EncryptionKeyPair";
const SIGNATURE_KEY_PAIR_LABEL: &[u8] = b"SignatureKeyPair";
pub(crate) const EPOCH_KEY_PAIRS_LABEL: &[u8] = b"EpochKeyPairs";

// related to PublicGroup
const TREE_LABEL: &[u8] = b"Tree";
const GROUP_CONTEXT_LABEL: &[u8] = b"GroupContext";
#[cfg(feature = "extensions-draft")]
const APPLICATION_EXPORT_TREE_LABEL: &[u8] = b"ApplicationExportTree";
#[cfg(feature = "virtual-clients-draft")]
const VC_EMULATION_EPOCH_STATE_LABEL: &[u8] = b"VcEmulationEpochState";
#[cfg(feature = "virtual-clients-draft")]
const VC_EMULATION_BINDING_LABEL: &[u8] = b"VcEmulationBinding";
#[cfg(feature = "virtual-clients-draft")]
const REGISTERED_VC_EMULATION_EPOCH_LABEL: &[u8] = b"RegisteredVcEmulationEpoch";
#[cfg(feature = "virtual-clients-draft")]
const VC_OPERATION_TREE_LABEL: &[u8] = b"VcOperationTree";
#[cfg(feature = "virtual-clients-draft")]
const RETAINED_KEY_PACKAGE_MATERIAL_LABEL: &[u8] = b"RetainedKeyPackageMaterial";
#[cfg(feature = "virtual-clients-draft")]
const RETAINED_KEY_PACKAGE_EPOCH_LABEL: &[u8] = b"RetainedKeyPackageEpoch";
const INTERIM_TRANSCRIPT_HASH_LABEL: &[u8] = b"InterimTranscriptHash";
const CONFIRMATION_TAG_LABEL: &[u8] = b"ConfirmationTag";

// related to MlsGroup
const JOIN_CONFIG_LABEL: &[u8] = b"MlsGroupJoinConfig";
const OWN_LEAF_NODES_LABEL: &[u8] = b"OwnLeafNodes";
const GROUP_STATE_LABEL: &[u8] = b"GroupState";
const QUEUED_PROPOSAL_LABEL: &[u8] = b"QueuedProposal";
const PROPOSAL_QUEUE_REFS_LABEL: &[u8] = b"ProposalQueueRefs";
pub(crate) const OWN_LEAF_NODE_INDEX_LABEL: &[u8] = b"OwnLeafNodeIndex";
const EPOCH_SECRETS_LABEL: &[u8] = b"EpochSecrets";
const RESUMPTION_PSK_STORE_LABEL: &[u8] = b"ResumptionPsk";
const MESSAGE_SECRETS_LABEL: &[u8] = b"MessageSecrets";

impl StorageProvider<CURRENT_VERSION> for Store {
    type Error = MemoryStorageError;

    fn queue_proposal<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
        QueuedProposal: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
        proposal: &QueuedProposal,
    ) -> Result<(), Self::Error> {
        // write proposal to key (group_id, proposal_ref)
        let key = serde_json::to_vec(&(group_id, proposal_ref))?;
        let value = serde_json::to_vec(proposal)?;
        self.write::<CURRENT_VERSION>(QUEUED_PROPOSAL_LABEL, &key, value)?;

        // update proposal list for group_id
        let key = serde_json::to_vec(group_id)?;
        let value = serde_json::to_vec(proposal_ref)?;
        self.append::<CURRENT_VERSION>(PROPOSAL_QUEUE_REFS_LABEL, &key, value)?;

        Ok(())
    }

    fn write_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        TreeSync: traits::TreeSync<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        tree: &TreeSync,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            TREE_LABEL,
            &serde_json::to_vec(&group_id).unwrap(),
            serde_json::to_vec(&tree).unwrap(),
        )
    }

    fn write_interim_transcript_hash<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        InterimTranscriptHash: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        interim_transcript_hash: &InterimTranscriptHash,
    ) -> Result<(), Self::Error> {
        let mut values = self.values.write().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id);
        let value = serde_json::to_vec(&interim_transcript_hash).unwrap();

        values.insert(key, value);
        Ok(())
    }

    fn write_context<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupContext: traits::GroupContext<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_context: &GroupContext,
    ) -> Result<(), Self::Error> {
        let mut values = self.values.write().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(GROUP_CONTEXT_LABEL, group_id);
        let value = serde_json::to_vec(&group_context).unwrap();

        values.insert(key, value);
        Ok(())
    }

    fn write_confirmation_tag<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ConfirmationTag: traits::ConfirmationTag<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        confirmation_tag: &ConfirmationTag,
    ) -> Result<(), Self::Error> {
        let mut values = self.values.write().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(CONFIRMATION_TAG_LABEL, group_id);
        let value = serde_json::to_vec(&confirmation_tag).unwrap();

        values.insert(key, value);
        Ok(())
    }

    fn write_signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
        SignatureKeyPair: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
        signature_key_pair: &SignatureKeyPair,
    ) -> Result<(), Self::Error> {
        let mut values = self.values.write().unwrap();
        let key =
            build_key::<CURRENT_VERSION, &SignaturePublicKey>(SIGNATURE_KEY_PAIR_LABEL, public_key);
        let value = serde_json::to_vec(&signature_key_pair).unwrap();

        values.insert(key, value);
        Ok(())
    }

    fn queued_proposal_refs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<ProposalRef>, Self::Error> {
        self.read_list(PROPOSAL_QUEUE_REFS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn queued_proposals<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
        QueuedProposal: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<(ProposalRef, QueuedProposal)>, Self::Error> {
        let refs: Vec<ProposalRef> =
            self.read_list(PROPOSAL_QUEUE_REFS_LABEL, &serde_json::to_vec(group_id)?)?;

        refs.into_iter()
            .map(|proposal_ref| -> Result<_, _> {
                let key = (group_id, &proposal_ref);
                let key = serde_json::to_vec(&key)?;

                let proposal = self.read(QUEUED_PROPOSAL_LABEL, &key)?.unwrap();
                Ok((proposal_ref, proposal))
            })
            .collect::<Result<Vec<_>, _>>()
    }

    fn tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        TreeSync: traits::TreeSync<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<TreeSync>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(TREE_LABEL, group_id);

        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        let value = serde_json::from_slice(value).unwrap();

        Ok(value)
    }

    fn group_context<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupContext: traits::GroupContext<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupContext>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(GROUP_CONTEXT_LABEL, group_id);

        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        let value = serde_json::from_slice(value).unwrap();

        Ok(value)
    }

    fn interim_transcript_hash<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        InterimTranscriptHash: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<InterimTranscriptHash>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(INTERIM_TRANSCRIPT_HASH_LABEL, group_id);

        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        let value = serde_json::from_slice(value).unwrap();

        Ok(value)
    }

    fn confirmation_tag<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ConfirmationTag: traits::ConfirmationTag<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ConfirmationTag>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(CONFIRMATION_TAG_LABEL, group_id);

        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        let value = serde_json::from_slice(value).unwrap();

        Ok(value)
    }

    fn signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
        SignatureKeyPair: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<Option<SignatureKeyPair>, Self::Error> {
        let values = self.values.read().unwrap();

        let key =
            build_key::<CURRENT_VERSION, &SignaturePublicKey>(SIGNATURE_KEY_PAIR_LABEL, public_key);

        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        let value = serde_json::from_slice(value).unwrap();

        Ok(value)
    }

    fn write_key_package<
        HashReference: traits::HashReference<CURRENT_VERSION>,
        KeyPackage: traits::KeyPackage<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &HashReference,
        key_package: &KeyPackage,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(&hash_ref).unwrap();
        let value = serde_json::to_vec(&key_package).unwrap();

        self.write::<CURRENT_VERSION>(KEY_PACKAGE_LABEL, &key, value)
            .unwrap();

        Ok(())
    }

    fn write_psk<
        PskId: traits::PskId<CURRENT_VERSION>,
        PskBundle: traits::PskBundle<CURRENT_VERSION>,
    >(
        &self,
        psk_id: &PskId,
        psk: &PskBundle,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            PSK_LABEL,
            &serde_json::to_vec(&psk_id).unwrap(),
            serde_json::to_vec(&psk).unwrap(),
        )
    }

    fn write_encryption_key_pair<
        EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &EncryptionKey,
        key_pair: &HpkeKeyPair,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            ENCRYPTION_KEY_PAIR_LABEL,
            &serde_json::to_vec(public_key).unwrap(),
            serde_json::to_vec(key_pair).unwrap(),
        )
    }

    fn key_package<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        KeyPackage: traits::KeyPackage<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<Option<KeyPackage>, Self::Error> {
        let key = serde_json::to_vec(&hash_ref).unwrap();
        self.read(KEY_PACKAGE_LABEL, &key)
    }

    fn psk<PskBundle: traits::PskBundle<CURRENT_VERSION>, PskId: traits::PskId<CURRENT_VERSION>>(
        &self,
        psk_id: &PskId,
    ) -> Result<Option<PskBundle>, Self::Error> {
        self.read(PSK_LABEL, &serde_json::to_vec(&psk_id).unwrap())
    }

    fn encryption_key_pair<
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
        EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>,
    >(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<Option<HpkeKeyPair>, Self::Error> {
        self.read(
            ENCRYPTION_KEY_PAIR_LABEL,
            &serde_json::to_vec(public_key).unwrap(),
        )
    }

    fn delete_signature_key_pair<
        SignaturePublicKeuy: traits::SignaturePublicKey<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKeuy,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            SIGNATURE_KEY_PAIR_LABEL,
            &serde_json::to_vec(public_key).unwrap(),
        )
    }

    fn delete_encryption_key_pair<EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>>(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            ENCRYPTION_KEY_PAIR_LABEL,
            &serde_json::to_vec(&public_key).unwrap(),
        )
    }

    fn delete_key_package<KeyPackageRef: traits::HashReference<CURRENT_VERSION>>(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        #[cfg(feature = "virtual-clients-draft")]
        {
            let serialized_ref = serde_json::to_vec(&hash_ref)?;
            self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_MATERIAL_LABEL, &serialized_ref)?;
            self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_EPOCH_LABEL, &serialized_ref)?;
        }
        self.delete::<CURRENT_VERSION>(KEY_PACKAGE_LABEL, &serde_json::to_vec(&hash_ref)?)
    }

    fn delete_psk<PskKey: traits::PskId<CURRENT_VERSION>>(
        &self,
        psk_id: &PskKey,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(PSK_LABEL, &serde_json::to_vec(&psk_id)?)
    }

    fn group_state<
        GroupState: traits::GroupState<CURRENT_VERSION>,
        GroupId: traits::GroupId<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupState>, Self::Error> {
        self.read(GROUP_STATE_LABEL, &serde_json::to_vec(&group_id)?)
    }

    fn write_group_state<
        GroupState: traits::GroupState<CURRENT_VERSION>,
        GroupId: traits::GroupId<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_state: &GroupState,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            GROUP_STATE_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(group_state)?,
        )
    }

    fn delete_group_state<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(GROUP_STATE_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn message_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MessageSecrets: traits::MessageSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MessageSecrets>, Self::Error> {
        self.read(MESSAGE_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_message_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MessageSecrets: traits::MessageSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        message_secrets: &MessageSecrets,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            MESSAGE_SECRETS_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(message_secrets)?,
        )
    }

    fn delete_message_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(MESSAGE_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn resumption_psk_store<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ResumptionPskStore: traits::ResumptionPskStore<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ResumptionPskStore>, Self::Error> {
        self.read(RESUMPTION_PSK_STORE_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_resumption_psk_store<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ResumptionPskStore: traits::ResumptionPskStore<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        resumption_psk_store: &ResumptionPskStore,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            RESUMPTION_PSK_STORE_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(resumption_psk_store)?,
        )
    }

    fn delete_all_resumption_psk_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(RESUMPTION_PSK_STORE_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn own_leaf_index<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNodeIndex: traits::LeafNodeIndex<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<LeafNodeIndex>, Self::Error> {
        self.read(OWN_LEAF_NODE_INDEX_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_own_leaf_index<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNodeIndex: traits::LeafNodeIndex<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        own_leaf_index: &LeafNodeIndex,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            OWN_LEAF_NODE_INDEX_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(own_leaf_index)?,
        )
    }

    fn delete_own_leaf_index<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(OWN_LEAF_NODE_INDEX_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn group_epoch_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupEpochSecrets: traits::GroupEpochSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupEpochSecrets>, Self::Error> {
        self.read(EPOCH_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_group_epoch_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupEpochSecrets: traits::GroupEpochSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_epoch_secrets: &GroupEpochSecrets,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            EPOCH_SECRETS_LABEL,
            &serde_json::to_vec(group_id)?,
            serde_json::to_vec(group_epoch_secrets)?,
        )
    }

    fn delete_group_epoch_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(EPOCH_SECRETS_LABEL, &serde_json::to_vec(group_id)?)
    }

    fn write_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
        key_pairs: &[HpkeKeyPair],
    ) -> Result<(), Self::Error> {
        let key = epoch_key_pairs_id(group_id, epoch, leaf_index)?;
        let value = serde_json::to_vec(key_pairs)?;

        self.write::<CURRENT_VERSION>(EPOCH_KEY_PAIRS_LABEL, &key, value)
    }

    fn encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<Vec<HpkeKeyPair>, Self::Error> {
        let key = epoch_key_pairs_id(group_id, epoch, leaf_index)?;
        let storage_key = build_key_from_vec::<CURRENT_VERSION>(EPOCH_KEY_PAIRS_LABEL, key);

        let values = self.values.read().unwrap();
        let value = values.get(&storage_key);


        if let Some(value) = value {
            return Ok(serde_json::from_slice(value).unwrap());
        }

        Ok(vec![])
    }

    fn delete_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<(), Self::Error> {
        let key = epoch_key_pairs_id(group_id, epoch, leaf_index)?;
        self.delete::<CURRENT_VERSION>(EPOCH_KEY_PAIRS_LABEL, &key)
    }

    fn clear_proposal_queue<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        // Get all proposal refs for this group.
        let proposal_refs: Vec<ProposalRef> =
            self.read_list(PROPOSAL_QUEUE_REFS_LABEL, &serde_json::to_vec(group_id)?)?;
        let mut values = self.values.write().unwrap();
        for proposal_ref in proposal_refs {
            // Delete all proposals.
            let key = serde_json::to_vec(&(group_id, proposal_ref))?;
            values.remove(&key);
        }

        // Delete the proposal refs from the store.
        let key = build_key::<CURRENT_VERSION, &GroupId>(PROPOSAL_QUEUE_REFS_LABEL, group_id);
        values.remove(&key);

        Ok(())
    }

    fn mls_group_join_config<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MlsGroupJoinConfig>, Self::Error> {
        self.read(JOIN_CONFIG_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn write_mls_join_config<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        config: &MlsGroupJoinConfig,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(group_id).unwrap();
        let value = serde_json::to_vec(config).unwrap();

        self.write::<CURRENT_VERSION>(JOIN_CONFIG_LABEL, &key, value)
    }

    fn own_leaf_nodes<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNode: traits::LeafNode<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<LeafNode>, Self::Error> {
        self.read_list(OWN_LEAF_NODES_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn append_own_leaf_node<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNode: traits::LeafNode<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        leaf_node: &LeafNode,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(group_id)?;
        let value = serde_json::to_vec(leaf_node)?;
        self.append::<CURRENT_VERSION>(OWN_LEAF_NODES_LABEL, &key, value)
    }

    fn delete_own_leaf_nodes<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(OWN_LEAF_NODES_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_group_config<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(JOIN_CONFIG_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_tree<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(TREE_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_confirmation_tag<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            CONFIRMATION_TAG_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    fn delete_context<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(GROUP_CONTEXT_LABEL, &serde_json::to_vec(group_id).unwrap())
    }

    fn delete_interim_transcript_hash<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            INTERIM_TRANSCRIPT_HASH_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    fn remove_proposal<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
    ) -> Result<(), Self::Error> {
        let key = serde_json::to_vec(group_id).unwrap();
        let value = serde_json::to_vec(proposal_ref).unwrap();

        self.remove_item::<CURRENT_VERSION>(PROPOSAL_QUEUE_REFS_LABEL, &key, value)?;

        let key = serde_json::to_vec(&(group_id, proposal_ref)).unwrap();
        self.delete::<CURRENT_VERSION>(QUEUED_PROPOSAL_LABEL, &key)
    }

    #[cfg(feature = "extensions-draft")]
    fn write_application_export_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ApplicationExportTree: traits::ApplicationExportTree<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        application_export_tree: &ApplicationExportTree,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            APPLICATION_EXPORT_TREE_LABEL,
            &serde_json::to_vec(&group_id).unwrap(),
            serde_json::to_vec(&application_export_tree).unwrap(),
        )
    }

    #[cfg(feature = "extensions-draft")]
    fn application_export_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ApplicationExportTree: traits::ApplicationExportTree<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ApplicationExportTree>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(APPLICATION_EXPORT_TREE_LABEL, group_id);

        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        let value = serde_json::from_slice(value).unwrap();

        Ok(value)
    }

    #[cfg(feature = "extensions-draft")]
    fn delete_application_export_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ApplicationExportTree: traits::ApplicationExportTree<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            APPLICATION_EXPORT_TREE_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_vc_emulation_epoch_state<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcEmulationEpochState: traits::VcEmulationEpochState<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
        vc_emulation_epoch_state: &VcEmulationEpochState,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            VC_EMULATION_EPOCH_STATE_LABEL,
            &serde_json::to_vec(epoch_id).unwrap(),
            serde_json::to_vec(vc_emulation_epoch_state).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn vc_emulation_epoch_state<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcEmulationEpochState: traits::VcEmulationEpochState<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
    ) -> Result<Option<VcEmulationEpochState>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &EpochId>(VC_EMULATION_EPOCH_STATE_LABEL, epoch_id);
        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_vc_emulation_state_if_unreferenced<EpochId: traits::VcEpochId<CURRENT_VERSION>>(
        &self,
        epoch_id: &EpochId,
    ) -> Result<bool, Self::Error> {
        let serialized_epoch_id = serde_json::to_vec(epoch_id)?;
        // Hold the write lock across the liveness check and the deletion so a
        // material stored concurrently cannot be orphaned.
        let mut values = self.values.write().unwrap();
        let referenced = values
            .iter()
            .any(|(key, value)| is_epoch_tag(key) && value == &serialized_epoch_id);
        if referenced {
            return Ok(false);
        }
        let state_key = build_key_from_vec::<CURRENT_VERSION>(
            VC_EMULATION_EPOCH_STATE_LABEL,
            serialized_epoch_id.clone(),
        );
        let tree_key =
            build_key_from_vec::<CURRENT_VERSION>(VC_OPERATION_TREE_LABEL, serialized_epoch_id);
        values.remove(&state_key);
        values.remove(&tree_key);
        Ok(true)
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_vc_emulation_bindings<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        VcEmulationBindings: traits::VcEmulationBindings<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        bindings: &VcEmulationBindings,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            VC_EMULATION_BINDING_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
            serde_json::to_vec(bindings).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn vc_emulation_bindings<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        VcEmulationBindings: traits::VcEmulationBindings<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<VcEmulationBindings>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &GroupId>(VC_EMULATION_BINDING_LABEL, group_id);
        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_vc_emulation_bindings<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            VC_EMULATION_BINDING_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_registered_vc_emulation_epoch<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        RegisteredVcEmulationEpoch: traits::RegisteredVcEmulationEpoch<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        registered: &RegisteredVcEmulationEpoch,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            REGISTERED_VC_EMULATION_EPOCH_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
            serde_json::to_vec(registered).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn registered_vc_emulation_epoch<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        RegisteredVcEmulationEpoch: traits::RegisteredVcEmulationEpoch<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<RegisteredVcEmulationEpoch>, Self::Error> {
        let values = self.values.read().unwrap();
        let key =
            build_key::<CURRENT_VERSION, &GroupId>(REGISTERED_VC_EMULATION_EPOCH_LABEL, group_id);
        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_registered_vc_emulation_epoch<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.delete::<CURRENT_VERSION>(
            REGISTERED_VC_EMULATION_EPOCH_LABEL,
            &serde_json::to_vec(group_id).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_vc_operation_tree<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcOperationTree: traits::VcOperationTree<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
        vc_operation_tree: &VcOperationTree,
    ) -> Result<(), Self::Error> {
        self.write::<CURRENT_VERSION>(
            VC_OPERATION_TREE_LABEL,
            &serde_json::to_vec(epoch_id).unwrap(),
            serde_json::to_vec(vc_operation_tree).unwrap(),
        )
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn vc_operation_tree<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcOperationTree: traits::VcOperationTree<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
    ) -> Result<Option<VcOperationTree>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &EpochId>(VC_OPERATION_TREE_LABEL, epoch_id);
        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn write_retained_key_package_material_batch<
        EpochId: traits::VcEpochId<CURRENT_VERSION>,
        VcOperationTree: traits::VcOperationTree<CURRENT_VERSION>,
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        RetainedKeyPackageMaterial: traits::RetainedKeyPackageMaterial<CURRENT_VERSION>,
    >(
        &self,
        epoch_id: &EpochId,
        operation_tree: &VcOperationTree,
        materials: &[(KeyPackageRef, RetainedKeyPackageMaterial)],
    ) -> Result<(), Self::Error> {
        let serialized_epoch_id = serde_json::to_vec(epoch_id)?;
        // Take the write lock once so the advanced tree and all materials are
        // written together. A reader cannot observe an advanced tree without
        // the materials it produced.
        let mut values = self.values.write().unwrap();
        let tree_key = build_key_from_vec::<CURRENT_VERSION>(
            VC_OPERATION_TREE_LABEL,
            serialized_epoch_id.clone(),
        );
        values.insert(tree_key, serde_json::to_vec(operation_tree)?);
        for (hash_ref, record) in materials {
            let serialized_ref = serde_json::to_vec(hash_ref)?;
            let material_key = build_key_from_vec::<CURRENT_VERSION>(
                RETAINED_KEY_PACKAGE_MATERIAL_LABEL,
                serialized_ref.clone(),
            );
            values.insert(material_key, serde_json::to_vec(record)?);
            let epoch_tag_key = build_key_from_vec::<CURRENT_VERSION>(
                RETAINED_KEY_PACKAGE_EPOCH_LABEL,
                serialized_ref,
            );
            values.insert(epoch_tag_key, serialized_epoch_id.clone());
        }
        Ok(())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn retained_key_package_material<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        RetainedKeyPackageMaterial: traits::RetainedKeyPackageMaterial<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<Option<RetainedKeyPackageMaterial>, Self::Error> {
        let values = self.values.read().unwrap();
        let key = build_key::<CURRENT_VERSION, &KeyPackageRef>(
            RETAINED_KEY_PACKAGE_MATERIAL_LABEL,
            hash_ref,
        );
        let Some(value) = values.get(&key) else {
            return Ok(None);
        };
        Ok(serde_json::from_slice(value).unwrap())
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn has_retained_key_package_material_for_epoch<EpochId: traits::VcEpochId<CURRENT_VERSION>>(
        &self,
        epoch_id: &EpochId,
    ) -> Result<bool, Self::Error> {
        let serialized_epoch_id = serde_json::to_vec(epoch_id)?;
        let values = self.values.read().unwrap();
        let referenced = values
            .iter()
            .any(|(key, value)| is_epoch_tag(key) && value == &serialized_epoch_id);
        Ok(referenced)
    }

    #[cfg(feature = "virtual-clients-draft")]
    fn delete_retained_key_package_material<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        let serialized_ref = serde_json::to_vec(hash_ref)?;
        self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_MATERIAL_LABEL, &serialized_ref)?;
        self.delete::<CURRENT_VERSION>(RETAINED_KEY_PACKAGE_EPOCH_LABEL, &serialized_ref)
    }
}

/// Build a key with version and label.
fn build_key_from_vec<const V: u16>(label: &[u8], key: Vec<u8>) -> Vec<u8> {
    let mut key_out = label.to_vec();
    key_out.extend_from_slice(&key);
    key_out.extend_from_slice(&u16::to_be_bytes(V));
    key_out
}

/// Whether a storage key belongs to a retained-KeyPackage epoch tag entry.
#[cfg(feature = "virtual-clients-draft")]
fn is_epoch_tag(storage_key: &[u8]) -> bool {
    storage_key.starts_with(RETAINED_KEY_PACKAGE_EPOCH_LABEL)
}

/// Build a key with version and label.
fn build_key<const V: u16, K: Serialize>(label: &[u8], key: K) -> Vec<u8> {
    build_key_from_vec::<V>(label, serde_json::to_vec(&key).unwrap())
}

fn epoch_key_pairs_id(
    group_id: &impl traits::GroupId<CURRENT_VERSION>,
    epoch: &impl traits::EpochKey<CURRENT_VERSION>,
    leaf_index: u32,
) -> Result<Vec<u8>, <Store as StorageProvider<CURRENT_VERSION>>::Error> {
    let mut key = serde_json::to_vec(group_id)?;
    key.extend_from_slice(&serde_json::to_vec(epoch)?);
    key.extend_from_slice(&serde_json::to_vec(&leaf_index)?);
    Ok(key)
}

impl From<serde_json::Error> for MemoryStorageError {
    fn from(_: serde_json::Error) -> Self {
        Self::SerializationError
    }
}
