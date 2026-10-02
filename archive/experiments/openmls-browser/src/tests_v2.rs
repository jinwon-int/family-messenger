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
    assert!(alice.session.apply("encrypt", &enc(ROOM, "alice", &[0; MAX_ATTACHMENT + 1])).is_err());
    let step = alice.session.apply("encrypt", &enc(ROOM, "alice", &[0; 16384])).unwrap();
    persist(&mut alice.mirror, &step.changes());
    alice.session.commit().unwrap();
}

/// M5 (#177 §4): an attachment at the full 256 KiB bound rides as one MLS
/// application message. Measures the exact wire cost the relay sees — the
/// number the PR body and the bot smoke receipt quote — and proves the decrypt
/// side's `MAX_WIRE` still accepts the ciphertext.
#[test]
fn attachment_256kib_rounds_trip() {
    let (mut alice, mut bob) = pair();
    let mut attachment = vec![0u8; MAX_ATTACHMENT];
    let mut state = 0x5eed_u32;
    for byte in &mut attachment {
        state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        *byte = (state >> 24) as u8;
    }
    let ciphertext = alice.step("encrypt", &enc(ROOM, "alice", &attachment));
    println!(
        "attachment measurement: plaintext {} B, ciphertext {} B (+{} B MLS overhead), MAX_WIRE {MAX_WIRE}",
        attachment.len(),
        ciphertext.len(),
        ciphertext.len() - attachment.len(),
    );
    assert!(ciphertext.len() > MAX_ATTACHMENT, "sanity: framing adds bytes");
    assert!(ciphertext.len() <= MAX_WIRE, "ciphertext must fit the wire bound");
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &ciphertext))), attachment);
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

/// Parse `frame_members` output from a cursor (used for the stage-report sections).
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

/// Parsed `stage_commit` report (`STAGE_REPORT_FORMAT` 2): the four
/// `frame_members` sections — adds, removes, update proposals, committer path.
type StageReport = (Vec<(String, Vec<u8>)>, Vec<(String, Vec<u8>)>, Vec<(String, Vec<u8>)>, Vec<(String, Vec<u8>)>);

