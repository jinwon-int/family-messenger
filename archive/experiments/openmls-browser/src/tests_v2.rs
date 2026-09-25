//! Storage v2 (#177 M2) measurements: dirty-set completeness, rollback of rejected
//! and aborted operations, growth over 1,000 messages, and the format-1 migration.
use super::*;
use session::{unframe, Session};
use std::collections::BTreeMap;

type Mirror = BTreeMap<Vec<u8>, Vec<u8>>;

/// What the JS worker does with `changes`: upsert or delete each entry.
fn persist(mirror: &mut Mirror, changes: &[u8]) -> usize {
    let changes = unframe(changes, true).expect("well-formed changes");
    let count = changes.len();
    for (key, value) in changes {
        match value {
            Some(value) => { mirror.insert(key, value); }
            None => { mirror.remove(&key); }
        }
    }
    count
}

fn framed(mirror: &Mirror) -> Vec<u8> {
    let entries: Vec<_> = mirror.iter().map(|(k, v)| (k.clone(), Some(v.clone()))).collect();
    session::frame(&entries)
}

struct Peer { session: Session, mirror: Mirror }

impl Peer {
    fn new(identity: &str) -> Peer {
        let mut session = Session::create(identity).expect("create");
        let mut mirror = Mirror::new();
        persist(&mut mirror, &session.pending_changes());
        session.commit().expect("commit");
        Peer { session, mirror }
    }

    /// apply → persist changes → commit, and check the mirror equals the store.
    fn step(&mut self, method: &str, input: &[u8]) -> Vec<u8> {
        let step = self.session.apply(method, input).unwrap_or_else(|_| panic!("{method} rejected"));
        persist(&mut self.mirror, &step.changes());
        self.session.commit().expect("commit");
        self.assert_durable();
        step.output()
    }

    fn assert_durable(&self) {
        let live: Mirror = self.session_store_entries().into_iter().collect();
        assert_eq!(live, self.mirror, "dirty set must reproduce the store exactly");
    }

    fn session_store_entries(&self) -> Vec<(Vec<u8>, Vec<u8>)> { session_entries(&self.session) }

    fn reopen(&self, identity: &str) -> Session {
        Session::open(identity, &self.session.public_key(), &self.session.group_id(),
            Session::format_version(), &framed(&self.mirror)).expect("reopen from persisted entries")
    }
}

fn session_entries(session: &Session) -> Vec<(Vec<u8>, Vec<u8>)> { session.store_entries_for_test() }

/// alice creates, invites bob through the v2 relay flow (pending commit → merge).
fn pair() -> (Peer, Peer) {
    let mut alice = Peer::new("alice");
    let mut bob = Peer::new("bob");
    alice.step("create", &[]);
    let package = bob.step("key_package", &[]);
    let framed = alice.step("invite_with_commit", &package);
    assert!(alice.session.has_pending_commit());
    alice.step("merge_pending", &[]);
    let commit_len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    bob.step("join", &framed[4 + commit_len..]);
    (alice, bob)
}

#[test]
fn dirty_set_reproduces_store_and_reopens() {
    let (mut alice, mut bob) = pair();
    for i in 0..20u8 {
        let ciphertext = alice.step("encrypt", &[i; 10]);
        assert_eq!(bob.step("decrypt", &ciphertext), vec![i; 10]);
        let reply = bob.step("encrypt", &[i, i]);
        assert_eq!(alice.step("decrypt", &reply), vec![i, i]);
    }
    assert_eq!(alice.session.full_serializations(), 0, "no full serialization per operation");
    assert_eq!(bob.session.full_serializations(), 0);

    // A fresh session opened from nothing but the persisted changes keeps talking.
    let mut reopened = bob.reopen("bob");
    assert_eq!(reopened.full_serializations(), 1, "open is the one full (de)serialization");
    let ciphertext = alice.step("encrypt", b"after reopen");
    let step = reopened.apply("decrypt", &ciphertext).expect("reopened decrypts");
    assert_eq!(step.output(), b"after reopen");
    reopened.commit().unwrap();
    let back = reopened.apply("encrypt", b"reply").expect("reopened encrypts");
    assert_eq!(alice.step("decrypt", &back.output()), b"reply");
}

