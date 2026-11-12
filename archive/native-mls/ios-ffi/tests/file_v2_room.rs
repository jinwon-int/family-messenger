//! #366 C: `MlsRoom` 의 file-v2 열기·보내기 — 봉인 → 업로드 → `file-v2-<uuid>` 로 설명자 게시 → 다른 기기가 받아 분류 → 열기.
//! 핵심 불변식: 설명자(파일 키)는 **어떤 경로로도** `<identity>-n` client_id 로 나가지 않는다(409 재시도 포함) — 그렇게 나가면 받는 앱이
//! 글로 보여 준다. 릴레이 대역은 `tests/support/mod.rs`(blob 저장소는 blobs.go 흉내).
mod support;

use std::sync::atomic::Ordering;

use family_mls_ios_ffi::{file_v2_check, file_v2_classify, MlsFileV2Kind, RoomError, RoomEvent, SendResult};
use support::{founded_pair, ok, Harness};

const PNG: &[u8] = b"\x89PNG\r\n\x1a\n hande file-v2 room test";

#[test]
fn send_then_the_peer_classifies_and_opens_it() {
    let h = Harness::new();
    let ((owner, _), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");

    let out = ok(owner.send_file_v2(PNG.to_vec(), None, Some("사진.png".into())), "send file-v2");
    let SendResult::Sent { client_id, seq, .. } = &out.result else { panic!("expected Sent, got {:?}", out.result) };
    assert!(client_id.starts_with("file-v2-") && client_id.len() == "file-v2-".len() + 36, "{client_id}");
    assert_eq!((out.size, out.mime.as_str(), out.kind.as_str()), (PNG.len() as u64, "image/png", "image"));
    assert!(!format!("{out:?}").contains("key"), "Debug hides the descriptor");
    let info = ok(file_v2_check(out.descriptor.clone()), "own descriptor is valid");
    assert_eq!((info.blob.as_str(), info.name.as_deref()), (out.blob.as_str(), Some("사진.png")));

    // 순서: 업로드 → (영속 → 게시). 릴레이 행의 client_id 는 file-v2-<uuid>.
    let trace = h.trace();
    let upload = trace.iter().position(|l| l.starts_with("BLOB POST owner-phone room-a")).expect("upload");
    let post = trace.iter().position(|l| l.starts_with("POST application file-v2-")).expect("descriptor post");
    assert!(upload < post, "{trace:?}");
    let row = h.relay.rows("room-a").into_iter().find(|r| r.seq == *seq).expect("row");
    assert_eq!(&row.client_id, client_id);

    ok(peer.poll(), "peer receives");
    let apps = peer_obs.apps.lock().unwrap().clone();
    let (_, sender, cid, plaintext) = apps.last().cloned().expect("application");
    assert_eq!((sender.as_str(), cid.as_str()), ("owner-phone", client_id.as_str()));
    assert_eq!(plaintext, out.descriptor, "the MLS plaintext is the descriptor");
    assert_eq!(file_v2_classify(cid, plaintext.clone()), MlsFileV2Kind::FileV2 { size: PNG.len() as u64 });
    assert_eq!(ok(peer.open_file_v2(plaintext), "peer opens"), PNG);
}

#[test]
fn a_conflict_replays_the_descriptor_under_a_file_v2_client_id() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    h.relay.bump_epoch("room-a");

    let out = ok(owner.send_file_v2(PNG.to_vec(), Some("image/png".into()), None), "send into a moved room");
    let SendResult::Queued { client_id } = &out.result else { panic!("expected Queued, got {:?}", out.result) };
    assert!(client_id.starts_with("file-v2-"), "{client_id}");
    assert_eq!(owner_obs.events().last(), Some(&RoomEvent::Conflict { client_id: client_id.clone(), attempt: 1 }));
    assert!(h.relay.rows("room-a").iter().all(|r| r.kind != "application"), "nothing stored on 409");

    ok(owner.poll(), "poll refreshes the epoch and replays");
    let replayed = owner_obs.events().into_iter().find(|e| matches!(e, RoomEvent::Replayed { .. })).expect("replayed");
    let RoomEvent::Replayed { client_id: replay_id, .. } = replayed else { unreachable!() };
    assert!(replay_id.starts_with("file-v2-") && replay_id != *client_id, "fresh file-v2 id on replay: {replay_id}");
    let apps: Vec<_> = h.relay.rows("room-a").into_iter().filter(|r| r.kind == "application").collect();
    assert_eq!(apps.len(), 1);
    assert!(apps[0].client_id.starts_with("file-v2-"), "never <identity>-n: {}", apps[0].client_id);
    // A text send right after still uses the ordinary id (the flag never leaks).
    let text = ok(owner.send(b"after".to_vec()), "text send");
    let SendResult::Sent { client_id: text_id, .. } = text else { panic!("{text:?}") };
    assert!(text_id.starts_with("owner-phone-"), "{text_id}");

    ok(peer.poll(), "peer reads");
    let apps = peer_obs.apps.lock().unwrap().clone();
    let (_, _, cid, plaintext) = apps.iter().find(|a| a.2.starts_with("file-v2-")).cloned().expect("descriptor");
    assert!(matches!(file_v2_classify(cid, plaintext.clone()), MlsFileV2Kind::FileV2 { .. }));
    assert_eq!(ok(peer.open_file_v2(plaintext), "open"), PNG);
}