fn stage_report(report: &[u8]) -> StageReport {
    let mut rest = report;
    let [adds, removes, updates, path] = std::array::from_fn(|_| take_roster(&mut rest));
    assert!(rest.is_empty(), "trailing bytes after the four stage-report sections");
    (adds, removes, updates, path)
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
/// J-MB (#231): the report also carries update proposals and the committer's
/// path leaf — the updates section is empty for an add-only commit, while the
/// committer's path leaf rides every member commit (OpenMLS 0.9), keeping the
/// same signing key across an add or remove.
#[test]
fn stage_commit_reports_roster_changes_before_merge() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let key1 = a1.public_key().unwrap();
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
    let (adds, removes, updates, path) = stage_report(&a2.stage_commit(commit).unwrap());
    assert_eq!((adds, removes), (vec![("a:3".to_string(), key3.clone())], vec![]));
    assert_eq!(updates, vec![], "no update proposals in an add-only commit");
    assert_eq!(path, vec![("a:1".to_string(), key1.clone())],
        "the committer's path leaf rides every member commit (OpenMLS 0.9)");
    assert_eq!(roster(&a2.members().unwrap()).len(), 2, "not merged yet");
    assert_eq!(a2.stage_commit(commit), Err(Rejected("commit already staged")));
    assert_eq!(a2.apply_commit(commit), Err(Rejected("commit already staged")));
    a2.merge_staged().unwrap();
    assert_eq!(roster(&a2.members().unwrap()).len(), 3);
    a3.join(welcome).unwrap();
    let ciphertext = a3.encrypt(&enc(ROOM, "a:3", b"after staged merge")).unwrap();
    assert_eq!(attributed(&a2.decrypt(&dec(ROOM, &ciphertext)).unwrap()),
        ("a:3".into(), "a:3".into(), b"after staged merge".to_vec()));

    // A removal is reported with the removed member's identity and key; the
    // committer's path leaf is reported too (identity unchanged, same key —
    // no new signer — but a consumer still sees the leaf replacement).
    // Discarding it leaves the device usable at its current epoch (a policy
    // refusal).
    let commit = a1.remove_member_pending(&key3).unwrap();
    a1.merge_pending().unwrap();
    let (adds, removes, updates, path) = stage_report(&a2.stage_commit(&commit).unwrap());
    assert_eq!((adds, removes, updates), (vec![], vec![("a:3".to_string(), key3)], vec![]));
    assert_eq!(path, vec![("a:1".to_string(), key1)], "remove commits always carry the committer's path");
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

/// Review 2 J-MA (#231): merging a foreign commit clears an own pending commit
/// (OpenMLS), so the loser of a commit race that catches up first and then
/// clears must see a plain rejection and keep its device — not retire it.
#[test]
fn foreign_commit_while_pending_then_clear_pending_does_not_retire() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let mut a4 = Device::new("a:4").unwrap();
    a1.create().unwrap();
    let framed = a1.invite_with_commit(&a2.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let n = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    a2.join(&framed[4 + n..]).unwrap();

    // a1 and a2 race: both commit an add at the same epoch; the relay orders a2 first.
    let losing = a1.invite_with_commit(&a3.key_package().unwrap()).unwrap();
    assert!(a1.has_pending());
    let winning = a2.invite_with_commit(&a4.key_package().unwrap()).unwrap();
    a2.merge_pending().unwrap();
    let wn = u32::from_le_bytes(winning[..4].try_into().unwrap()) as usize;
    // Catch up first (documented order: process everything the relay placed
    // before the 409), which clears the pending commit inside OpenMLS…
    a1.apply_commit(&winning[4..4 + wn]).unwrap();
    assert!(!a1.has_pending(), "a foreign merge clears the own pending commit");
    // …then the 409 handler clears: before #231 this retired the device.
    assert_eq!(a1.clear_pending(), Err(Rejected("nothing pending")));
    assert_eq!(a1.merge_pending(), Err(Rejected("nothing pending")));
    assert_eq!(roster(&a1.members().unwrap()).len(), 3, "a1 is at the winner's epoch");
    // Still usable: the retry of the lost add goes through.
    let retry = a1.invite_with_commit(&a3.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let rn = u32::from_le_bytes(retry[..4].try_into().unwrap()) as usize;
    a2.apply_commit(&retry[4..4 + rn]).unwrap();
    let _ = losing;
    assert_eq!(roster(&a2.members().unwrap()).len(), 4);
}

/// Review 2 J-HB (#231): an application message from the previous epoch — the
/// relay ordered it before a commit, or the reader merged its own commit before
/// reading it — decrypts within the bounded past-epoch window instead of being
/// rejected (and, in the durable lane, tombstoned as poison).
#[test]
fn past_epoch_application_messages_decrypt_within_window() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    a1.create().unwrap();
    let mut packages = a2.key_package().unwrap();
    packages.extend(a3.key_package().unwrap());
    let framed = a1.invite_with_commit(&packages).unwrap();
    a1.merge_pending().unwrap();
    let n = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    a2.join(&framed[4 + n..]).unwrap();
    a3.join(&framed[4 + n..]).unwrap();

    // a3 sends at epoch 1; a1 commits (remove a2) and merges BEFORE reading it.
    let old = a3.encrypt(&enc(ROOM, "a:3", b"sent before the commit")).unwrap();
    let key2 = a2.public_key().unwrap();
    let commit = a1.remove_member(&key2).unwrap();
    assert_eq!(plain(&a1.decrypt(&dec(ROOM, &old)).unwrap()), b"sent before the commit");
    // a3 applies the commit and can still read a message a1 sent at the old
    // epoch that arrives late (a1 encrypted before merging, i.e. at epoch 1).
    let late = {
        // a2 (about to be removed) sends at epoch 1 too.
        a2.encrypt(&enc(ROOM, "a:2", b"late from a2")).unwrap()
    };
    a3.apply_commit(&commit).unwrap();
    assert_eq!(plain(&a3.decrypt(&dec(ROOM, &late)).unwrap()), b"late from a2");
    // Beyond the window (PAST_EPOCHS commits later) the old secrets are gone:
    // a message that old is rejected, and the device rolls back/retires as
    // before rather than silently decrypting with stale keys.
    let mut extra = Vec::new();
    for i in 0..PAST_EPOCHS {
        let mut d = Device::new(&format!("x:{i}")).unwrap();
        let f = a1.invite_with_commit(&d.key_package().unwrap()).unwrap();
        a1.merge_pending().unwrap();
        let m = u32::from_le_bytes(f[..4].try_into().unwrap()) as usize;
        a3.apply_commit(&f[4..4 + m]).unwrap();
        d.join(&f[4 + m..]).unwrap();
        extra.push(d);
    }
    let ancient = a2.encrypt(&enc(ROOM, "a:2", b"too old")).unwrap();
    assert!(a3.decrypt(&dec(ROOM, &ancient)).is_err(), "messages older than the window stay rejected");
}

/// Review 2 J-HA (#231): the staged two-phase commit is reachable from the
/// memory worker; staging then discarding a commit keeps the device usable
/// and the next incoming commit can still be staged.
#[test]
fn stage_then_discard_keeps_device_usable_for_the_next_commit() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    a1.create().unwrap();
    let package2 = a2.key_package().unwrap();
    a2.join(&a1.invite(&package2).unwrap()).unwrap();
    let first = a1.invite_with_commit(&a3.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let n = u32::from_le_bytes(first[..4].try_into().unwrap()) as usize;
    a2.stage_commit(&first[4..4 + n]).unwrap();
    a2.discard_staged().unwrap();
    assert_eq!(roster(&a2.members().unwrap()).len(), 2, "discarded: epoch unchanged");
    // The discarded epoch cannot be re-staged (handshake secrets consumed)…
    assert!(a2.stage_commit(&first[4..4 + n]).is_err());
    // …so a2 is a fresh device for the policy refusal case: the usual path is
    // to be re-added. A different device that staged and merged keeps going.
    let mut b1 = Device::new("b:1").unwrap();
    let second = a1.invite_with_commit(&b1.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let m = u32::from_le_bytes(second[..4].try_into().unwrap()) as usize;
    a3.join(&first[4 + n..]).unwrap();
    let report = a3.stage_commit(&second[4..4 + m]).unwrap();
    let (adds, removes, updates, path) = stage_report(&report);
    assert_eq!(adds.len(), 1);
    assert_eq!((removes, updates), (vec![], vec![]), "no roster delta beyond the add");
    assert_eq!(path.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(), vec!["a:1"],
        "exactly the committer's path leaf");
    a3.merge_staged().unwrap();
    b1.join(&second[4 + m..]).unwrap();
    let wire = b1.encrypt(&enc(ROOM, "b:1", b"after merge")).unwrap();
    assert_eq!(plain(&a3.decrypt(&dec(ROOM, &wire)).unwrap()), b"after merge");
}

/// Review 2 J-MB (#231): a commit can carry an identity→key change that
/// adds/removes cannot express — the committer's own path leaf, here with a
/// NEW signing key. The stage report surfaces it in section 4; the roster
/// moves only at the merge, matches the report afterwards, and the rotated
/// member talks under its new key while a member that has not applied the
/// commit is rejected until it catches up. Update proposals are different:
/// public builders commit them by REFERENCE and this relay lane carries no
/// standalone proposals, so section 3 is defence in depth — a commit that
/// references a proposal the device never saw is refused (`MissingProposal`),
/// and like every MLS-level rejection that refusal retires the device.
#[test]
fn stage_report_covers_the_committer_path_and_refuses_unseen_proposals() {
    use openmls_rust_crypto::OpenMlsRustCrypto;
    let provider = OpenMlsRustCrypto::default();
    let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    signer.store(provider.storage()).unwrap();
    let alice_credential = CredentialWithKey {
        credential: BasicCredential::new(b"alice".to_vec()).into(),
        signature_key: signer.public().into(),
    };
    let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE)
        .use_ratchet_tree_extension(true).build();
    let mut alice = MlsGroup::new(&provider, &signer, &config, alice_credential).unwrap();

    // Raw bob and facade carol join.
    let bob_provider = OpenMlsRustCrypto::default();
    let bob_signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    bob_signer.store(bob_provider.storage()).unwrap();
    let bob_package = KeyPackage::builder().build(SUITE, &bob_provider, &bob_signer, CredentialWithKey {
        credential: BasicCredential::new(b"bob".to_vec()).into(),
        signature_key: bob_signer.public().into(),
    }).unwrap().key_package().clone();
    let mut carol = Device::new("carol").unwrap();
    let carol_package = KeyPackageIn::tls_deserialize_exact_bytes(&carol.key_package().unwrap()).unwrap()
        .validate(provider.crypto(), ProtocolVersion::Mls10).unwrap();
    let (_, welcome, _) = alice.add_members(&provider, &signer, &[bob_package, carol_package]).unwrap();
    alice.merge_pending_commit(&provider).unwrap();
    let welcome_bytes = welcome.tls_serialize_detached().unwrap();
    let join_config = MlsGroupJoinConfig::builder().use_ratchet_tree_extension(true).build();
    let MlsMessageBodyIn::Welcome(welcome_message) =
        MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes).unwrap().extract() else { unreachable!() };
    let mut bob = StagedWelcome::new_from_welcome(&bob_provider, &join_config, welcome_message, None).unwrap()
        .into_group(&bob_provider).unwrap();
    carol.join(&welcome_bytes).unwrap();

    // alice rotates her SIGNING key in a plain self-update: no add, no remove,
    // no update proposal — the change rides solely in the committer's path.
    let alice_new_signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    alice_new_signer.store(provider.storage()).unwrap();
    let bundle = alice.self_update_with_new_signer(&provider, &signer, NewSignerBundle {
        signer: &alice_new_signer,
        credential_with_key: CredentialWithKey {
            credential: BasicCredential::new(b"alice".to_vec()).into(),
            signature_key: alice_new_signer.public().into(),
        },
    }, LeafNodeParameters::default()).unwrap();
    alice.merge_pending_commit(&provider).unwrap();
    let commit_bytes = bundle.commit().tls_serialize_detached().unwrap();

    // carol stages BEFORE merging: sections 1–3 empty, section 4 is the
    // committer's authoritative post-commit identity→key pair — the new key.
    let (adds, removes, updates, path) = stage_report(&carol.stage_commit(&commit_bytes).unwrap());
    assert_eq!((adds, removes, updates), (vec![], vec![], vec![]));
    assert_eq!(path, vec![("alice".to_string(), alice_new_signer.public().to_vec())],
        "the path section reports the committer's rotated signing key");
    assert_eq!(
        roster(&carol.members().unwrap()).iter().find(|(id, _)| id == "alice").unwrap().1,
        signer.public().to_vec(), "pre-merge roster still shows the old key");
    carol.merge_staged().unwrap();
    assert_eq!(
        roster(&carol.members().unwrap()).iter().find(|(id, _)| id == "alice").unwrap().1,
        alice_new_signer.public().to_vec(), "merged roster matches the reported path");

    // The rotated member talks under its new key end-to-end (raw sender →
    // facade receiver, AAD binding as §3.6 requires) — the facade accepts
    // traffic signed with exactly the key the report pinned.
    alice.set_aad(aad_bytes(ROOM.as_bytes(), alice.group_id().as_slice(), b"alice", b"alice", alice.epoch().as_u64()));
    let wire = alice.create_message(&provider, &alice_new_signer, b"under the new key").unwrap()
        .tls_serialize_detached().unwrap();
    assert_eq!(attributed(&carol.decrypt_inner(&dec(ROOM, &wire)).unwrap()),
        ("alice".into(), "alice".into(), b"under the new key".to_vec()));

    // bob has not applied the commit: alice's new-epoch message is rejected
    // until bob catches up, after which the same message reads.
    let parse_wire = || MlsMessageIn::tls_deserialize_exact_bytes(&wire).unwrap()
        .try_into_protocol_message().unwrap();
    assert!(bob.process_message(&bob_provider, parse_wire()).is_err(),
        "a member behind the commit cannot read the new epoch");
    let parse_commit = || MlsMessageIn::tls_deserialize_exact_bytes(&commit_bytes).unwrap()
        .try_into_protocol_message().unwrap();
    let processed = bob.process_message(&bob_provider, parse_commit()).unwrap();
    let ProcessedMessageContent::StagedCommitMessage(staged) = processed.into_content() else { unreachable!() };
    bob.merge_staged_commit(&bob_provider, *staged).unwrap();
    let caught_up = bob.process_message(&bob_provider, parse_wire()).unwrap();
    let ProcessedMessageContent::ApplicationMessage(message) = caught_up.into_content() else { unreachable!() };
    assert_eq!(message.into_bytes(), b"under the new key");

    // Section 3 (update proposals) is defence in depth: public builders commit
    // proposals by REFERENCE and this lane carries no standalone proposals, so
    // the lane can only ever see a commit that references a proposal it never
    // stored. bob proposes a leaf update; alice — which did store the proposal
    // — commits it by reference; carol never saw the proposal and the stage is
    // REFUSED, retiring the device like every MLS-level rejection (no
    // uncertain state survives, there is no recovery).
    let bob_new_signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    bob_new_signer.store(bob_provider.storage()).unwrap();
    let (proposal, _) = bob.propose_self_update_with_new_signer(&bob_provider, &bob_signer,
        NewSignerBundle {
            signer: &bob_new_signer,
            credential_with_key: CredentialWithKey {
                credential: BasicCredential::new(b"bob".to_vec()).into(),
                signature_key: bob_new_signer.public().into(),
            },
        },
        LeafNodeParameters::default()).unwrap();
    let processed = alice.process_message(&provider,
        MlsMessageIn::from(proposal).try_into_protocol_message().unwrap()).unwrap();
    let ProcessedMessageContent::ProposalMessage(proposal) = processed.into_content() else { unreachable!() };
    alice.store_pending_proposal(provider.storage(), *proposal).unwrap();
    let (commit, _, _) = alice.commit_to_pending_proposals(&provider, &alice_new_signer).unwrap();
    alice.merge_pending_commit(&provider).unwrap();
    let referenced = commit.tls_serialize_detached().unwrap();
    assert_eq!(carol.stage_commit(&referenced), Err(Rejected("MLS operation rejected")),
        "a commit referencing a proposal this lane never carried is refused");
    assert_eq!(carol.stage_commit(&referenced), Err(Rejected("device retired")),
        "the refusal is fail-closed: the device is retired, nothing pending survives");
}

