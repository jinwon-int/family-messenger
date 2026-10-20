//! #366 3a 호스트 게이트: `MlsRoom` 이 Rust 로 구현한 호스트 콜백(in-memory 릴레이 + 관찰자) 위에서 봇과 같은
//! 동기화·송신 규칙으로 도는지. 릴레이는 와이어 JSON 만 흉내 내는 순서 매기기(MLS 검증 없음, cas 검사만).
//! 이 파일이 깨지면 "봇·Android 가 한 코드" 라는 2단계의 전제가 깨진 것이다.
//! 릴레이·관찰자 대역은 `tests/support/mod.rs`(3c 에서 `lobby_host.rs` 와 공유).
mod support;

use std::sync::atomic::Ordering;

use family_mls_ios_ffi::{MlsRoom, RoomError, RoomEvent, SendResult};
use support::{founded_pair, ok, Harness, Observer, BASE};

#[test]
fn two_rooms_roundtrip_over_the_relay() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);

    let sent = ok(owner.send(b"hello pc".to_vec()), "owner send");
    let SendResult::Sent { client_id, seq, duplicate, .. } = sent else { panic!("expected Sent, got {sent:?}") };
    assert_eq!((seq, duplicate), (2, false));
    assert!(client_id.starts_with("owner-phone-") && client_id.len() == "owner-phone-".len() + 8, "{client_id}");
    assert!(!client_id.contains("-echo-"), "a bot must not mistake app messages for echoes");

    ok(peer.poll(), "peer poll");
    assert_eq!(peer_obs.events(), [RoomEvent::Joined { epoch: 0, seq: 1 }]);
    assert_eq!(peer_obs.texts(), [(2, "owner-phone".to_string(), "hello pc".to_string())]);
    let sync = ok(peer.sync_state(), "peer sync");
    assert_eq!((sync.cursor, sync.joined, sync.acked), (2, true, 2), "persisted after the page: acked == cursor");

    let back = ok(peer.send(b"hello phone".to_vec()), "peer send");
    assert!(matches!(back, SendResult::Sent { seq: 3, .. }), "{back:?}");
    ok(owner.poll(), "owner poll");
    assert_eq!(owner_obs.texts(), [(3, "owner-pc".to_string(), "hello phone".to_string())]);
    assert!(owner_obs.events().iter().any(|e| matches!(e, RoomEvent::OwnEvent { seq: 2, .. })), "{:?}", owner_obs.events());

    // B-H2: every send persists (new sends counter) before the POST.
    let trace = h.trace();
    let persist = trace.iter().position(|l| l == "persist owner-phone cursor=0 sends=2").expect("persist before send");
    let post = trace.iter().position(|l| l.starts_with("POST application owner-phone-")).expect("post");
    assert!(persist < post, "{trace:?}");
    // The next GET acks what the first page persisted (the peer's own send does not move its cursor).
    ok(peer.poll(), "peer poll again");
    assert!(h.trace().iter().any(|l| l == "GET owner-pc after=2 ack=2"), "{:?}", h.trace());
    assert_eq!(ok(peer.sync_state(), "sync").cursor, 3, "its own echo moved the cursor");
}

#[test]
fn own_commit_merges_on_its_echo_and_the_peer_applies_it() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    let (third, third_obs) = h.room("owner-tablet");
    let kp = ok(third.dispatch("key_package".into(), Vec::new()), "third key package");
    let framed = ok(owner.dispatch("invite_with_commit".into(), kp), "invite_with_commit");
    // `u32 LE commit_len ‖ commit ‖ welcome`
    let len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    let (commit, welcome) = (framed[4..4 + len].to_vec(), framed[4 + len..].to_vec());

    let posted = ok(owner.post_commit(commit), "post commit");
    assert_eq!(posted.epoch, 1, "the relay moved its epoch");
    ok(owner.poll(), "owner sees its own commit");
    assert!(owner_obs.events().iter().any(|e| *e == RoomEvent::OwnCommitMerged { seq: posted.seq, epoch: 1 }), "{:?}", owner_obs.events());
    assert_eq!(ok(owner.sync_state(), "sync").epoch, 1);
    ok(owner.post_welcome(welcome, vec!["owner-tablet".into()]), "post welcome");

    ok(third.poll(), "third joins");
    assert!(third_obs.events().iter().any(|e| matches!(e, RoomEvent::Joined { .. })), "{:?}", third_obs.events());
    ok(peer.poll(), "peer applies the foreign commit");
    let applied = peer_obs.events().into_iter().find(|e| matches!(e, RoomEvent::CommitApplied { .. })).expect("commit applied");
    let RoomEvent::CommitApplied { committer, adds, members, outer_checked, .. } = applied else { unreachable!() };
    assert_eq!((committer.as_str(), adds, outer_checked), ("owner-phone", vec!["owner-tablet".to_string()], false));
    assert_eq!(members, ["owner-pc", "owner-phone", "owner-tablet"]);

    ok(owner.send(b"all three".to_vec()), "owner sends at epoch 1");
    ok(peer.poll(), "peer reads");
    ok(third.poll(), "third reads");
    assert_eq!(peer_obs.texts().last().map(|t| t.2.as_str()), Some("all three"));
    assert_eq!(third_obs.texts().last().map(|t| t.2.as_str()), Some("all three"));
}