#[test]
fn rejected_and_aborted_operations_roll_back() {
    let (mut alice, mut bob) = pair();
    let ciphertext = alice.step("encrypt", b"one");

    // Tampered ciphertext: rejected, nothing in flight, store unchanged, still usable.
    let mut forged = ciphertext.clone();
    let last = forged.len() - 1;
    forged[last] ^= 1;
    let before = session_entries(&bob.session);
    assert!(bob.session.apply("decrypt", &forged).is_err());
    assert!(bob.session.pending_changes() == session::frame(&[]), "rejection leaves nothing in flight");
    assert_eq!(session_entries(&bob.session), before, "rejection restores the store");
    assert_eq!(bob.step("decrypt", &ciphertext), b"one", "session survives a rejection");

    // Replay: the ratchet key was consumed and committed; the replay is rejected.
    let before = session_entries(&bob.session);
    assert!(bob.session.apply("decrypt", &ciphertext).is_err());
    assert_eq!(session_entries(&bob.session), before);

    // Abort (IDB transaction failed): the decrypt is undone, so the same
    // ciphertext decrypts again — the consumed key was restored.
    let second = alice.step("encrypt", b"two");
    bob.session.apply("decrypt", &second).expect("decrypt");
    assert!(bob.session.apply("decrypt", &second).is_err(), "no apply while changes are in flight");
    bob.session.abort().expect("abort");
    bob.assert_durable();
    assert_eq!(bob.step("decrypt", &second), b"two");

    // Unknown methods and malformed input are rejected without state change.
    let before = session_entries(&bob.session);
    assert!(bob.session.apply("export_secrets", &[]).is_err());
    assert!(bob.session.apply("commit", &[1, 2, 3]).is_err());
    assert_eq!(session_entries(&bob.session), before);
}

#[test]
fn thousand_messages_do_not_grow_the_store_linearly() {
    let (mut alice, mut bob) = pair();
    let mut sizes = Vec::new();
    let mut max_change = 0usize;
    for i in 0..1000u32 {
        let ciphertext = alice.step("encrypt", &i.to_le_bytes());
        let step = bob.session.apply("decrypt", &ciphertext).expect("decrypt");
        max_change = max_change.max(step.changes().len());
        persist(&mut bob.mirror, &step.changes());
        bob.session.commit().unwrap();
        if i == 9 || i == 99 || i == 999 {
            sizes.push((i + 1, bob.session.store_bytes(), bob.session.entry_count()));
        }
    }
    bob.assert_durable();
    eprintln!("M2 growth (messages, store bytes, entries): {sizes:?}; largest per-message change {max_change} B");
    let (_, at10, _) = sizes[0];
    let (_, at1000, _) = sizes[2];
    assert!(at1000 <= at10 + at10 / 10, "store must not grow with message count: {at10} -> {at1000}");
    assert!(max_change < at10 as usize / 2, "a message persists a small delta, not the store: {max_change} vs {at10}");
    assert_eq!(bob.session.full_serializations(), 0);
    assert_eq!(alice.session.full_serializations(), 0);
}