/// Review 2 J-MB (#231), batch (e): three members, two commits racing at the
/// same epoch, and the loser catching up through the STAGED two-phase path.
/// Staging a foreign commit while an own commit is pending is allowed (the
/// staged slot and the pending commit are separate); merging the staged
/// foreign commit silently consumed the own pending commit exactly like
/// `apply_commit` (review 2 J-MA) — a pure rejection afterwards, never a
/// retired device — and the lost operation retries at the new epoch.
#[test]
fn stage_commit_while_own_pending_destroys_it_and_reports_the_winner() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let mut a4 = Device::new("a:4").unwrap();
    let key3 = a3.public_key().unwrap();
    a1.create().unwrap();
    let mut last_commit = Vec::new();
    for joiner in [&mut a2, &mut a3] {
        let framed = a1.invite_with_commit(&joiner.key_package().unwrap()).unwrap();
        a1.merge_pending().unwrap();
        let n = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
        joiner.join(&framed[4 + n..]).unwrap();
        last_commit = framed[..4 + n].to_vec();
    }
    // a2 catches up with a3's add so both racers start from the same epoch.
    a2.apply_commit(&last_commit[4..]).unwrap();
    assert_eq!(roster(&a2.members().unwrap()).len(), 3);

    // Same epoch, two competing commits: a1 removes a3, a2 invites a4. The
    // relay orders a2's commit first.
    let losing = a1.remove_member_pending(&key3).unwrap();
    assert!(a1.has_pending());
    let winning = a2.invite_with_commit(&a4.key_package().unwrap()).unwrap();
    a2.merge_pending().unwrap();
    let wn = u32::from_le_bytes(winning[..4].try_into().unwrap()) as usize;
    let (wcommit, wwelcome) = (&winning[4..4 + wn], &winning[4 + wn..]);

    // The loser stages the winner's commit while its own is still pending:
    // the report is exactly the winner's add plus the committer's path leaf
    // (OpenMLS 0.9 rides it on every member commit) — no updates or removes.
    let (adds, removes, updates, path) = stage_report(&a1.stage_commit(wcommit).unwrap());
    assert_eq!(adds, vec![("a:4".into(), a4.public_key().unwrap())]);
    assert_eq!((removes, updates), (vec![], vec![]));
    assert_eq!(path, vec![("a:2".into(), a2.public_key().unwrap())],
        "the committer's path leaf rides every member commit (OpenMLS 0.9)");

    // Merging the staged foreign commit consumed the own pending commit
    // (OpenMLS): a1 is at the winner's epoch, a4 added, a3 kept.
    a1.merge_staged().unwrap();
    assert!(!a1.has_pending(), "a foreign merge clears the own pending commit");
    assert_eq!(a1.clear_pending(), Err(Rejected("nothing pending")));
    assert_eq!(a1.merge_pending(), Err(Rejected("nothing pending")));
    assert_eq!(roster(&a1.members().unwrap()).len(), 4);
    // a3 catches up via apply (staging it would hit its "already staged" slot
    // only if it had one — it does not) and hears a4 at the new epoch.
    a3.apply_commit(wcommit).unwrap();
    a4.join(wwelcome).unwrap();
    let wire = a4.encrypt(&enc(ROOM, "a:4", b"hello from a4")).unwrap();
    assert_eq!(plain(&a3.decrypt(&dec(ROOM, &wire)).unwrap()), b"hello from a4");

    // The lost removal retries cleanly at the winner's epoch.
    let retry = a1.remove_member_pending(&key3).unwrap();
    a1.merge_pending().unwrap();
    a2.apply_commit(&retry).unwrap();
    assert_eq!(roster(&a1.members().unwrap()).len(), 3);
    assert_eq!(roster(&a2.members().unwrap()).len(), 3);
    let _ = losing;
}