#[test]
fn conflict_is_queued_and_replayed_after_the_next_poll() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    h.relay.bump_epoch("room-a");

    let queued = ok(owner.send(b"late".to_vec()), "send into a moved room");
    let SendResult::Queued { client_id } = queued else { panic!("expected Queued, got {queued:?}") };
    assert_eq!(owner_obs.events().last(), Some(&RoomEvent::Conflict { client_id: client_id.clone(), attempt: 1 }));
    assert!(h.relay.rows("room-a").iter().all(|r| r.kind != "application"), "nothing stored on 409");

    ok(owner.poll(), "poll refreshes the epoch and replays");
    let replayed = owner_obs.events().into_iter().find(|e| matches!(e, RoomEvent::Replayed { .. })).expect("replayed");
    let RoomEvent::Replayed { client_id: replay_id, epoch, .. } = replayed else { unreachable!() };
    assert_ne!(replay_id, client_id, "a replay reserves a fresh dedup key");
    assert_eq!(epoch, 1);
    ok(peer.poll(), "peer reads the replayed message");
    assert_eq!(peer_obs.texts().last().map(|t| t.2.as_str()), Some("late"));
}

#[test]
fn import_resumes_from_the_last_persisted_state() {
    let h = Harness::new();
    let ((owner, _), (peer, peer_obs)) = founded_pair(&h);
    ok(owner.send(b"one".to_vec()), "one");
    ok(peer.poll(), "peer reads one");
    let (state, sync) = peer_obs.last_persisted();
    assert_eq!((sync.cursor, sync.joined, sync.sends), (2, true, 0));
    drop(peer);

    let again_obs = Observer::new("owner-pc-again", h.trace.clone());
    let again = ok(
        MlsRoom::import("owner-pc".into(), "room-a".into(), state, sync, BASE.into(), h.relay.clone(), again_obs.clone()),
        "import",
    );
    ok(owner.send(b"two".to_vec()), "two");
    ok(again.poll(), "resumed poll");
    assert_eq!(again_obs.texts(), [(3, "owner-phone".to_string(), "two".to_string())], "only what came after the cursor");
    let sent = ok(again.send(b"back".to_vec()), "resumed send");
    assert!(matches!(sent, SendResult::Sent { .. }), "the restored ratchet still encrypts: {sent:?}");

    let wrong_room = again_obs.last_persisted();
    let err = MlsRoom::import("owner-pc".into(), "room-b".into(), wrong_room.0, wrong_room.1, BASE.into(), h.relay.clone(), again_obs.clone())
        .err()
        .expect("state bound to its room");
    assert!(matches!(err, RoomError::Host { .. }), "{err}");
}

#[test]
fn transport_failure_is_a_transient_relay_error() {
    let h = Harness::new();
    let ((owner, _), _) = founded_pair(&h);
    h.relay.down.store(true, Ordering::SeqCst);
    let err = owner.poll().err().expect("relay down");
    assert!(matches!(err, RoomError::Relay { transient: true, .. }), "{err}");
    let err = owner.send(b"x".to_vec()).err().expect("relay down on send");
    assert!(matches!(err, RoomError::Relay { transient: true, .. }), "{err}");
    h.relay.down.store(false, Ordering::SeqCst);
    ok(owner.poll(), "back");
}

#[test]
fn pruned_history_halts_the_room_before_anything_moves() {
    let h = Harness::new();
    let ((owner, _), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins at seq 1");
    for text in ["a", "b", "c"] {
        ok(owner.send(text.as_bytes().to_vec()), text);
    }
    h.relay.prune_before("room-a", 4); // seqs 2..3 are gone for a reader at cursor 1
    ok(peer.poll(), "a gap is reported, not an error");
    let halts = peer_obs.halts.lock().unwrap().clone();
    assert_eq!(halts.len(), 1);
    assert_eq!(halts[0].0, "history_gap");
    assert!(halts[0].1.contains("missing 2..3"), "{}", halts[0].1);
    assert!(halts[0].2.halted);
    assert_eq!(ok(peer.sync_state(), "sync").cursor, 1, "nothing of the page moved");
    assert!(peer_obs.texts().is_empty());
    ok(peer.poll(), "halted room does nothing");
    assert_eq!(h.trace().iter().filter(|l| l.starts_with("GET owner-pc")).count(), 3, "no fetch while halted: {:?}", h.trace());
}
