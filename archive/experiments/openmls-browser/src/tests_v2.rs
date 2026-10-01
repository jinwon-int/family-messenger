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

/// Room used by every §3.6-bound encrypt/decrypt below.
const ROOM: &str = "family";

/// §3.6 binding frames: the encrypt input is `u32 LE len ‖ room ‖ u32 LE len ‖
/// client_id ‖ plaintext`, the decrypt input is `u32 LE len ‖ room ‖
/// ciphertext` — exactly what the facade parses before the MLS operation.
fn enc(room: &str, client: &str, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    for part in [room.as_bytes(), client.as_bytes()] {
        out.extend_from_slice(&(part.len() as u32).to_le_bytes());
        out.extend_from_slice(part);
    }
    out.extend_from_slice(payload);
    out
}
fn dec(room: &str, wire: &[u8]) -> Vec<u8> {
    let mut out = (room.len() as u32).to_le_bytes().to_vec();
    out.extend_from_slice(room.as_bytes());
    out.extend_from_slice(wire);
    out
}

/// Inverse of `frame_decrypt` (DECRYPT_FORMAT 2): (sender_device, client_id, plaintext).
fn attributed(out: &[u8]) -> (String, String, Vec<u8>) {
    let mut rest = out;
    let mut field = || {
        let len = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
        let value = String::from_utf8(rest[4..4 + len].to_vec()).unwrap();
        rest = &rest[4 + len..];
        value
    };
    let (sender, client) = (field(), field());
    (sender, client, rest.to_vec())
}
fn plain(out: &[u8]) -> Vec<u8> { attributed(out).2 }

/// A pre-M4 caller (no binding header) or any tampered header must be refused
/// before MLS state is touched.
#[test]
fn aad_frame_rejects_malformed_caller_input() {
    let mut alice = Device::new("alice").unwrap();
    alice.create_inner().unwrap();
    for input in [&b""[..], &[1u8, 0, 0, 0], &[u8::MAX, 0, 0, 0], b"\x06\x00\x00\x00famil\x00"] {
        assert!(alice.encrypt_inner(input).is_err(), "{input:?}");
        assert!(alice.decrypt_inner(input).is_err(), "{input:?}");
    }
    // Bad identity charset ('?'), oversized identity (65 > 64), non-UTF-8 room.
    for room in ["bad room", &"a".repeat(65)[..], "\u{ff}"] {
        assert!(alice.decrypt_inner(&dec(room, &[1, 2, 3])).is_err(), "{room:?}");
    }
    // Raw non-UTF-8 bytes fail before the identity check (dec() is always UTF-8).
    let mut raw = vec![2u8, 0, 0, 0];
    raw.extend_from_slice(&[0xC3, 0xBF]);
    raw.extend_from_slice(&[1, 2, 3]);
    assert!(alice.decrypt_inner(&raw).is_err());
    // Encrypt also parses the client id.
    assert!(alice.encrypt_inner(&enc(ROOM, "", b"x")).is_err());
    assert!(alice.encrypt_inner(&enc(ROOM, "bad client", b"x")).is_err());
    assert!(alice.encrypt_inner(&enc(ROOM, "person-a", &[])).is_err(), "empty plaintext");
}