/// Review 2 L (#231), batch (f): `clear_proposal_queue` — inherited verbatim
/// from upstream `openmls_memory_storage` 0.6.0 — removed QueuedProposal
/// entries under the raw tuple key while `queue_proposal` writes them under
/// the labelled/versioned key, so every queued proposal was orphaned in the
/// store once the queue was cleared (a leak that also kept retired ratchet
/// material around). On the facade's own [`store::Store`]: a self-update
/// proposal is queued (1 entry), committing it by reference and merging
/// clears the queue (0 entries, 0 refs).
#[test]
fn clear_proposal_queue_removes_queued_proposals() {
    let provider = Provider::default();
    let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).unwrap();
    signer.store(provider.storage()).unwrap();
    let credential = CredentialWithKey {
        credential: BasicCredential::new(b"alice".to_vec()).into(),
        signature_key: signer.public().into(),
    };
    let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE)
        .use_ratchet_tree_extension(true).build();
    let mut alice = MlsGroup::new(&provider, &signer, &config, credential).unwrap();
    let queued = || provider.storage().count_with_label(b"QueuedProposal");
    let refs = || provider.storage().count_with_label(b"ProposalQueueRefs");
    assert_eq!((queued(), refs()), (0, 0));

    let (_proposal, _ref) = alice.propose_self_update(&provider, &signer, LeafNodeParameters::default()).unwrap();
    assert_eq!((queued(), refs()), (1, 1), "the own proposal is queued under the labelled key");

    let (_commit, _, _) = alice.commit_to_pending_proposals(&provider, &signer).unwrap();
    alice.merge_pending_commit(&provider).unwrap();
    assert_eq!(queued(), 0, "clear_proposal_queue must remove the QueuedProposal entry (was orphaned before change 4)");
    assert_eq!(refs(), 0, "and the refs list");
}

