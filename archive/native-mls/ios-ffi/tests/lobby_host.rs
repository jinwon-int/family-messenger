//! #366 3c 호스트 게이트: 기기 수준 객체 `MlsLobby`(로비 key package · 방 목록 · 푸시 등록)와 `MlsRoom::adopt`/`close_room` 이
//! in-memory 릴레이(`tests/support`) 위에서 iOS `LobbyKeyring`·릴레이 lobby.go 와 같은 규칙으로 도는지.
mod support;

use family_mls_ios_ffi::{MlsLobbySlot, MlsLobby, MlsRoom, RoomError, RoomEvent, SendResult};
use support::{founded_pair, ok, Harness, LobbyStore, Observer, BASE, LOBBY_MAX_DEFAULT};

#[test]
fn replenish_publishes_up_to_the_target_and_prunes_what_the_relay_consumed() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    assert_eq!(store.count(), 1, "the seed is persisted before anything else");
    assert!(store.last().published.is_empty());

    let report = ok(lobby.replenish(3), "first replenish");
    assert_eq!((report.minted, report.pruned, report.live, report.max), (3, 0, 3, LOBBY_MAX_DEFAULT as u32));
    assert_eq!(h.relay.lobby_live("owner-phone"), 3);
    assert_eq!(store.last().published.len(), 3, "the ledger follows the relay");
    // persist-before-bytes-leave: the fresh secrets hit the store before the POST.
    let trace = h.trace();
    let persist = trace.iter().position(|l| l == "persist lobby owner-phone published=0").expect("persist before post");
    let post = trace.iter().position(|l| l.starts_with("POST lobby owner-phone n=3")).expect("post");
    assert!(persist < post, "{trace:?}");

    // Nothing to do when the relay already holds the target.
    let again = ok(lobby.replenish(3), "steady state");
    assert_eq!((again.minted, again.pruned), (0, 0));
    assert_eq!(h.trace().iter().filter(|l| l.starts_with("POST lobby")).count(), 1, "no empty POST");

    // A steward consumes the oldest one → the ledger head is pruned and one is minted.
    let consumed = h.relay.consume_lobby("owner-phone", "bot-steward", "room-b").expect("one live package");
    assert_eq!(consumed, store.last().published[0], "the relay hands out the oldest first");
    let topped = ok(lobby.replenish(3), "after a consume");
    assert_eq!((topped.minted, topped.pruned, topped.live), (1, 1, 3));
    assert_eq!(store.last().published.len(), 3);
    assert!(!store.last().published.contains(&consumed), "the consumed package left the ledger");
    assert_eq!(ok(lobby.published_count(), "count"), 3);
}

#[test]
fn replenish_is_bounded_by_the_relay_max_and_the_facade_limit() {
    let h = Harness::new();
    let (lobby, _) = h.lobby("owner-phone");
    // Relay max wins over the caller's target.
    let report = ok(lobby.replenish(50), "target above the relay max");
    assert_eq!((report.minted, report.live), (LOBBY_MAX_DEFAULT as u32, LOBBY_MAX_DEFAULT as u32));
    // The facade keeps at most 8 unconsumed key packages: a laxer relay cannot make the device mint more.
    h.relay.set_lobby_max(12);
    let more = ok(lobby.replenish(12), "relay allows 12");
    assert_eq!(more.minted, 0, "facade limit reached — not an error ({more:?})");
    assert_eq!(h.relay.lobby_live("owner-phone"), 8);
}

#[test]
fn a_failed_publish_discards_the_fresh_secrets() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    ok(lobby.replenish(2), "publish 2");
    // The status says there is room, but the POST is refused (another publisher raced us): 409 key_package_limit.
    h.relay.refuse_lobby_post.store(true, std::sync::atomic::Ordering::SeqCst);
    let err = lobby.replenish(4).err().expect("relay refuses the publish");
    assert!(matches!(err, RoomError::Relay { transient: false, .. }) && err.to_string().contains("key_package_limit"), "{err}");
    assert_eq!(store.last().published.len(), 2, "the ledger did not grow");
    assert_eq!(h.relay.lobby_live("owner-phone"), 2);
    // The two refused secrets were deleted locally: 2 live + 6 fresh reaches the facade limit of 8 exactly.
    h.relay.refuse_lobby_post.store(false, std::sync::atomic::Ordering::SeqCst);
    h.relay.set_lobby_max(10);
    let report = ok(lobby.replenish(10), "after the failure");
    assert_eq!((report.minted, report.live), (6, 8), "{report:?}");
}