/// The canonical AAD wire form parses strictly; nothing loose is accepted.
#[test]
fn aad_parse_rejects_malformed_frames() {
    fn len(part: &[u8]) -> Vec<u8> { let mut o = (part.len() as u32).to_le_bytes().to_vec(); o.extend_from_slice(part); o }
    let good = aad_bytes(b"family", &[9; 16], b"a-1", b"person-a", 7);
    let parsed = parse_aad(&good).unwrap();
    assert_eq!((parsed.room.as_slice(), parsed.group_id.as_slice(),
        parsed.sender_device.as_slice(), parsed.epoch),
        (b"family".as_slice(), &[9; 16][..], b"a-1".as_slice(), 7));
    // Every truncation and any trailing byte is refused.
    for n in 0..good.len() { assert!(parse_aad(&good[..n]).is_none(), "truncated at {n}"); }
    let mut trailing = good.clone();
    trailing.push(0);
    assert!(parse_aad(&trailing).is_none());
    // Length fields that lie, invalid identity charset, oversized identity,
    // empty group id, empty client id, missing epoch.
    let bad = |room: &[u8], group: &[u8], sender: &[u8], client: &[u8], epoch: &[u8]|
        parse_aad(&[len(room), len(group), len(sender), len(client), epoch.to_vec()].concat()).is_none();
    assert!(bad(b"family", &[9; 16], b"a-1", b"person-a", &[]), "epoch truncated");
    assert!(bad(b"bad room", &[9; 16], b"a-1", b"person-a", &7u64.to_le_bytes()), "room charset");
    assert!(bad(b"family", &[], b"a-1", b"person-a", &7u64.to_le_bytes()), "empty group");
    assert!(bad(b"family", &[9; 16], b"", b"person-a", &7u64.to_le_bytes()), "empty sender");
    assert!(bad(b"family", &[9; 16], b"a-1", b"", &7u64.to_le_bytes()), "empty client");
    assert!(bad(&[b'a'; 65], &[9; 16], b"a-1", b"person-a", &7u64.to_le_bytes()), "oversized room");
    assert!(bad(b"family", &[9; 16], &[b'x'; 65], b"person-a", &7u64.to_le_bytes()), "oversized sender");
    // A lying length field consumes past the end (no panic, just rejection).
    assert!(parse_aad(&[(&65u32).to_le_bytes().as_slice(), b"fam".as_slice()].concat()).is_none());
}

/// §3.6: a message encrypted for one room must not open under another, and a
/// rejection after MLS authentication must not consume ratchet state.
#[test]
fn aad_binding_rejects_wrong_room_and_rolls_back() {
    let (mut alice, mut bob) = pair();
    // The client id a sender declares must be its own roster identity (H1).
    let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", b"hello"));
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &ciphertext))), b"hello");
    // A second message, declared in the wrong room context: the AAD gate fires
    // only after MLS authentication has consumed the ratchet secret.
    let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", b"secret"));
    let before = session_entries(&bob.session);
    assert!(bob.session.apply("decrypt", &dec("elsewhere", &ciphertext)).is_err());
    assert_eq!(session_entries(&bob.session), before, "AAD rejection restores the store");
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &ciphertext))), b"secret", "session survives an AAD rejection");
    // The plaintext bound applies to the framed payload, not the whole input.
    assert!(alice.session.apply("encrypt", &enc(ROOM, "alice", &[0; 16385])).is_err());
    let step = alice.session.apply("encrypt", &enc(ROOM, "alice", &[0; 16384])).unwrap();
    persist(&mut alice.mirror, &step.changes());
    alice.session.commit().unwrap();
}

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
        let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", &[i; 10]));
        assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &ciphertext))), vec![i; 10]);
        let reply = bob.step("encrypt", &enc(ROOM, "bob", &[i, i]));
        assert_eq!(plain(&alice.step("decrypt", &dec(ROOM, &reply))), vec![i, i]);
    }
    assert_eq!(alice.session.full_serializations(), 0, "no full serialization per operation");
    assert_eq!(bob.session.full_serializations(), 0);

    // A fresh session opened from nothing but the persisted changes keeps talking.
    let mut reopened = bob.reopen("bob");
    assert_eq!(reopened.full_serializations(), 1, "open is the one full (de)serialization");
    let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", b"after reopen"));
    let step = reopened.apply("decrypt", &dec(ROOM, &ciphertext)).expect("reopened decrypts");
    assert_eq!(attributed(&step.output()), ("alice".into(), "alice".into(), b"after reopen".to_vec()));
    reopened.commit().unwrap();
    let back = reopened.apply("encrypt", &enc(ROOM, "bob", b"reply")).expect("reopened encrypts");
    assert_eq!(plain(&alice.step("decrypt", &dec(ROOM, &back.output()))), b"reply");
}