// ---- Batch g (#231 후속): the durable lane (`Session.apply` + journal +
// reopen) under the same races the memory lane proved in batches c/e, plus
// three committers at one epoch and a winner that evicts a loser mid-pending.

/// alice, bob, carol in one group through the durable lane; every step is
/// mirrored and verified like the IDB worker would.
fn trio() -> (Peer, Peer, Peer) {
    let (mut alice, mut bob) = pair();
    let mut carol = Peer::new("carol");
    let package = carol.step("key_package", &[]);
    let framed = alice.step("invite_with_commit", &package);
    alice.step("merge_pending", &[]);
    let n = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    bob.step("commit", &framed[4..4 + n]);
    carol.step("join", &framed[4 + n..]);
    (alice, bob, carol)
}

fn split_framed(framed: &[u8]) -> (&[u8], &[u8]) {
    let n = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    (&framed[4..4 + n], &framed[4 + n..])
}

#[test]
fn durable_lane_foreign_commit_while_own_pending_then_reopen() {
    let (mut alice, mut bob, mut carol) = trio();
    let mut dave = Peer::new("dave");
    let carol_key = carol.session.public_key();

    // alice's removal of carol is pending (durable: the pending commit is in
    // the mirror) when bob's add of dave wins the relay order.
    alice.step("remove_pending", &carol_key);
    assert!(alice.session.has_pending_commit());
    let winning = bob.step("invite_with_commit", &dave.step("key_package", &[]));
    bob.step("merge_pending", &[]);
    let (wcommit, wwelcome) = split_framed(&winning);

    // Catch up through the durable lane: the foreign merge consumed the own
    // pending commit, the journal recorded it, the mirror matches.
    alice.step("commit", wcommit);
    assert!(!alice.session.has_pending_commit(), "a foreign merge clears the own pending commit");
    // The 409 handler's clear is a pure rejection — nothing in flight, store
    // unchanged, session still usable (review 2 J-MA on the durable lane).
    let before = session_entries(&alice.session);
    assert!(alice.session.apply("clear_pending", &[]).is_err());
    assert_eq!(session_entries(&alice.session), before, "a rejected clear_pending changes nothing");
    assert!(alice.session.pending_changes() == session::frame(&[]));
    carol.step("commit", wcommit);
    dave.step("join", wwelcome);

    // Reopened from nothing but the mirror, alice is at the winner's epoch
    // with no pending commit, and talks to the new member.
    let mut reopened = alice.reopen("alice");
    assert!(!reopened.has_pending_commit());
    assert_eq!(reopened.current_epoch(), bob.session.current_epoch());
    let wire = dave.step("encrypt", &enc(ROOM, "dave", b"hello from dave"));
    let step = reopened.apply("decrypt", &dec(ROOM, &wire)).expect("reopened decrypts at the new epoch");
    assert_eq!(plain(&step.output()), b"hello from dave");
    reopened.commit().unwrap();

    // The lost removal retries cleanly at the new epoch.
    let retry = reopened.apply("remove_pending", &carol_key).expect("retry");
    reopened.commit().unwrap();
    reopened.apply("merge_pending", &[]).expect("merge").epoch();
    reopened.commit().unwrap();
    let rcommit = retry.output(); // remove_pending yields the bare commit (no Welcome)
    bob.step("commit", &rcommit);
    dave.step("commit", &rcommit);
    let wire = bob.step("encrypt", &enc(ROOM, "bob", b"after the retry"));
    assert_eq!(plain(&reopened.apply("decrypt", &dec(ROOM, &wire)).unwrap().output()), b"after the retry");
}

