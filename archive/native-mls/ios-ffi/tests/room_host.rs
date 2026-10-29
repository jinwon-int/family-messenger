//! #366 3a 호스트 게이트: `MlsRoom` 이 Rust 로 구현한 호스트 콜백(in-memory 릴레이 + 관찰자) 위에서 봇과 같은
//! 동기화·송신 규칙으로 도는지. 릴레이는 와이어 JSON 만 흉내 내는 순서 매기기(MLS 검증 없음, cas 검사만).
//! 이 파일이 깨지면 "봇·Android 가 한 코드" 라는 2단계의 전제가 깨진 것이다.
//! 릴레이·관찰자 대역은 `tests/support/mod.rs`(3c 에서 `lobby_host.rs` 와 공유).
mod support;

use std::sync::atomic::Ordering;

use family_mls_ios_ffi::{MlsInvite, MlsRoom, RoomError, RoomEvent, SendResult};
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

/// #571 B: the read position is per actor — `owner-phone` and `owner-pc` are one person. `poll` carries the relay's
/// value on the page; `mark_read` posts the strict body, stores the answered max and never posts below what it knows.
#[test]
fn read_position_is_shared_across_an_actor_and_posted_on_mark_read() {
    let h = Harness::new();
    let ((owner, _), (peer, _)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    ok(owner.send(b"one".to_vec()), "one"); // seq 2
    ok(owner.send(b"two".to_vec()), "two"); // seq 3
    ok(peer.poll(), "peer reads both");
    assert_eq!(ok(peer.read_seq(), "nothing read"), 0);

    // Another device of the same person (the web) read up to 2: the next page carries it.
    h.relay.rooms.lock().unwrap().get_mut("room-a").expect("room").reads.insert("owner".into(), 2);
    ok(peer.poll(), "peer polls");
    assert_eq!(ok(peer.read_seq(), "from the page"), 2, "GET /events read_seq is merged");

    assert_eq!(ok(peer.mark_read(3), "pc read it all"), 3);
    assert_eq!(h.relay.read_seq("room-a", "owner"), 3, "stored per actor");
    assert!(h.trace().iter().any(|l| l == "READ owner-pc seq=3"), "{:?}", h.trace());

    // The phone has not polled since: it posts a lower value and learns the actor max from the answer.
    assert_eq!(ok(owner.read_seq(), "phone before"), 0);
    assert_eq!(ok(owner.mark_read(1), "phone marks 1"), 3, "the relay answers max(current, posted)");
    assert_eq!(ok(owner.read_seq(), "phone after"), 3);
    assert_eq!(h.relay.read_seq("room-a", "owner"), 3, "monotonic on the relay");

    // Nothing at or below the known position is posted.
    let posted = |h: &Harness| h.trace().iter().filter(|l| l.starts_with("READ ")).count();
    let before = posted(&h);
    assert_eq!(ok(peer.mark_read(2), "older"), 3);
    assert_eq!(ok(peer.mark_read(3), "same"), 3);
    assert_eq!(posted(&h), before, "no POST below or at the known read_seq: {:?}", h.trace());

    // Local guard and relay refusals: the host sees an error it may log and ignore; nothing local moves.
    assert!(matches!(peer.mark_read(-1).err().expect("negative"), RoomError::Host { .. }));
    let err = peer.mark_read(99).err().expect("past last_seq");
    assert!(matches!(&err, RoomError::Relay { transient: false, .. }) && err.to_string().contains("bad_seq"), "{err}");
    let (guest, _) = h.room_in("guest-pc", "room-a");
    let err = guest.mark_read(1).err().expect("not a member");
    assert!(matches!(&err, RoomError::Relay { transient: false, .. }) && err.to_string().contains("not_a_member"), "{err}");
    assert_eq!(ok(peer.read_seq(), "unchanged"), 3);
    assert_eq!(ok(peer.sync_state(), "sync").acked, 3, "read position never touches the MLS cursor/ack");
}

/// A relay from before #571 B answers a bare 404 on `/read` and omits `read_seq`; a room the relay does not know yet is
/// 404 `no_such_room`. Both are ignored (the position stays local), a closed room is the usual `Relay` error.
#[test]
fn mark_read_is_ignored_on_a_relay_without_the_route_or_the_room() {
    let h = Harness::new();
    let ((owner, _), (peer, _)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    ok(owner.send(b"one".to_vec()), "one");
    h.relay.no_read_route.store(true, Ordering::SeqCst);
    ok(peer.poll(), "old relay page parses");
    assert_eq!(ok(peer.read_seq(), "absent field"), 0);
    assert_eq!(ok(peer.mark_read(2), "old relay"), 0, "bare 404 is a no-op, not an error");
    assert_eq!(h.relay.read_seq("room-a", "owner"), 0);
    h.relay.no_read_route.store(false, Ordering::SeqCst);

    let (local_only, _) = h.room_in("owner-watch", "room-z");
    assert_eq!(ok(local_only.mark_read(1), "room not on the relay"), 0, "404 no_such_room is a no-op");
    assert!(h.trace().iter().any(|l| l == "READ owner-watch seq=1"), "it was posted: {:?}", h.trace());

    assert!(ok(owner.close_room(), "close"));
    let err = peer.mark_read(2).err().expect("closed room");
    assert!(matches!(&err, RoomError::Relay { transient: false, .. }) && err.to_string().contains("room_closed"), "{err}");
    h.relay.down.store(true, Ordering::SeqCst);
    let err = peer.mark_read(2).err().expect("relay down");
    assert!(matches!(err, RoomError::Relay { transient: true, .. }), "{err}");
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

/// #574 형제 기기 초대: `invite(target)` 이 대상의 로비 키를 소비해 commit 을 올리고, 자기 echo 를 merge 한 뒤 Welcome 을 대상에게만
/// 올린다(봇 `invite` 와 같은 순서). 대상은 `welcomes()`(`from` = 초대한 기기)로 발견해 `adopt` → join; 다른 멤버는 commit 을 적용한다.
#[test]
fn invite_consumes_the_lobby_package_and_posts_the_welcome_after_the_echo() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    let (tablet, _) = h.lobby("owner-tablet");

    // 아직 로비 키가 없다(새 기기는 활성이 된 뒤 첫 틱에야 올린다) — 다음 틱에 다시.
    assert_eq!(ok(owner.invite("owner-tablet".into()), "invite without a key package"), MlsInvite::NoKeyPackage);
    assert!(h.trace().iter().any(|l| l == "CONSUME room owner-tablet by owner-phone for room-a"), "room pool first: {:?}", h.trace());
    ok(tablet.replenish(1), "tablet publishes a lobby key");

    let invited = ok(owner.invite("owner-tablet".into()), "invite");
    let MlsInvite::Invited { commit_seq, welcome_seq, epoch } = invited else { panic!("{invited:?}") };
    assert_eq!((commit_seq, welcome_seq, epoch), (2, 3, 1));
    assert!(h.trace().iter().any(|l| l == "CONSUME lobby owner-tablet by owner-phone for room-a"), "{:?}", h.trace());
    assert!(owner_obs.events().iter().any(|e| matches!(e, RoomEvent::OwnCommitMerged { seq: 2, epoch: 1 })), "{:?}", owner_obs.events());
    // persist-before-bytes-leave: the pending-commit state hit the store before the commit POST.
    let trace = h.trace();
    let persist = trace.iter().position(|l| l == "persist owner-phone cursor=0 sends=2").expect("persist before the commit post");
    let post = trace.iter().position(|l| l.starts_with("POST commit owner-phone-")).expect("commit post");
    assert!(persist < post, "{trace:?}");
    let rows = h.relay.rows("room-a");
    assert_eq!((rows[2].kind.as_str(), rows[2].targets.as_slice()), ("welcome", &["owner-tablet".to_string()][..]));

    // 대상: welcomes 에 `from` = 초대한 기기 → adopt → join.
    let pending = ok(tablet.welcomes(), "welcomes");
    assert_eq!(pending.len(), 1);
    assert_eq!((pending[0].room.as_str(), pending[0].seq, pending[0].from.as_str()), ("room-a", 3, "owner-phone"));
    let tablet_obs = Observer::new("owner-tablet", h.trace.clone());
    let tablet_room = ok(
        MlsRoom::adopt("owner-tablet".into(), "room-a".into(), ok(tablet.seed_state(), "seed"), 2, BASE.into(), h.relay.clone(), tablet_obs.clone()),
        "adopt",
    );
    ok(tablet_room.poll(), "tablet joins");
    assert!(tablet_obs.events().iter().any(|e| matches!(e, RoomEvent::Joined { .. })), "{:?}", tablet_obs.events());
    // 다른 멤버는 commit 을 적용하고, 셋이 같은 방에서 읽는다.
    ok(peer.poll(), "peer applies the add");
    assert!(peer_obs.events().iter().any(|e| matches!(e, RoomEvent::CommitApplied { adds, .. } if adds == &["owner-tablet".to_string()])), "{:?}", peer_obs.events());
    ok(tablet_room.send(b"hi all".to_vec()), "tablet sends");
    ok(owner.poll(), "owner reads");
    ok(peer.poll(), "peer reads");
    assert_eq!(owner_obs.texts().last().map(|t| t.2.as_str()), Some("hi all"));
    assert_eq!(peer_obs.texts().last().map(|t| t.2.as_str()), Some("hi all"));

    // 방이 먼저 움직였으면(409 cas_mismatch) 대기 commit 을 버리고 `Raced` — 다음 poll 뒤 다시 하면 된다.
    let (watch, _) = h.lobby("owner-watch");
    ok(watch.replenish(1), "watch publishes");
    h.relay.bump_epoch("room-a");
    assert_eq!(ok(owner.invite("owner-watch".into()), "invite into a moved room"), MlsInvite::Raced);
    ok(owner.poll(), "catch up");
    ok(watch.replenish(1), "watch publishes again (the raced consume used one)");
    assert!(matches!(ok(owner.invite("owner-watch".into()), "invite again"), MlsInvite::Invited { .. }));

    // 참여 전인 방에서는 초대할 수 없다.
    let (stranger, _) = h.room_in("stranger-pc", "room-a");
    let err = stranger.invite("owner-tablet".into()).expect_err("not joined");
    assert!(matches!(err, RoomError::Host { .. }), "{err}");
    let err = owner.invite("bad target".into()).expect_err("identifier rule");
    assert!(matches!(err, RoomError::Host { .. }), "{err}");
}