#[test]
fn rejected_and_aborted_operations_roll_back() {
    let (mut alice, mut bob) = pair();
    let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", b"one"));

    // Tampered ciphertext: rejected, nothing in flight, store unchanged, still usable.
    let mut forged = ciphertext.clone();
    let last = forged.len() - 1;
    forged[last] ^= 1;
    let before = session_entries(&bob.session);
    assert!(bob.session.apply("decrypt", &dec(ROOM, &forged)).is_err());
    assert!(bob.session.pending_changes() == session::frame(&[]), "rejection leaves nothing in flight");
    assert_eq!(session_entries(&bob.session), before, "rejection restores the store");
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &ciphertext))), b"one", "session survives a rejection");

    // Replay: the ratchet key was consumed and committed; the replay is rejected.
    let before = session_entries(&bob.session);
    assert!(bob.session.apply("decrypt", &dec(ROOM, &ciphertext)).is_err());
    assert_eq!(session_entries(&bob.session), before);

    // Abort (IDB transaction failed): the decrypt is undone, so the same
    // ciphertext decrypts again — the consumed key was restored.
    let second = alice.step("encrypt", &enc(ROOM, "alice", b"two"));
    bob.session.apply("decrypt", &dec(ROOM, &second)).expect("decrypt");
    assert!(bob.session.apply("decrypt", &dec(ROOM, &second)).is_err(), "no apply while changes are in flight");
    bob.session.abort().expect("abort");
    bob.assert_durable();
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &second))), b"two");

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
        let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", &i.to_le_bytes()));
        let step = bob.session.apply("decrypt", &dec(ROOM, &ciphertext)).expect("decrypt");
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
    let ciphertext = bob.encrypt_inner(&enc(ROOM, "bob", b"to migrated alice")).unwrap();
    assert_eq!(plain(&alice.decrypt_inner(&dec(ROOM, &ciphertext)).unwrap()), b"to migrated alice");
    // bob commits: alice needs her epoch-12 encryption key pair (the migrated key).
    let bundle = bob.group.as_mut().unwrap()
        .self_update(&bob.provider, &bob.signer, LeafNodeParameters::default()).unwrap();
    bob.group.as_mut().unwrap().merge_pending_commit(&bob.provider).unwrap();
    alice.apply_commit_inner(&bundle.commit().tls_serialize_detached().unwrap()).expect("migrated alice applies commit");
    let reply = alice.encrypt_inner(&enc(ROOM, "alice", b"from migrated alice")).unwrap();
    assert_eq!(plain(&bob.decrypt_inner(&dec(ROOM, &reply)).unwrap()), b"from migrated alice");

    // Session path: a migrated open must be rewritten (export) before use.
    let framed_v1: Vec<_> = entries.iter().map(|(k, v)| (k.clone(), Some(v.clone()))).collect();
    let mut session = Session::open("alice", signer.public(), group.group_id().as_slice(), 1,
        &session::frame(&framed_v1)).expect("format-1 entries open");
    assert!(session.migrated());
    assert!(session.apply("encrypt", &enc(ROOM, "alice", b"x")).is_err(), "no operation before the rewrite");
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
        let ciphertext = alice.encrypt_inner(&enc(ROOM, "alice", &[i])).unwrap();
        bob.decrypt_inner(&dec(ROOM, &ciphertext)).unwrap();
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
    let step = alice.apply("encrypt", &enc(ROOM, "alice", b"after migrated merge")).unwrap();
    assert_eq!(plain(&bob.decrypt_inner(&dec(ROOM, &step.output())).unwrap()), b"after migrated merge");
}