#[test]
fn durable_lane_pending_commit_survives_reopen_and_merges() {
    let (mut alice, mut bob, mut carol) = trio();
    let carol_key = carol.session.public_key();
    let commit = alice.step("remove_pending", &carol_key); // bare commit
    assert!(alice.session.has_pending_commit());

    // The pending commit is part of the durable state: a session reopened
    // from the mirror still has it, and can merge it after the relay 201.
    let mut reopened = alice.reopen("alice");
    assert!(reopened.has_pending_commit(), "pending commit must be durable, not in-memory only");
    reopened.apply("merge_pending", &[]).expect("merge after reopen");
    reopened.commit().unwrap();
    assert!(!reopened.has_pending_commit());
    bob.step("commit", &commit);
    let wire = reopened.apply("encrypt", &enc(ROOM, "alice", b"two of us")).unwrap();
    reopened.commit().unwrap();
    assert_eq!(plain(&bob.step("decrypt", &dec(ROOM, &wire.output()))), b"two of us");
    // carol was removed: her next decrypt of the new epoch is rejected and
    // rolled back, not a retired session.
    let before = session_entries(&carol.session);
    assert!(carol.session.apply("decrypt", &dec(ROOM, &wire.output())).is_err());
    assert_eq!(session_entries(&carol.session), before);
}

