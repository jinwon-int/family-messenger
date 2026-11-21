//! #366 3c 호스트 게이트: 기기 수준 객체 `MlsLobby`(로비 key package · 방 목록 · 푸시 등록)와 `MlsRoom::adopt`/`close_room` 이
//! in-memory 릴레이(`tests/support`) 위에서 iOS `LobbyKeyring`·릴레이 lobby.go 와 같은 규칙으로 도는지.
mod support;

use std::sync::atomic::Ordering;
use std::time::Duration;

use family_mls_ios_ffi::{
    MlsCandidate, MlsCandidateList, MlsCandidatePost, MlsLobbySlot, MlsLobby, MlsMe, MlsPolicyCommit, MlsRefusal, MlsRoom, RoomError,
    RoomEvent, SendResult,
};
use support::{founded_pair, ok, Harness, LobbyStore, Observer, BASE, CANDIDATE_TTL_SECONDS, LOBBY_MAX_DEFAULT, SUBJECT};

#[test]
fn replenish_publishes_up_to_the_target_and_prunes_what_nobody_claims_after_the_hold() {
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

    // A steward consumes the oldest one → one is minted, but the consumed secret stays at the ledger head: its Welcome may
    // still be on the way (#616).
    let consumed = h.relay.consume_lobby("owner-phone", "bot-steward", "room-b").expect("one live package");
    assert_eq!(consumed, store.last().published[0], "the relay hands out the oldest first");
    let topped = ok(lobby.replenish(3), "after a consume");
    assert_eq!((topped.minted, topped.pruned, topped.kept, topped.live), (1, 0, 1, 3));
    assert_eq!(store.last().published.len(), 4);
    assert_eq!(store.last().published[0], consumed, "kept in place, oldest first");
    let held = ok(lobby.replenish(3), "still within the hold");
    assert_eq!((held.minted, held.pruned, held.kept), (0, 0, 1));

    // No Welcome ever names it: once the hold has passed it is an orphan and the next replenish prunes it.
    ok(lobby.set_consumed_hold(Duration::ZERO), "hold");
    let swept = ok(lobby.replenish(3), "after the hold");
    assert_eq!((swept.minted, swept.pruned, swept.kept, swept.live), (0, 1, 0, 3));
    assert_eq!(store.last().published.len(), 3);
    assert!(!store.last().published.contains(&consumed), "the consumed package left the ledger");
    assert_eq!(ok(lobby.published_count(), "count"), 3);
}