/// Review F2 / M4: a session must never make durable a state `open` would
/// refuse. Unused KeyPackages were the one way to walk into that bound (one
/// entry each); the M4 cap now stops them long before it, with a pure
/// rejection the session survives, and the last durable state still reopens.
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
    let (at, error) = rejected_at.expect("unused key packages must hit a bound");
    assert_eq!((at, error), (MAX_KEY_PACKAGES, Rejected("key package limit")));
    assert_eq!(session.key_packages_outstanding() as usize, MAX_KEY_PACKAGES);
    assert!(session.entry_count() as usize <= staging::MAX_ENTRIES);
    let public_key = session.public_key();
    let exported = session.export().unwrap();
    Session::open("alice", &public_key, &[], Session::format_version(), &exported)
        .expect("the last durable state reopens");
}

/// Review M4: the cap is recoverable — deleting a published package (the relay
/// reported it consumed or expired) frees a slot; joining prunes every unused
/// one; foreign, unknown or already-deleted packages are refused without
/// touching state, in both the Session and the memory-only Device.
#[test]
fn key_package_cap_recovers_by_delete_and_join() {
    let mut alice = Peer::new("alice");
    let mut bob = Peer::new("bob");
    let packages: Vec<Vec<u8>> = (0..MAX_KEY_PACKAGES).map(|_| bob.step("key_package", &[])).collect();
    assert_eq!(bob.session.apply("key_package", &[]).err(), Some(Rejected("key package limit")));
    bob.assert_durable();
    // Not bob's package, and a package bob never minted: pure rejections.
    let foreign = alice.step("key_package", &[]);
    assert!(bob.session.apply("delete_key_package", &foreign).is_err());
    assert!(bob.session.apply("delete_key_package", &[1, 2, 3]).is_err());
    bob.assert_durable();
    bob.step("delete_key_package", &packages[0]);
    assert_eq!(bob.session.key_packages_outstanding() as usize, MAX_KEY_PACKAGES - 1);
    assert!(bob.session.apply("delete_key_package", &packages[0]).is_err(), "already deleted");
    bob.step("key_package", &[]);
    assert_eq!(bob.session.apply("key_package", &[]).err(), Some(Rejected("key package limit")));
    // Joining consumes one package (OpenMLS) and prunes the rest (facade).
    alice.step("create", &[]);
    let framed = alice.step("invite_with_commit", &packages[3]);
    alice.step("merge_pending", &[]);
    let commit_len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    // `step` asserts the mirror (deletes applied from `changes`) equals the store,
    // so the pruned entries provably left the durable set too.
    bob.step("join", &framed[4 + commit_len..]);
    assert_eq!(bob.session.key_packages_outstanding(), 0, "join prunes every unused package");
    let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", b"after prune"));
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &ciphertext))), b"after prune");
    // Memory-only Device: the same cap, and the bookkeeping never retires it.
    let mut carol = Device::new("carol").unwrap();
    let minted: Vec<Vec<u8>> = (0..MAX_KEY_PACKAGES).map(|_| carol.key_package().unwrap()).collect();
    assert_eq!(carol.key_package(), Err(Rejected("key package limit")));
    assert!(carol.delete_key_package(&foreign).is_err());
    carol.delete_key_package(&minted[1]).unwrap();
    assert_eq!(carol.key_packages_outstanding() as usize, MAX_KEY_PACKAGES - 1);
    carol.key_package().expect("slot freed; device not retired by the pure rejections");
}

/// Review M3: a length field that would make `4 + len` wrap on a 32-bit
/// `usize` (or index past the end on the host) is rejected before any
/// arithmetic; exactly `MAX_IDENTITY` still parses.
#[test]
fn split_identity_rejects_overflowing_lengths() {
    for len in [u32::MAX - 1, 0xFFFF_FFFC, u32::MAX, 65, 0] {
        let mut input = len.to_le_bytes().to_vec();
        input.extend_from_slice(b"family-payload");
        assert_eq!(split_identity(&input).err(), Some(rejected(())), "len {len:#x}");
    }
    let mut input = 64u32.to_le_bytes().to_vec();
    input.extend_from_slice(&[b'a'; 64]);
    input.extend_from_slice(b"rest");
    assert_eq!(split_identity(&input).unwrap(), ("a".repeat(64).as_str(), b"rest".as_slice()));
    assert!(split_identity(&[3, 0, 0, 0, b'a', b'b']).is_err(), "declared length past the end");
}