#[test]
fn format1_snapshot_migrates_and_keeps_talking() {
    use openmls_rust_crypto::OpenMlsRustCrypto;
    // alice on the pre-M2 provider (openmls_memory_storage, JSON), bob on v2.
    let provider = OpenMlsRustCrypto::default();
    let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    signer.store(provider.storage()).unwrap();
    let credential = CredentialWithKey {
        credential: BasicCredential::new(b"alice".to_vec()).into(),
        signature_key: signer.public().into(),
    };
    let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE).use_ratchet_tree_extension(true).build();
    let mut group = MlsGroup::new(&provider, &signer, &config, credential).unwrap();
    let mut bob = Device::new("bob").unwrap();
    let package = KeyPackageIn::tls_deserialize_exact_bytes(&bob.key_package_inner().unwrap()).unwrap()
        .validate(provider.crypto(), ProtocolVersion::Mls10).unwrap();
    let (_, welcome, _) = group.add_members(&provider, &signer, &[package]).unwrap();
    group.merge_pending_commit(&provider).unwrap();
    bob.join_inner(&welcome.tls_serialize_detached().unwrap()).unwrap();
    // Reach epoch 12 with own leaf 0: the v1 EpochKeyPairs key ends in "…120",
    // the ambiguous concatenation the migration must split correctly.
    for _ in 0..11 {
        let bundle = group.self_update(&provider, &signer, LeafNodeParameters::default()).unwrap();
        group.merge_pending_commit(&provider).unwrap();
        bob.apply_commit_inner(&bundle.commit().tls_serialize_detached().unwrap()).unwrap();
    }
    assert_eq!(group.epoch().as_u64(), 12);

    let mut entries: Vec<(Vec<u8>, Vec<u8>)> = provider.storage().values.read().unwrap()
        .iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    entries.sort();
    assert!(entries.iter().any(|(k, _)| k.starts_with(b"EpochKeyPairs") && k.ends_with(b"120\x00\x01")),
        "fixture must contain the ambiguous epoch/leaf key");
    let v1 = serde_json::json!({
        "version": 1, "identity": "alice", "public_key": signer.public(),
        "group_id": group.group_id().as_slice(), "entries": entries,
    });
    let v1 = serde_json::to_vec(&v1).unwrap();

    // Snapshot API path (format 1 → 2 at load).
    let mut alice = staging::load_for_test(&v1, "alice").expect("format-1 snapshot migrates");
    assert_eq!(alice.group.as_ref().unwrap().epoch().as_u64(), 12);
    let ciphertext = bob.encrypt_inner(b"to migrated alice").unwrap();
    assert_eq!(alice.decrypt_inner(&ciphertext).unwrap(), b"to migrated alice");
    // bob commits: alice needs her epoch-12 encryption key pair (the migrated key).
    let bundle = bob.group.as_mut().unwrap()
        .self_update(&bob.provider, &bob.signer, LeafNodeParameters::default()).unwrap();
    bob.group.as_mut().unwrap().merge_pending_commit(&bob.provider).unwrap();
    alice.apply_commit_inner(&bundle.commit().tls_serialize_detached().unwrap()).expect("migrated alice applies commit");
    let reply = alice.encrypt_inner(b"from migrated alice").unwrap();
    assert_eq!(bob.decrypt_inner(&reply).unwrap(), b"from migrated alice");

    // Session path: a migrated open must be rewritten (export) before use.
    let framed_v1: Vec<_> = entries.iter().map(|(k, v)| (k.clone(), Some(v.clone()))).collect();
    let mut session = Session::open("alice", signer.public(), group.group_id().as_slice(), 1,
        &session::frame(&framed_v1)).expect("format-1 entries open");
    assert!(session.migrated());
    assert!(session.apply("encrypt", b"x").is_err(), "no operation before the rewrite");
    let rewritten = session.export().expect("export");
    eprintln!("M2 same state (epoch 12, 2 members): format-1 JSON snapshot {} B -> format-2 entries {} B",
        v1.len(), rewritten.len());
    assert!(rewritten.len() * 2 < v1.len(), "binary codec must at least halve the snapshot");
    assert!(session.migrated(), "still migrated until the rewrite is durable");
    session.commit().unwrap();
    assert!(!session.migrated());
    let reopened = Session::open("alice", signer.public(), group.group_id().as_slice(),
        Session::format_version(), &rewritten).expect("rewritten entries open as format 2");
    assert_eq!(reopened.current_epoch(), "12");

    // Unknown formats and an ambiguous key without its OwnLeafNodeIndex are rejected.
    assert!(migrate::upgrade(3, entries.clone()).is_none());
    let without_leaf: Vec<_> = entries.iter().filter(|(k, _)| !k.starts_with(b"OwnLeafNodeIndex")).cloned().collect();
    assert!(migrate::upgrade(1, without_leaf).is_none(), "no guessing the epoch/leaf split");
}