#[test]
fn open_refuses_tampered_bytes_missing_blobs_and_bad_descriptors() {
    let h = Harness::new();
    let ((owner, _), (peer, _)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    let out = ok(owner.send_file_v2(b"%PDF-1.7 doc".to_vec(), None, Some("r.pdf".into())), "send pdf");
    assert_eq!((out.mime.as_str(), out.kind.as_str()), ("application/pdf", "file"));

    h.relay.corrupt_next_blob.store(true, Ordering::SeqCst);
    let err = peer.open_file_v2(out.descriptor.clone()).expect_err("tampered");
    assert!(matches!(&err, RoomError::Host { reason } if reason == "file-v2 integrity"), "{err}");
    assert_eq!(ok(peer.open_file_v2(out.descriptor.clone()), "re-fetch"), b"%PDF-1.7 doc", "a retry fetches clean bytes");

    h.relay.blobs.lock().unwrap().clear();
    let err = peer.open_file_v2(out.descriptor.clone()).expect_err("gone");
    assert!(matches!(&err, RoomError::Relay { reason, transient: false } if reason.contains("no_such_blob")), "{err}");

    let err = peer.open_file_v2(b"{\"v\":2}".to_vec()).expect_err("bad descriptor");
    assert!(matches!(&err, RoomError::Host { reason } if reason == "file-v2 missing blob"), "{err}");
}

#[test]
fn send_refuses_before_uploading_when_it_cannot_post() {
    let h = Harness::new();
    let (lonely, _) = h.room("owner-tablet");
    let err = lonely.send_file_v2(PNG.to_vec(), None, None).expect_err("not joined");
    assert!(matches!(&err, RoomError::Host { reason } if reason.contains("not a member")), "{err}");
    assert!(h.relay.blobs.lock().unwrap().is_empty(), "nothing uploaded");

    let ((owner, _), _) = founded_pair(&h);
    let err = owner.send_file_v2(Vec::new(), None, None).expect_err("empty file");
    assert!(matches!(&err, RoomError::Host { reason } if reason == "file-v2 size"), "{err}");
    let err = owner.send_file_v2(PNG.to_vec(), None, Some("a\u{7}b".into())).expect_err("control char name");
    assert!(matches!(&err, RoomError::Host { reason } if reason == "file-v2 name"), "{err}");
    assert!(h.relay.blobs.lock().unwrap().is_empty(), "refused before upload");
}