/// Review H1: three members; the AAD `client_id` a sender declares must be the
/// roster identity of its MLS-authenticated leaf. c signing as "a" is rejected
/// and rolled back on both receivers; honest output carries (sender, client).
#[test]
fn decrypt_binds_client_id_to_the_authenticated_sender() {
    let mut a = Peer::new("a");
    let mut b = Peer::new("b");
    let mut c = Peer::new("c");
    a.step("create", &[]);
    let packages = [b.step("key_package", &[]), c.step("key_package", &[])].concat();
    let framed = a.step("invite_with_commit", &packages);
    a.step("merge_pending", &[]);
    let commit_len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    b.step("join", &framed[4 + commit_len..]);
    c.step("join", &framed[4 + commit_len..]);

    let forged = c.step("encrypt", &enc(ROOM, "a", b"as if from a"));
    for receiver in [&mut a, &mut b] {
        let before = session_entries(&receiver.session);
        assert_eq!(receiver.session.apply("decrypt", &dec(ROOM, &forged)).err(), Some(Rejected("sender attribution rejected")));
        assert_eq!(session_entries(&receiver.session), before, "attribution rejection restores the store");
    }
    let honest = c.step("encrypt", &enc(ROOM, "c", b"really from c"));
    for receiver in [&mut a, &mut b] {
        assert_eq!(attributed(&receiver.step("decrypt", &dec(ROOM, &honest))),
            ("c".into(), "c".into(), b"really from c".to_vec()));
    }
    // Memory-only Device lane: the same rejection (and that device retires, as documented).
    let mut d = Device::new("d").unwrap();
    let mut e = Device::new("e").unwrap();
    d.create().unwrap();
    let welcome = d.invite(&e.key_package().unwrap()).unwrap();
    e.join(&welcome).unwrap();
    let forged = e.encrypt(&enc(ROOM, "d", b"x")).unwrap();
    assert_eq!(d.decrypt(&dec(ROOM, &forged)), Err(Rejected("sender attribution rejected")));
    assert_eq!(Device::decrypt_format(), 2);
}

/// Parse `frame_members` output from a cursor (used for the two-frame stage report).
fn take_roster(rest: &mut &[u8]) -> Vec<(String, Vec<u8>)> {
    let count = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
    *rest = &rest[4..];
    let mut out = Vec::new();
    for _ in 0..count {
        let len = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
        let identity = String::from_utf8(rest[4..4 + len].to_vec()).unwrap();
        let key = rest[4 + len..4 + len + 32].to_vec();
        *rest = &rest[4 + len + 32..];
        out.push((identity, key));
    }
    out
}

/// Review M2: while a commit is pending, `members()` is the old epoch and
/// `members_after_pending()` is the roster the relay must enforce.
#[test]
fn members_after_pending_tracks_staged_adds_and_removes() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let (key1, key2) = (a1.public_key().unwrap(), a2.public_key().unwrap());
    a1.create().unwrap();
    assert_eq!(a1.members_after_pending().unwrap(), a1.members().unwrap(), "no pending commit: identical");
    let framed = a1.invite_with_commit(&a2.key_package().unwrap()).unwrap();
    assert_eq!(roster(&a1.members().unwrap()), vec![("a:1".into(), key1.clone())], "old epoch until merge");
    assert_eq!(roster(&a1.members_after_pending().unwrap()),
        vec![("a:1".into(), key1.clone()), ("a:2".into(), key2.clone())], "pending add is visible");
    a1.merge_pending().unwrap();
    assert_eq!(a1.members_after_pending().unwrap(), a1.members().unwrap());
    let commit_len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    a2.join(&framed[4 + commit_len..]).unwrap();
    a1.remove_member_pending(&key2).unwrap();
    assert_eq!(roster(&a1.members_after_pending().unwrap()), vec![("a:1".into(), key1.clone())], "pending remove is applied");
    assert_eq!(roster(&a1.members().unwrap()).len(), 2);
    a1.clear_pending().unwrap();
    assert_eq!(roster(&a1.members_after_pending().unwrap()).len(), 2, "discarded commit: back to the live roster");
}