#[test]
fn stores_nobody_commits_do_not_journal() {
    // The memory-only `Device` (and the per-call snapshot API) never commit; a
    // journal there would keep a pre-image of every key ever touched.
    let mut alice = Device::new("alice").unwrap();
    let mut bob = Device::new("bob").unwrap();
    alice.create_inner().unwrap();
    let welcome = alice.invite_inner(&bob.key_package_inner().unwrap()).unwrap();
    bob.join_inner(&welcome).unwrap();
    for i in 0..50u8 {
        let ciphertext = alice.encrypt_inner(&[i]).unwrap();
        bob.decrypt_inner(&ciphertext).unwrap();
    }
    assert!(alice.provider.storage().changes().is_empty());
    assert!(bob.provider.storage().changes().is_empty());
}

/// A pre-M2 (format-1) alice on the real `openmls_memory_storage` provider, in a
/// group with bob. Returns (provider, signer, group, bob).
fn v1_alice_with_bob() -> (openmls_rust_crypto::OpenMlsRustCrypto, SignatureKeyPair, MlsGroup, Device) {
    let provider = openmls_rust_crypto::OpenMlsRustCrypto::default();
    let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    signer.store(provider.storage()).unwrap();
    let credential = CredentialWithKey {
        credential: BasicCredential::new(b"alice".to_vec()).into(),
        signature_key: signer.public().into(),
    };
    let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE).use_ratchet_tree_extension(true).build();
    let mut group = MlsGroup::new(&provider, &signer, &config, credential).unwrap();
    let mut bob = Device::new("bob").unwrap();
    let package = KeyPackageIn::tls_deserialize_exact_bytes(&bob.key_package_inner().unwrap()).unwrap()
        .validate(provider.crypto(), ProtocolVersion::Mls10).unwrap();
    let (_, welcome, _) = group.add_members(&provider, &signer, &[package]).unwrap();
    group.merge_pending_commit(&provider).unwrap();
    bob.join_inner(&welcome.tls_serialize_detached().unwrap()).unwrap();
    (provider, signer, group, bob)
}

fn v1_entries(provider: &openmls_rust_crypto::OpenMlsRustCrypto) -> Vec<(Vec<u8>, Vec<u8>)> {
    let mut entries: Vec<_> = provider.storage().values.read().unwrap()
        .iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    entries.sort();
    entries
}

fn framed_entries(entries: &[(Vec<u8>, Vec<u8>)]) -> Vec<u8> {
    let framed: Vec<_> = entries.iter().map(|(k, v)| (k.clone(), Some(v.clone()))).collect();
    session::frame(&framed)
}

/// Review F1: JSON turns the integer map keys of a pending commit's staged diff
/// (`leaf_diff: BTreeMap<LeafNodeIndex, _>`) into strings; a format-1 state saved
/// between "update" and "merge_update" must still migrate, and the migrated
/// pending commit must still merge and interoperate.
#[test]
fn format1_with_pending_commit_migrates() {
    let (provider, signer, mut group, mut bob) = v1_alice_with_bob();
    let bundle = group.self_update(&provider, &signer, LeafNodeParameters::default()).unwrap();
    assert!(group.pending_commit().is_some());
    let entries = v1_entries(&provider);
    let state = &entries.iter().find(|(k, _)| k.starts_with(b"GroupState")).unwrap().1;
    assert!(String::from_utf8_lossy(state).contains("\"0\":"), "fixture must hold a string-keyed map");

    let mut session = Session::open("alice", signer.public(), group.group_id().as_slice(), 1,
        &framed_entries(&entries)).expect("format-1 state with a pending commit migrates");
    assert!(session.has_pending_commit());
    let rewritten = session.export().unwrap();
    session.commit().unwrap();
    let mut alice = Session::open("alice", signer.public(), group.group_id().as_slice(),
        Session::format_version(), &rewritten).unwrap();
    alice.apply("merge_pending", &[]).expect("migrated pending commit merges");
    alice.commit().unwrap();
    bob.apply_commit_inner(&bundle.commit().tls_serialize_detached().unwrap()).unwrap();
    let step = alice.apply("encrypt", b"after migrated merge").unwrap();
    assert_eq!(bob.decrypt_inner(&step.output()).unwrap(), b"after migrated merge");
}