#[test]
fn three_committers_race_at_one_epoch_losers_retry_in_relay_order() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let mut j1 = Device::new("j:1").unwrap();
    let mut j2 = Device::new("j:2").unwrap();
    let mut j3 = Device::new("j:3").unwrap();
    a1.create().unwrap();
    let mut commits = Vec::new();
    for joiner in [&mut a2, &mut a3] {
        let framed = a1.invite_with_commit(&joiner.key_package().unwrap()).unwrap();
        a1.merge_pending().unwrap();
        let (c, w) = split_framed(&framed);
        joiner.join(w).unwrap();
        commits.push(c.to_vec());
    }
    a2.apply_commit(&commits[1]).unwrap();

    // Three commits at the same epoch, each adding a different joiner. The
    // relay orders a3, then a1's retry, then a2's retry.
    let c1 = a1.invite_with_commit(&j1.key_package().unwrap()).unwrap();
    let c2 = a2.invite_with_commit(&j2.key_package().unwrap()).unwrap();
    let c3 = a3.invite_with_commit(&j3.key_package().unwrap()).unwrap();
    assert!(a1.has_pending() && a2.has_pending() && a3.has_pending());
    a3.merge_pending().unwrap();
    let (w3commit, w3welcome) = split_framed(&c3);
    j3.join(w3welcome).unwrap();
    // Both losers catch up (their pending commits are consumed by the merge).
    a1.apply_commit(w3commit).unwrap();
    a2.apply_commit(w3commit).unwrap();
    assert!(!a1.has_pending() && !a2.has_pending());
    let _ = (c1, c2);
    // a1 retries first: a2, a3, j3 apply it.
    let r1 = a1.invite_with_commit(&j1.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let (r1commit, r1welcome) = split_framed(&r1);
    for d in [&mut a2, &mut a3, &mut j3] { d.apply_commit(r1commit).unwrap(); }
    j1.join(r1welcome).unwrap();
    // a2 retries last.
    let r2 = a2.invite_with_commit(&j2.key_package().unwrap()).unwrap();
    a2.merge_pending().unwrap();
    let (r2commit, r2welcome) = split_framed(&r2);
    for d in [&mut a1, &mut a3, &mut j1, &mut j3] { d.apply_commit(r2commit).unwrap(); }
    j2.join(r2welcome).unwrap();
    for d in [&a1, &a2, &a3, &j1, &j2, &j3] {
        assert_eq!(roster(&d.members().unwrap()).len(), 6, "everyone sees the same 6-member roster");
    }
    let wire = j2.encrypt(&enc(ROOM, "j:2", b"last joiner speaks")).unwrap();
    for d in [&mut a1, &mut a2, &mut a3, &mut j1, &mut j3] {
        assert_eq!(plain(&d.decrypt(&dec(ROOM, &wire)).unwrap()), b"last joiner speaks");
    }
}