/// Review M1: an incoming commit can be staged, inspected (adds/removes with
/// identity + signing key) and only then merged or discarded; the roster does
/// not move until the merge, and the pure preconditions do not retire the device.
#[test]
fn stage_commit_reports_roster_changes_before_merge() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let key3 = a3.public_key().unwrap();
    a1.create().unwrap();
    let package = a2.key_package().unwrap();
    a2.join(&a1.invite(&package).unwrap()).unwrap();
    assert_eq!(a2.merge_staged(), Err(Rejected("nothing staged")));
    assert_eq!(a2.discard_staged(), Err(Rejected("nothing staged")));

    let framed = a1.invite_with_commit(&a3.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let commit_len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    let (commit, welcome) = (&framed[4..4 + commit_len], &framed[4 + commit_len..]);
    let report = a2.stage_commit(commit).unwrap();
    let mut rest = report.as_slice();
    let (adds, removes) = (take_roster(&mut rest), take_roster(&mut rest));
    assert!(rest.is_empty());
    assert_eq!((adds, removes), (vec![("a:3".to_string(), key3.clone())], vec![]));
    assert_eq!(roster(&a2.members().unwrap()).len(), 2, "not merged yet");
    assert_eq!(a2.stage_commit(commit), Err(Rejected("commit already staged")));
    assert_eq!(a2.apply_commit(commit), Err(Rejected("commit already staged")));
    a2.merge_staged().unwrap();
    assert_eq!(roster(&a2.members().unwrap()).len(), 3);
    a3.join(welcome).unwrap();
    let ciphertext = a3.encrypt(&enc(ROOM, "a:3", b"after staged merge")).unwrap();
    assert_eq!(attributed(&a2.decrypt(&dec(ROOM, &ciphertext)).unwrap()),
        ("a:3".into(), "a:3".into(), b"after staged merge".to_vec()));

    // A removal is reported with the removed member's identity and key; discarding
    // it leaves the device usable at its current epoch (a policy refusal).
    let commit = a1.remove_member_pending(&key3).unwrap();
    a1.merge_pending().unwrap();
    let report = a2.stage_commit(&commit).unwrap();
    let mut rest = report.as_slice();
    let (adds, removes) = (take_roster(&mut rest), take_roster(&mut rest));
    assert_eq!((adds, removes), (vec![], vec![("a:3".to_string(), key3)]));
    a2.discard_staged().unwrap();
    assert_eq!(roster(&a2.members().unwrap()).len(), 3, "discarded: roster untouched");
    assert!(a2.members_after_pending().is_ok(), "device still usable");
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
    assert!(alice.session.apply_trusted("encrypt", &enc(ROOM, "alice", b"x"), "carol", &bob_key).is_err());
    let ciphertext = trusted(&mut alice, "encrypt", &enc(ROOM, "alice", b"pinned hello"), "bob", &bob_key).unwrap();
    // decrypt_peer checks the MLS-authenticated sender against the pin.
    let before = session_entries(&bob.session);
    assert!(bob.session.apply_trusted("decrypt_peer", &dec(ROOM, &ciphertext), "alice", &bob_key).is_err());
    assert_eq!(session_entries(&bob.session), before, "sender-key mismatch rolls back (ratchet not consumed)");
    assert_eq!(attributed(&trusted(&mut bob, "decrypt_peer", &dec(ROOM, &ciphertext), "alice", &alice_key).unwrap()),
        ("alice".into(), "alice".into(), b"pinned hello".to_vec()), "framed attribution in the trusted lane too");
}