/// The hold is bounded by the facade limit, not by time alone: kept secrets count against the 8, and minting resumes as
/// they are released.
#[test]
fn kept_secrets_count_against_the_facade_limit_until_they_are_released() {
    let h = Harness::new();
    let (lobby, _) = h.lobby("owner-phone");
    ok(lobby.replenish(8), "publish 8");
    for room in ["room-b", "room-c", "room-d"] {
        h.relay.consume_lobby("owner-phone", "bot-steward", room).expect("live package");
    }
    let full = ok(lobby.replenish(8), "three consumed, none claimed yet");
    assert_eq!((full.kept, full.pruned, full.minted, full.live), (3, 0, 0, 5), "8 secrets are outstanding — nothing can be minted ({full:?})");
    ok(lobby.set_consumed_hold(Duration::ZERO), "hold");
    let freed = ok(lobby.replenish(8), "after the hold");
    assert_eq!((freed.kept, freed.pruned, freed.minted, freed.live), (0, 3, 3, 8), "{freed:?}");
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

/// 로비 키로 `room` 을 만들어 `phone` 을 초대하는 steward 한 번(봇 `invite` 로비 폴백). 소비한 뒤 `between` 을 부르고 Welcome 을 올린다 —
/// 실제 릴레이에서도 소비(`GET /v2/lobby/keypackages`)와 Welcome 게시 사이에는 틈이 있다.
fn steward_invites(h: &Harness, steward: &str, room: &str, phone: &str, between: impl FnOnce()) -> i64 {
    let (bot, _) = h.room_in(steward, room);
    ok(bot.dispatch("create".into(), Vec::new()), "create");
    let kp = h.relay.consume_lobby(phone, steward, room).expect("lobby package");
    between();
    let welcome = ok(bot.dispatch("invite".into(), kp), "invite via lobby package");
    ok(bot.post_welcome(welcome, vec![phone.into()]), "post welcome").seq
}

/// 로비 Welcome 하나를 받아들인다(`adopt(seq - 1)` → `poll`). 참여했는지를 돌려준다.
fn adopt_and_poll(h: &Harness, lobby: &MlsLobby, phone: &str, room: &str, seq: i64) -> (std::sync::Arc<MlsRoom>, bool) {
    let obs = Observer::new(phone, h.trace.clone());
    let adopted = ok(MlsRoom::adopt(phone.into(), room.into(), ok(lobby.seed_state(), "seed"), seq - 1, BASE.into(), h.relay.clone(), obs.clone()), "adopt");
    ok(adopted.poll(), "poll");
    let joined = obs.events().iter().any(|e| matches!(e, RoomEvent::Joined { .. }));
    (adopted, joined)
}

/// #616: 보충이 「릴레이가 소비했다」는 것만 보고 비밀을 지우면, 그 키로 만든 Welcome 이 아직 올라오지 않았거나(소비와 게시 사이의 틈)
/// 아직 받아들이지 않은 경우 그 Welcome 은 영영 열 수 없다. 실기기에서는 대체 키 발급이 Welcome 게시보다 1초 빨랐다.
#[test]
fn replenish_keeps_the_secret_of_a_consumed_package_until_its_welcome_is_joined() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    ok(lobby.replenish(2), "publish");

    // 틈 ①: 소비됐지만 Welcome 은 아직 없다 — 이때 도는 보충(주기 틱).
    let seq = steward_invites(&h, "bot-steward", "room-b", "owner-phone", || {
        let report = ok(lobby.replenish(2), "replenish between the consume and the Welcome");
        assert_eq!((report.pruned, report.kept, report.minted, report.live), (0, 1, 1, 2), "{report:?}");
    });
    assert_eq!(store.last().published.len(), 3, "the consumed package stays at the head of the ledger");

    // 틈 ②: Welcome 이 올라왔지만 아직 받아들이지 않았다 — 또 한 번의 보충.
    let pending = ok(lobby.welcomes(), "welcomes");
    assert_eq!((pending.len(), pending[0].seq), (1, seq));
    assert!(!pending[0].key_package_ref.is_empty(), "the relay names the lobby package the Welcome used");
    let report = ok(lobby.replenish(2), "replenish while the Welcome waits");
    assert_eq!((report.pruned, report.kept, report.minted), (0, 1, 0), "{report:?}");

    let (phone, joined) = adopt_and_poll(&h, &lobby, "owner-phone", "room-b", seq);
    assert!(joined, "the Welcome still opens: its key package secret was kept ({:?})", h.trace());

    // 읽고 지나가면(ack) 그 비밀은 더 필요 없다 — 다음 보충이 바로 지운다.
    ok(phone.poll(), "ack the page");
    assert!(ok(lobby.welcomes(), "welcomes after ack").is_empty());
    let report = ok(lobby.replenish(2), "replenish after the join");
    assert_eq!((report.pruned, report.kept, report.minted), (1, 0, 0), "{report:?}");
    assert_eq!(store.last().published.len(), 2);
}