/// Review F2: a session must never make durable a state `open` would refuse.
#[test]
fn session_refuses_states_open_could_not_load() {
    let mut session = Session::create("alice").unwrap();
    session.commit().unwrap();
    let mut rejected_at = None;
    for i in 0..=staging::MAX_ENTRIES {
        match session.apply("key_package", &[]) {
            Ok(_) => session.commit().unwrap(),
            Err(error) => { rejected_at = Some((i, error)); break; }
        }
    }
    let (_, error) = rejected_at.expect("unused key packages must hit the entry bound");
    assert_eq!(error, Rejected("state limit"));
    assert!(session.entry_count() as usize <= staging::MAX_ENTRIES);
    let public_key = session.public_key();
    let exported = session.export().unwrap();
    Session::open("alice", &public_key, &[], Session::format_version(), &exported)
        .expect("the last durable state reopens");
}

/// Review F3: the format rewrite is two-phase; an export that was never made
/// durable must not unlock `apply` (deltas would mix v2 keys into a v1 store).
#[test]
fn migration_rewrite_is_two_phase() {
    let (provider, signer, group, _bob) = v1_alice_with_bob();
    let entries = framed_entries(&v1_entries(&provider));
    let open = || Session::open("alice", signer.public(), group.group_id().as_slice(), 1, &entries).unwrap();

    let mut session = open();
    let _lost = session.export().unwrap();
    assert!(session.apply("key_package", &[]).is_err(), "rewrite in flight");
    session.abort().unwrap();
    assert!(session.migrated(), "failed rewrite leaves the session migrated");
    assert!(session.apply("key_package", &[]).is_err());

    let mut session = open();
    let _rewritten = session.export().unwrap();
    session.commit().unwrap();
    assert!(!session.migrated());
    session.apply("key_package", &[]).expect("usable once the rewrite is durable");
}

/// M2b-2: the trusted Session path enforces the pins before and after each
/// operation and rolls a rejection back instead of retiring the device.
#[test]
fn trusted_session_enforces_pins_and_rolls_back() {
    let mut alice = Peer::new("alice");
    let mut bob = Peer::new("bob");
    let (alice_key, bob_key) = (alice.session.public_key(), bob.session.public_key());
    let trusted = |peer: &mut Peer, method: &str, input: &[u8], actor: &str, key: &[u8]| {
        let step = peer.session.apply_trusted(method, input, actor, key)?;
        persist(&mut peer.mirror, &step.changes());
        peer.session.commit().unwrap();
        peer.assert_durable();
        Ok::<_, Rejected>(step.output())
    };
    trusted(&mut alice, "create", &[], "bob", &bob_key).unwrap();
    let package = trusted(&mut bob, "key_package", &[], "alice", &alice_key).unwrap();
    // A KeyPackage that is not the pinned peer's is refused and rolled back.
    let mallory = Peer::new("mallory").session.apply("key_package", &[]).unwrap().output();
    let before = session_entries(&alice.session);
    assert!(alice.session.apply_trusted("invite", &mallory, "bob", &bob_key).is_err());
    assert_eq!(session_entries(&alice.session), before, "rejected invite leaves the store unchanged");
    // Wrong pinned key for the right actor is refused too.
    assert!(alice.session.apply_trusted("invite", &package, "bob", &alice_key).is_err());
    let welcome = trusted(&mut alice, "invite", &package, "bob", &bob_key).unwrap();
    trusted(&mut bob, "join", &welcome, "alice", &alice_key).unwrap();
    alice.session.check_trust("bob", &bob_key).unwrap();
    assert!(alice.session.check_trust("bob", &alice_key).is_err());
    // Pair-only operations need the exact pinned pair.
    assert!(alice.session.apply_trusted("encrypt", b"x", "carol", &bob_key).is_err());
    let ciphertext = trusted(&mut alice, "encrypt", b"pinned hello", "bob", &bob_key).unwrap();
    // decrypt_peer checks the MLS-authenticated sender against the pin.
    let before = session_entries(&bob.session);
    assert!(bob.session.apply_trusted("decrypt_peer", &ciphertext, "alice", &bob_key).is_err());
    assert_eq!(session_entries(&bob.session), before, "sender-key mismatch rolls back (ratchet not consumed)");
    assert_eq!(trusted(&mut bob, "decrypt_peer", &ciphertext, "alice", &alice_key).unwrap(), b"pinned hello");
}