#[test]
fn a_welcome_made_from_a_lobby_package_is_adopted_into_a_new_room() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    ok(lobby.replenish(2), "publish");
    assert!(ok(lobby.welcomes(), "welcomes").is_empty());

    // A steward founds room-b and invites the phone with its lobby package (bot `invite` lobby fallback).
    let (steward, _) = h.room_in("bot-steward", "room-b");
    ok(steward.dispatch("create".into(), Vec::new()), "create room-b");
    let kp = h.relay.consume_lobby("owner-phone", "bot-steward", "room-b").expect("lobby package");
    let welcome = ok(steward.dispatch("invite".into(), kp), "invite via lobby package");
    let posted = ok(steward.post_welcome(welcome, vec!["owner-phone".into()]), "post welcome");

    let pending = ok(lobby.welcomes(), "welcomes");
    assert_eq!(pending.len(), 1);
    assert_eq!((pending[0].room.as_str(), pending[0].seq), ("room-b", posted.seq));

    // Adopt: the room starts from the lobby state (which holds the consumed package's secret) just before the Welcome.
    let phone_obs = Observer::new("owner-phone", h.trace.clone());
    let before = h.trace().len();
    let phone = ok(
        MlsRoom::adopt("owner-phone".into(), "room-b".into(), ok(lobby.seed_state(), "seed"), posted.seq - 1, BASE.into(), h.relay.clone(), phone_obs.clone()),
        "adopt",
    );
    let after_adopt: Vec<String> = h.trace()[before..].to_vec();
    assert_eq!(after_adopt, ["persist owner-phone cursor=0 sends=0"], "adopt persists the pair before any network");
    let sync = ok(phone.sync_state(), "sync");
    assert_eq!((sync.cursor, sync.acked, sync.joined), (posted.seq - 1, posted.seq - 1, false));

    ok(phone.poll(), "join from the Welcome");
    assert!(phone_obs.events().iter().any(|e| matches!(e, RoomEvent::Joined { .. })), "{:?}", phone_obs.events());
    ok(steward.send(b"welcome aboard".to_vec()), "steward sends");
    ok(phone.poll(), "phone reads");
    assert_eq!(phone_obs.texts().last().map(|t| t.2.as_str()), Some("welcome aboard"));
    let back = ok(phone.send(b"thanks".to_vec()), "phone sends");
    assert!(matches!(back, SendResult::Sent { .. }), "the adopted ratchet encrypts: {back:?}");

    // Reading past the Welcome (ack) clears the pending listing; the room shows up as a membership.
    ok(phone.poll(), "ack the page");
    assert!(ok(lobby.welcomes(), "welcomes after ack").is_empty(), "{:?}", h.trace());
    let rooms = ok(lobby.rooms(), "rooms");
    assert_eq!(rooms.len(), 1);
    assert_eq!((rooms[0].room.as_str(), rooms[0].member, rooms[0].closed), ("room-b", true, false));

    // The lobby itself still holds the other package's secret; the next replenish prunes the consumed one.
    let report = ok(lobby.replenish(2), "replenish after the join");
    assert_eq!((report.pruned, report.minted), (1, 1));
    assert_eq!(store.last().published.len(), 2);

    // The same signing key everywhere: rooms founded from the seed share the lobby's public key.
    let founded = ok(
        MlsRoom::adopt("owner-phone".into(), "room-c".into(), ok(lobby.seed_state(), "seed"), 0, BASE.into(), h.relay.clone(), Observer::new("owner-phone", h.trace.clone())),
        "found from seed",
    );
    ok(founded.dispatch("create".into(), Vec::new()), "create room-c from the seed");
    let err = MlsRoom::adopt("owner-phone".into(), "room-d".into(), Vec::new(), -1, BASE.into(), h.relay.clone(), Observer::new("owner-phone", h.trace.clone()))
        .err()
        .expect("negative cursor");
    assert!(matches!(err, RoomError::Host { .. }), "{err}");
}