/// #616: 기기가 꺼져 있는 동안 초대가 여러 개 쌓였을 때 — 하나를 받아들인 뒤의 보충이 나머지 Welcome 의 비밀을 지우면 안 된다.
#[test]
fn several_waiting_welcomes_are_all_joined_with_a_replenish_after_each() {
    let h = Harness::new();
    let (lobby, _) = h.lobby("owner-phone");
    ok(lobby.replenish(3), "publish");
    let seq_b = steward_invites(&h, "bot-b", "room-b", "owner-phone", || {});
    let seq_c = steward_invites(&h, "bot-c", "room-c", "owner-phone", || {});
    let seq_d = steward_invites(&h, "bot-d", "room-d", "owner-phone", || {});

    // 호스트의 한 바퀴(`DeviceHub.lobbyAux`): 목록 → 방마다 받아들이기 → 참여 뒤 보충.
    let pending = ok(lobby.welcomes(), "welcomes");
    assert_eq!(pending.iter().map(|w| (w.room.as_str(), w.seq)).collect::<Vec<_>>(), [("room-b", seq_b), ("room-c", seq_c), ("room-d", seq_d)]);
    for w in &pending {
        let (_, joined) = adopt_and_poll(&h, &lobby, "owner-phone", &w.room, w.seq);
        assert!(joined, "{} joined ({:?})", w.room, h.trace());
        ok(lobby.replenish(3), "replenish after a join");
    }
}