// ---- policy v4 approval evidence (#177 M3c, DEVICES-V4.md) ----

fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }

/// Parsed `members()` frame: sorted (identity, signing key) pairs.
fn roster(frame: &[u8]) -> Vec<(String, Vec<u8>)> {
    let count = u32::from_le_bytes(frame[..4].try_into().unwrap()) as usize;
    let mut rest = &frame[4..];
    let mut out = Vec::new();
    for _ in 0..count {
        let len = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
        let identity = String::from_utf8(rest[4..4 + len].to_vec()).unwrap();
        rest = &rest[4 + len..];
        let key = rest[..32].to_vec();
        rest = &rest[32..];
        out.push((identity, key));
    }
    assert!(rest.is_empty(), "trailing bytes in members frame");
    out
}

/// Canonical payload + signature from `sign_approval`, split at the length prefix.
fn evidence(device: &mut Device, action: &str, acceptance: &str, base_revision: u64)
            -> (Vec<u8>, Vec<u8>) {
    let framed = device.sign_approval(action, "a:2", "a", "person-a", CANDIDATE_KEY_HEX,
                                      acceptance, base_revision).expect("evidence");
    let len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    (framed[4..4 + len].to_vec(), framed[4 + len..].to_vec())
}

/// Generated from `devicepolicy.ApprovalMessage` (Go, module archive/native-mls/server)
/// for the payloads pinned below. If this test fails, the facade and the owner CLI
/// disagree on canonical bytes — never regenerate the fixture from the Rust side.
const GO_APPROVE_MESSAGE_HEX: &str = "66616d696c792d6d6c732d76322f617070726f76652d646576696365007550e65fb9904401f483271345196164be5f338390c93c2349802963c63da75f";
const GO_REVOKE_MESSAGE_HEX: &str = "66616d696c792d6d6c732d76322f7265766f6b652d646576696365005e8b2e5748c9b372614550137243c11bcaffbd7a47a6c468791da17e66968a4a";
const CANDIDATE_KEY_HEX: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const CANDIDATE_FINGERPRINT_HEX: &str = "02d449a31fbb267c8f352e9968a79e3e5fc95c1bbeaa502fd6454ebde5a4bedc";