#[test]
fn import_restores_the_ledger_and_the_secrets() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    ok(lobby.replenish(3), "publish");
    let slot: MlsLobbySlot = store.last();
    drop(lobby);

    let again_store = LobbyStore::new("owner-phone-again", h.trace.clone());
    let again = ok(MlsLobby::import("owner-phone".into(), slot, BASE.into(), h.relay.clone(), again_store.clone()), "import");
    assert_eq!(ok(again.published_count(), "count"), 3);
    h.relay.consume_lobby("owner-phone", "bot-steward", "room-b");
    h.relay.consume_lobby("owner-phone", "bot-steward", "room-c");
    let report = ok(again.replenish(3), "replenish after import");
    assert_eq!((report.pruned, report.minted, report.live), (2, 2, 3), "the restored device still knows the old secrets");
    assert_eq!(again_store.last().published.len(), 3);
}

#[test]
fn withdraw_empties_the_relay_pool_and_frees_the_local_limit() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    ok(lobby.replenish(8), "fill");
    assert_eq!(ok(lobby.withdraw(), "withdraw"), 8);
    assert_eq!(h.relay.lobby_live("owner-phone"), 0);
    assert!(store.last().published.is_empty());
    assert_eq!(ok(lobby.status(), "status").live, 0);
    // All 8 secrets were deleted locally — otherwise the facade limit would refuse any new package.
    let report = ok(lobby.replenish(8), "refill");
    assert_eq!(report.minted, 8, "{report:?}");
}

#[test]
fn close_room_tombstones_the_relay_room() {
    let h = Harness::new();
    let ((owner, _), (peer, _)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    assert!(ok(owner.close_room(), "close"), "closed");
    assert!(ok(owner.close_room(), "close again"), "idempotent on the relay");
    let err = peer.poll().err().expect("a closed room is gone for every member");
    assert!(matches!(err, RoomError::Relay { transient: false, .. }) && err.to_string().contains("room_closed"), "{err}");
    let err = owner.send(b"x".to_vec()).err().expect("no sends into a closed room");
    assert!(err.to_string().contains("room_closed"), "{err}");

    let (never_posted, _) = h.room_in("owner-phone", "room-z");
    assert!(!ok(never_posted.close_room(), "close an unknown room"), "no_such_room is false, not an error");
    let (stranger, _) = h.room_in("stranger-pc", "room-a");
    let err = stranger.close_room().err().expect("not a member");
    assert!(err.to_string().contains("not_a_member"), "{err}");
}

#[test]
fn push_registration_round_trips_the_wire() {
    let h = Harness::new();
    let (lobby, _) = h.lobby("owner-phone");
    let token = vec![0xAB; 32];
    ok(lobby.register_push(token.clone(), "com.seoyoon_family.familychat".into()), "register");
    let rows = h.relay.push_rows();
    assert_eq!(rows.len(), 1);
    assert_eq!((rows[0].device.as_str(), rows[0].token.as_slice(), rows[0].topic.as_str()), ("owner-phone", token.as_slice(), "com.seoyoon_family.familychat"));
    ok(lobby.register_push(token.clone(), "com.seoyoon_family.familychat".into()), "register again");
    assert_eq!(h.relay.push_rows().len(), 1, "idempotent");
    let err = lobby.register_push(Vec::new(), "com.seoyoon_family.familychat".into()).err().expect("empty token refused");
    assert!(err.to_string().contains("bad_apns_token"), "{err}");
    ok(lobby.unregister_push(), "unregister");
    assert!(h.relay.push_rows().is_empty());
}