/// #616: 무엇이 기다리는지 모르면 지우지 않는다 — Welcome 목록을 읽지 못한 보충은 실패하고(다음 틱이 다시 한다), 목록 라우트가
/// 없는 옛 릴레이에서는 보류 시간만으로 지킨다.
#[test]
fn replenish_does_not_prune_blind_when_the_welcome_listing_is_unavailable() {
    let h = Harness::new();
    let (lobby, store) = h.lobby("owner-phone");
    ok(lobby.replenish(2), "publish");
    let seq = steward_invites(&h, "bot-steward", "room-b", "owner-phone", || {});
    ok(lobby.set_consumed_hold(Duration::ZERO), "no time-based hold: only the listing protects the secret");

    h.relay.fail_lobby_welcomes.store(true, Ordering::SeqCst);
    let err = lobby.replenish(2).err().expect("the listing failed");
    assert!(matches!(err, RoomError::Relay { .. }), "{err}");
    assert_eq!(store.last().published.len(), 2, "nothing pruned, nothing minted");
    h.relay.fail_lobby_welcomes.store(false, Ordering::SeqCst);

    let report = ok(lobby.replenish(2), "listing is back");
    assert_eq!((report.pruned, report.kept, report.minted), (0, 1, 1), "the waiting Welcome protects its package ({report:?})");
    let (_, joined) = adopt_and_poll(&h, &lobby, "owner-phone", "room-b", seq);
    assert!(joined, "{:?}", h.trace());

    // 옛 릴레이: 목록이 없으면 보류 시간이 유일한 보호다.
    let (old, old_store) = h.lobby("owner-tablet");
    ok(old.replenish(2), "publish");
    h.relay.no_lobby_welcomes.store(true, Ordering::SeqCst);
    h.relay.consume_lobby("owner-tablet", "bot-steward", "room-c").expect("live package");
    let report = ok(old.replenish(2), "old relay, within the hold");
    assert_eq!((report.pruned, report.kept, report.minted), (0, 1, 1), "{report:?}");
    ok(old.set_consumed_hold(Duration::ZERO), "hold");
    let report = ok(old.replenish(2), "old relay, after the hold");
    assert_eq!((report.pruned, report.kept), (1, 0), "{report:?}");
    assert_eq!(old_store.last().published.len(), 2);
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
    // 복원 직후에도 소비분은 일단 남긴다(기억은 메모리에만 — 재시작하면 보류 시계가 다시 돈다).
    let report = ok(again.replenish(3), "replenish after import");
    assert_eq!((report.pruned, report.kept, report.minted, report.live), (0, 2, 2, 3));
    assert_eq!(again_store.last().published.len(), 5);
    ok(again.set_consumed_hold(Duration::ZERO), "hold");
    let report = ok(again.replenish(3), "replenish after the hold");
    assert_eq!((report.pruned, report.kept, report.minted, report.live), (2, 0, 0, 3), "the restored device still knows the old secrets");
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

// ---- #574 기기 셀프서비스: `/v2/me` · 후보 게시 · 승인(E2) · 역할(E5) · 로비 dispatch ----

fn fingerprint_of(lobby: &MlsLobby) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(ok(lobby.public_key(), "pk")).iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn me_reports_the_subject_revision_and_my_devices_and_tolerates_an_old_relay() {
    let h = Harness::new();
    let (phone, _) = h.lobby("owner-phone");
    h.relay.enroll("owner-phone", &fingerprint_of(&phone), &["registrar"]);
    h.relay.enroll("owner-pc", "cd", &[]);
    let me = ok(phone.me(), "me");
    assert_eq!((me.subject.as_str(), me.policy_revision), (SUBJECT, Some(3)));
    assert_eq!(me.devices.len(), 2);
    assert_eq!((me.devices[0].device_id.as_str(), me.devices[0].status.as_str(), me.devices[0].roles.as_slice()), ("owner-phone", "active", &["registrar".to_string()][..]));
    assert_eq!((me.devices[1].device_id.as_str(), me.devices[1].roles.len()), ("owner-pc", 0));
    assert_eq!(me.devices[0].fingerprint, fingerprint_of(&phone));
    // #574 이전 릴레이: `{subject}` 만 — revision 없음, 기기 없음.
    h.relay.no_self_service.store(true, std::sync::atomic::Ordering::SeqCst);
    let old = ok(phone.me(), "me on an old relay");
    assert_eq!(old, MlsMe { subject: SUBJECT.into(), policy_revision: None, devices: Vec::new() });
    let err = phone.post_candidate().expect("transport ok");
    assert_eq!(err, MlsCandidatePost::Refused { refusal: MlsRefusal { status: 404, code: String::new(), detail: String::new(), revision: None } },
               "a bare 404 is a refusal with an empty code (operator flow)");
    assert!(matches!(ok(phone.list_candidates(), "list on an old relay"), MlsCandidateList::Refused { refusal: MlsRefusal { status: 404, .. } }));
}

#[test]
fn a_candidate_is_posted_listed_fingerprint_checked_and_approved_into_the_chain() {
    let h = Harness::new();
    let (phone, _) = h.lobby("owner-phone");
    let (droid, _) = h.lobby("owner-android");
    // 첫 기기가 없으면 자기 승인은 불가(E1 은 운영자 의식).
    assert!(matches!(ok(droid.post_candidate(), "post without a first device"),
                     MlsCandidatePost::Refused { refusal: MlsRefusal { status: 403, ref code, .. } } if code == "first_device_out_of_band"));
    h.relay.enroll("owner-phone", &fingerprint_of(&phone), &["registrar"]);

    // 새 기기가 후보를 올린다: 본문은 `{device_id, actor, signing_key, fingerprint}` — subject 없음(대역의 strict 검사).
    let posted = ok(droid.post_candidate(), "post candidate");
    let MlsCandidatePost::Posted { fingerprint, policy_revision, expires_at } = posted else { panic!("{posted:?}") };
    assert_eq!((fingerprint.as_str(), policy_revision, expires_at), (fingerprint_of(&droid).as_str(), 2, CANDIDATE_TTL_SECONDS));
    assert!(h.trace().iter().any(|l| l == "CANDIDATE owner-android"), "{:?}", h.trace());
    // 같은 ID 재게시는 갱신(행 하나).
    ok(droid.post_candidate(), "re-post");
    assert_eq!(h.relay.candidates().len(), 1);

    // 체인에 없는 기기는 우편함을 볼 수 없다; 활성 기기는 본다.
    assert!(matches!(ok(droid.list_candidates(), "list as a candidate"), MlsCandidateList::Refused { refusal: MlsRefusal { status: 403, .. } }));
    let listed = ok(phone.list_candidates(), "list");
    let MlsCandidateList::Listed { policy_revision, candidates } = listed else { panic!("{listed:?}") };
    assert_eq!((policy_revision, candidates.len()), (2, 1));
    let c = candidates[0].clone();
    assert_eq!((c.device_id.as_str(), c.actor.as_str(), c.subject.as_str(), c.fingerprint.as_str()), ("owner-android", "owner", SUBJECT, fingerprint_of(&droid).as_str()));
    assert_eq!(c.signing_key.len(), 64);

    // 지문이 공개키와 맞지 않으면 서명하지 않는다(화면이 보여 준 지문 ≠ 키).
    let tampered = MlsCandidate { fingerprint: "00".repeat(32), ..c.clone() };
    let err = phone.approve(tampered, policy_revision).expect_err("fingerprint mismatch");
    assert!(matches!(err, RoomError::Mls { .. }) && err.to_string().contains("fingerprint mismatch"), "{err}");
    assert!(!h.trace().iter().any(|l| l.starts_with("APPROVE ")), "nothing was posted");

    // 낡은 revision 은 409 — 현재 revision 이 실려 온다; 그걸로 다시 서명하면 201.
    let stale = ok(phone.approve(c.clone(), policy_revision - 1), "stale approve");
    let MlsPolicyCommit::Refused { refusal } = stale else { panic!("{stale:?}") };
    assert_eq!((refusal.status, refusal.code.as_str(), refusal.revision), (409, "stale_revision", Some(2)));
    let committed = ok(phone.approve(c.clone(), refusal.revision.unwrap() as u64), "approve");
    assert_eq!(committed, MlsPolicyCommit::Committed { device_id: "owner-android".into(), approved_by: "owner-phone".into(), revision: 3, roles: Vec::new() });
    let record = h.relay.chain_device("owner-android").expect("enrolled");
    assert_eq!((record.status.as_str(), record.fingerprint.as_str(), record.roles.len()), ("active", fingerprint_of(&droid).as_str(), 0));
    assert!(h.relay.candidates().is_empty(), "the candidate row is dropped");
    let me = ok(droid.me(), "me as the new device");
    assert!(me.devices.iter().any(|d| d.device_id == "owner-android" && d.status == "active"));

    // ID 는 다시 쓸 수 없다.
    assert!(matches!(ok(droid.post_candidate(), "post again"), MlsCandidatePost::Refused { refusal: MlsRefusal { status: 409, ref code, .. } } if code == "device_exists"));

    // registrar 가 있는 actor 에서 registrar 가 아닌 기기의 승인은 403 `approval_rejected` + detail.
    let (tablet, _) = h.lobby("owner-tablet");
    ok(tablet.post_candidate(), "tablet candidate");
    let MlsCandidateList::Listed { policy_revision, candidates } = ok(phone.list_candidates(), "list") else { panic!() };
    let refused = ok(droid.approve(candidates[0].clone(), policy_revision), "approve by a non-registrar");
    let MlsPolicyCommit::Refused { refusal } = refused else { panic!("{refused:?}") };
    assert_eq!((refusal.status, refusal.code.as_str()), (403, "approval_rejected"));
    assert!(refusal.detail.contains("not a registrar"), "{}", refusal.detail);

    // 후보는 10분 뒤 사라진다.
    h.relay.advance_clock(CANDIDATE_TTL_SECONDS + 1);
    let MlsCandidateList::Listed { candidates, .. } = ok(phone.list_candidates(), "list after the TTL") else { panic!() };
    assert!(candidates.is_empty());
}

#[test]
fn set_roles_grants_and_releases_registrar_under_the_server_rules() {
    let h = Harness::new();
    let (phone, _) = h.lobby("owner-phone");
    let (pc, _) = h.lobby("owner-pc");
    h.relay.enroll("owner-phone", &fingerprint_of(&phone), &["registrar"]);
    h.relay.enroll("owner-pc", &fingerprint_of(&pc), &[]);
    let rev = h.relay.policy_revision();

    // registrar 가 아닌 기기는 역할을 바꿀 수 없다.
    let refused = ok(pc.set_roles("owner-pc".into(), "owner".into(), vec!["registrar".into()], rev), "grant by a non-registrar");
    assert!(matches!(refused, MlsPolicyCommit::Refused { refusal: MlsRefusal { status: 403, ref code, .. } } if code == "approval_rejected"), "{refused:?}");

    // 부여: roles 는 완전한 정렬 목록(중복은 접힌다).
    let granted = ok(phone.set_roles("owner-pc".into(), "owner".into(), vec!["registrar".into(), "registrar".into()], rev), "grant");
    assert_eq!(granted, MlsPolicyCommit::Committed { device_id: "owner-pc".into(), approved_by: "owner-phone".into(), revision: rev + 1, roles: vec!["registrar".into()] });
    assert!(h.trace().iter().any(|l| l == "ROLES owner-pc [\"registrar\"] by owner-phone"), "{:?}", h.trace());

    // 낡은 revision → 409 + 현재 revision.
    let stale = ok(phone.set_roles("owner-phone".into(), "owner".into(), Vec::new(), rev), "stale release");
    assert!(matches!(stale, MlsPolicyCommit::Refused { refusal: MlsRefusal { status: 409, revision: Some(r), .. } } if r as u64 == rev + 1), "{stale:?}");

    // 다른 registrar 가 남으면 스스로 사퇴할 수 있다(승인자 = 대상).
    let released = ok(phone.set_roles("owner-phone".into(), "owner".into(), Vec::new(), rev + 1), "release self");
    assert!(matches!(released, MlsPolicyCommit::Committed { revision, ref roles, .. } if revision == rev + 2 && roles.is_empty()), "{released:?}");
    // 이제 phone 은 registrar 가 아니고 pc 가 있으므로 phone 의 서명은 거절된다.
    let refused = ok(phone.set_roles("owner-phone".into(), "owner".into(), vec!["registrar".into()], rev + 2), "re-grant by the released device");
    assert!(matches!(refused, MlsPolicyCommit::Refused { refusal: MlsRefusal { status: 403, .. } }), "{refused:?}");
    // 마지막 registrar 는 해제할 수 없다.
    let last = ok(pc.set_roles("owner-pc".into(), "owner".into(), Vec::new(), rev + 2), "release the last registrar");
    let MlsPolicyCommit::Refused { refusal } = last else { panic!("{last:?}") };
    assert_eq!((refusal.status, refusal.code.as_str()), (403, "approval_rejected"));
    assert!(refusal.detail.contains("last registrar"), "{}", refusal.detail);
    assert_eq!(h.relay.chain_device("owner-pc").unwrap().roles, vec!["registrar"]);
}

/// 로비 객체의 `dispatch` 는 정책 메서드 셋만 받고, 같은 시드를 import 한 `MlsDevice::dispatch` 와 바이트가 같다(`policy_wire` 하나).
#[test]
fn lobby_dispatch_is_the_policy_wire_of_the_seed_and_nothing_else() {
    use family_mls_ios_ffi::{MlsDevice, MlsError};
    let h = Harness::new();
    let (phone, _) = h.lobby("owner-phone");
    let (droid, _) = h.lobby("owner-android");
    let device = ok(MlsDevice::import_state("owner-phone".into(), ok(phone.seed_state(), "seed")), "import the seed");
    let key_hex: String = ok(droid.public_key(), "pk").iter().map(|b| format!("{b:02x}")).collect();
    let fp = ok(phone.dispatch("policy_fingerprint".into(), key_hex.clone().into_bytes()), "lobby policy_fingerprint");
    assert_eq!(fp, ok(device.dispatch("policy_fingerprint".into(), key_hex.clone().into_bytes()), "device policy_fingerprint"));
    assert_eq!(String::from_utf8(fp).unwrap(), fingerprint_of(&droid));
    let args = format!("{{\"action\":\"approve-device\",\"device_id\":\"owner-android\",\"actor\":\"owner\",\"subject\":\"{SUBJECT}\",\"signing_key\":\"{key_hex}\",\"acceptance\":\"trusted-device-fingerprint\",\"base_revision\":2}}");
    let framed = ok(phone.dispatch("sign_approval".into(), args.clone().into_bytes()), "lobby sign_approval");
    assert_eq!(framed, ok(device.dispatch("sign_approval".into(), args.into_bytes()), "device sign_approval"), "Ed25519 is deterministic: same seed → same evidence");
    let roles = b"{\"device_id\":\"owner-android\",\"actor\":\"owner\",\"roles\":[\"registrar\"],\"base_revision\":2}".to_vec();
    assert_eq!(ok(phone.dispatch("sign_roles".into(), roles.clone()), "lobby sign_roles"), ok(device.dispatch("sign_roles".into(), roles), "device sign_roles"));
    for method in ["key_package", "create", "members", "delete_key_package", "nonsense"] {
        let err = phone.dispatch(method.into(), Vec::new()).expect_err("not a lobby method");
        assert!(matches!(err, MlsError::Invalid { .. }), "{method}: {err}");
    }
    let err = phone.dispatch("sign_approval".into(), b"not json".to_vec()).expect_err("rejected by the facade");
    assert!(matches!(err, MlsError::Rejected { .. }), "{err}");
    assert_eq!(ok(phone.replenish(1), "the lobby is still usable").minted, 1);
}

// ---- #755 1단계: 기기 단위 대기 `GET /v2/watch` ----

#[test]
fn watch_reports_changed_rooms_and_refusals_and_tolerates_an_old_relay() {
    use family_mls_ios_ffi::{MlsWatchRefusal, MlsWatchResult, MlsWatchRoom};
    let h = Harness::new();
    let (_owner, (peer, _)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    let (lobby, _) = h.lobby("owner-phone");
    let cursor = h.relay.rows("room-a").iter().map(|r| r.seq).max().unwrap_or(0);
    let at = |room: &str, after: i64| MlsWatchRoom { room: room.into(), after };
    let quiet = ok(lobby.watch(vec![at("room-a", cursor), at("ghost", 0)], 12_000), "watch quiet");
    assert_eq!(quiet, MlsWatchResult {
        supported: true, changed: Vec::new(), refused: vec![MlsWatchRefusal { room: "ghost".into(), code: "no_such_room".into() }],
    });
    ok(peer.send(b"hello".to_vec()), "send");
    let busy = ok(lobby.watch(vec![at("room-a", cursor)], 12_000), "watch after a send");
    assert_eq!((busy.supported, busy.changed.as_slice()), (true, &["room-a".to_string()][..]));
    assert!(h.trace().iter().any(|t| t == "WATCH owner-phone wait=12000 rooms=1"), "{:?}", h.trace());
    // 「wait」 상한은 코어가 25 s 로 자른다(릴레이 maxEventsWait).
    ok(lobby.watch(vec![at("room-a", cursor)], 90_000), "clamped");
    assert!(h.trace().iter().any(|t| t == "WATCH owner-phone wait=25000 rooms=1"));
    // #424 이전 릴레이: 봉투 없는 404 → 미지원(호스트는 고정 주기 폴링 유지), 오류 아님.
    h.relay.no_watch.store(true, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(ok(lobby.watch(vec![at("room-a", cursor)], 12_000), "old relay"),
               MlsWatchResult { supported: false, changed: Vec::new(), refused: Vec::new() });
    // 잘못된 입력은 전송 전에 거부.
    assert!(lobby.watch(Vec::new(), 12_000).is_err());
    assert!(lobby.watch(vec![at("bad room", 0)], 12_000).is_err());
}