#[test]
fn approval_message_bytes_match_go_approval_message() {
    let mut approver = Device::new("a:1").unwrap();
    let (canonical, signature) = evidence(&mut approver, "approve-device",
                                          "trusted-device-fingerprint", 3);
    assert_eq!(String::from_utf8(canonical.clone()).unwrap(), format!(
        r#"{{"action":"approve-device","device_id":"a:2","actor":"a","subject":"person-a","signing_key":"{CANDIDATE_KEY_HEX}","fingerprint":"{CANDIDATE_FINGERPRINT_HEX}","acceptance":"trusted-device-fingerprint","base_revision":3}}"#),
        "canonical payload is the exact Go field order, compact");
    let message = [b"family-mls-v2/approve-device\0".as_slice(),
                   &staging::staged_checksum(&canonical).unwrap()].concat();
    assert_eq!(hex(&message), GO_APPROVE_MESSAGE_HEX, "domain-separated digest matches Go");
    assert_eq!(signature.len(), 64, "compact Ed25519 signature (Go crypto/ed25519 verifies)");

    // The Go fixture above was generated with the out-of-band acceptance (E1 target).
    let (canonical, signature) = evidence(&mut approver, "revoke-device",
                                          "out-of-band-fingerprint", 6);
    let message = [b"family-mls-v2/revoke-device\0".as_slice(),
                   &staging::staged_checksum(&canonical).unwrap()].concat();
    assert_eq!(hex(&message), GO_REVOKE_MESSAGE_HEX);
    assert_eq!(signature.len(), 64);
}

#[test]
fn approval_rejections_are_pure_and_self_approval_is_refused() {
    let mut approver = Device::new("a:1").unwrap();
    let own_key_hex = hex(&approver.public_key().unwrap());
    // 자기 승인: own id or own key, for both actions.
    for action in ["approve-device", "revoke-device"] {
        assert!(approver.sign_approval(action, "a:1", "a", "person-a", CANDIDATE_KEY_HEX,
                                       "trusted-device-fingerprint", 2).is_err(), "own id");
        assert!(approver.sign_approval(action, "a:2", "a", "person-a", &own_key_hex,
                                       "trusted-device-fingerprint", 2).is_err(), "own key");
    }
    // Every malformed input is refused before any state is touched.
    for (action, device, subject, key, acceptance, base) in [
        ("sign-device", "a:2", "person-a", CANDIDATE_KEY_HEX, "trusted-device-fingerprint", 2), // unknown action
        ("approve-device", "a:2", "person-a", CANDIDATE_KEY_HEX, "out-of-band-fingerprint", 2), // approve is trusted-only
        ("revoke-device", "a:2", "person-a", CANDIDATE_KEY_HEX, "free-fingerprint", 2),         // unknown acceptance
        ("approve-device", "a:2", "person-a", CANDIDATE_KEY_HEX, "trusted-device-fingerprint", 0), // revision 0
        ("approve-device", "a:2", "person-a", &"AB".repeat(32), "trusted-device-fingerprint", 2), // uppercase hex
        ("approve-device", "a:2", "person-a", "1111", "trusted-device-fingerprint", 2),         // short key
        ("approve-device", "a:2", "person a", CANDIDATE_KEY_HEX, "trusted-device-fingerprint", 2), // charset
        ("approve-device", "a/2", "person-a", CANDIDATE_KEY_HEX, "trusted-device-fingerprint", 2), // charset
    ] {
        assert!(approver.sign_approval(action, device, "a", subject, key, acceptance, base)
            .is_err(), "{action} {device} {subject}");
    }
    // The device survived every pure rejection: it still creates a group and talks.
    approver.create().unwrap();
    let plaintext = approver.encrypt(&enc(ROOM, "person-a", b"still usable")).unwrap();
    assert!(!plaintext.is_empty());
    assert_eq!(approver.fingerprint().unwrap(),
               policy::policy_fingerprint(&own_key_hex).unwrap(),
               "fingerprint stays sha256(public key)");
}

#[test]
fn members_tracks_add_and_remove() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let key2 = a2.public_key().unwrap();
    a1.create().unwrap();
    assert_eq!(roster(&a1.members().unwrap()),
        vec![("a:1".into(), a1.public_key().unwrap())], "creator alone after create");
    let welcome = a1.invite(&a2.key_package().unwrap()).unwrap();
    let listed = roster(&a1.members().unwrap());
    assert_eq!(listed, vec![("a:1".into(), a1.public_key().unwrap()), ("a:2".into(), key2.clone())],
        "post-commit roster, sorted by identity");
    a2.join(&welcome).unwrap();
    assert_eq!(a2.members().unwrap(), a1.members().unwrap(), "both sides agree");
    a1.remove_member(&key2).unwrap();
    assert_eq!(roster(&a1.members().unwrap()), vec![("a:1".into(), a1.public_key().unwrap())],
        "removal leaves the sender alone");
    assert!(Device::new("a:3").unwrap().members().is_err(), "no group, no roster");
}

#[test]
fn policy_fingerprint_is_sha256_of_key_bytes() {
    assert_eq!(policy::policy_fingerprint(CANDIDATE_KEY_HEX).unwrap(), CANDIDATE_FINGERPRINT_HEX);
    assert!(policy::policy_fingerprint("1111").is_err(), "32 bytes required");
    assert!(policy::policy_fingerprint(&"AB".repeat(32)).is_err(), "lowercase hex only");
}