#[test]
fn winner_evicts_loser_while_loser_has_own_pending() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let mut j1 = Device::new("j:1").unwrap();
    a1.create().unwrap();
    let mut last = Vec::new();
    for joiner in [&mut a2, &mut a3] {
        let framed = a1.invite_with_commit(&joiner.key_package().unwrap()).unwrap();
        a1.merge_pending().unwrap();
        let (c, w) = split_framed(&framed);
        joiner.join(w).unwrap();
        last = c.to_vec();
    }
    a2.apply_commit(&last).unwrap();
    let key2 = a2.public_key().unwrap();

    // a2 has an add pending; a1's commit that removes a2 wins the order.
    let _lost = a2.invite_with_commit(&j1.key_package().unwrap()).unwrap();
    assert!(a2.has_pending());
    let eviction = a1.remove_member(&key2).unwrap();
    a3.apply_commit(&eviction).unwrap();
    assert_eq!(roster(&a3.members().unwrap()).len(), 2);

    // The evicted loser processes its own removal: the commit is accepted (it
    // is a valid commit from the previous epoch), the own pending commit is
    // gone, and from here on the device is out of the group — encrypting is
    // refused and the device is retired fail-closed, never a silent sender.
    let applied = a2.apply_commit(&eviction);
    assert!(!a2.has_pending(), "own pending commit does not survive an eviction commit");
    let wire = a1.encrypt(&enc(ROOM, "a:1", b"after eviction")).unwrap();
    assert!(a2.decrypt(&dec(ROOM, &wire)).is_err(), "an evicted device cannot read the new epoch");
    assert!(a2.encrypt(&enc(ROOM, "a:2", b"ghost")).is_err(), "an evicted device cannot send");
    assert_eq!(plain(&a3.decrypt(&dec(ROOM, &wire)).unwrap()), b"after eviction");
    let _ = applied;
}

#[test]
fn discard_staged_keeps_the_own_pending_commit() {
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    let mut a4 = Device::new("a:4").unwrap();
    a1.create().unwrap();
    let mut last = Vec::new();
    for joiner in [&mut a2, &mut a3] {
        let framed = a1.invite_with_commit(&joiner.key_package().unwrap()).unwrap();
        a1.merge_pending().unwrap();
        let (c, w) = split_framed(&framed);
        joiner.join(w).unwrap();
        last = c.to_vec();
    }
    a2.apply_commit(&last).unwrap();
    let key3 = a3.public_key().unwrap();

    let own = a1.remove_member_pending(&key3).unwrap(); // bare commit
    let foreign = a2.invite_with_commit(&a4.key_package().unwrap()).unwrap();
    let (fcommit, _) = split_framed(&foreign);
    a1.stage_commit(fcommit).unwrap();
    // Policy said no (e.g. the add is not in the device directory): discard
    // the staged foreign commit. The own pending commit must still be there
    // and still mergeable once the relay accepts it instead.
    a1.discard_staged().unwrap();
    assert!(a1.has_pending(), "discarding a staged foreign commit must not touch the own pending commit");
    a1.merge_pending().unwrap();
    let ocommit = own.as_slice();
    a3.apply_commit(ocommit).unwrap();
    assert_eq!(roster(&a1.members().unwrap()).len(), 2);
    // a2's discarded add never happened for a1: a2 must clear and retry at
    // a1's epoch (relay CAS refuses the stale commit in the real flow).
    a2.clear_pending().unwrap();
    a2.apply_commit(ocommit).unwrap();
    assert_eq!(roster(&a2.members().unwrap()).len(), 2);
}
