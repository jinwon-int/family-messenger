// #372 founding-actor admission tests. A post-founding commit may add a
// device of an actor not yet on the room roster only when the sender's
// policy actor was in the founding commit's member list; actors admitted
// later are roster actors, not founding actors, and keep the roster verdict
// (403 commit_actor_not_in_roster). The founding set is pinned in
// mls_rooms.founding_actors by the founding transaction and, for rooms
// founded before the column existed (NULL), derived from the earliest
// mls_members rows and backfilled.
package main

import (
	"database/sql"
	"net/http"
	"testing"
)

// foundingActorsColumn reads mls_rooms.founding_actors for room as stored.
func foundingActorsColumn(t *testing.T, r *relay, room string) sql.NullString {
	t.Helper()
	var v sql.NullString
	if err := r.db.QueryRow(`SELECT founding_actors FROM mls_rooms WHERE room = ?`, room).Scan(&v); err != nil {
		t.Fatalf("read founding_actors: %v", err)
	}
	return v
}

func TestFoundingActorAdmitsNewActor(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	enrollDevice(t, st, first, "c2", "carol")
	enrollDevice(t, st, first, "d1", "dave")
	enrollDevice(t, st, first, "e1", "erin")

	// Founding commit by alice seats alice and bob; the founding set is
	// written in the same transaction, sorted and de-duplicated.
	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"b1", "bob"}, [2]string{"a1", "alice"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if got := foundingActorsColumn(t, r, "r"); !got.Valid || got.String != `["alice","bob"]` {
		t.Fatalf("founding_actors after bootstrap = %+v, want [\"alice\",\"bob\"]", got)
	}

	// (1) A founding actor's device adds a device of a brand-new actor:
	// accepted, seated, founding set unchanged.
	addC1 := postCommitBody(t, "a1", "c2", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}), []byte("add-c1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", addC1); code != http.StatusCreated {
		t.Fatalf("founder adds new actor: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND device = 'c1' AND actor = 'carol'`); n != 1 {
		t.Fatalf("c1 not seated after founder add: %d", n)
	}
	if got := foundingActorsColumn(t, r, "r"); !got.Valid || got.String != `["alice","bob"]` {
		t.Fatalf("founding_actors changed by a later add = %+v", got)
	}

	// (2) carol is now a tracked member but not a founding actor: her device
	// cannot admit yet another new actor.
	c1AddsD1 := postCommitBody(t, "c1", "c3", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"d1", "dave"}), []byte("c1-add-d1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", c1AddsD1); code != http.StatusForbidden || errField(t, raw) != "commit_actor_not_in_roster" {
		t.Fatalf("non-founder adds new actor: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND device = 'd1'`); n != 0 {
		t.Fatalf("rejected add seated d1: %d", n)
	}

	// (3) Existing behaviour: any tracked member adds a device of a roster
	// actor, and a wrong posted actor is still commit_actor_mismatch (the
	// G-H3 check runs before the roster/founder verdict).
	c1AddsC2 := postCommitBody(t, "c1", "c4", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"c2", "carol"}), []byte("c1-add-c2"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", c1AddsC2); code != http.StatusCreated {
		t.Fatalf("non-founder adds roster actor device: status=%d body=%s", code, raw)
	}
	smuggle := postCommitBody(t, "a1", "c5", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"c2", "carol"}, [2]string{"d1", "alice"}), []byte("smuggle-d1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", smuggle); code != http.StatusForbidden || errField(t, raw) != "commit_actor_mismatch" {
		t.Fatalf("founder smuggles d1 as alice: status=%d body=%s", code, raw)
	}
	mislabelled := postCommitBody(t, "a1", "c6", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"c2", "carol"}, [2]string{"d1", "erin"}), []byte("mislabel-d1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", mislabelled); code != http.StatusForbidden || errField(t, raw) != "commit_actor_mismatch" {
		t.Fatalf("founder mislabels d1 as erin: status=%d body=%s", code, raw)
	}

	// The other founding actor (bob, not the room creator) may admit too.
	b1AddsD1 := postCommitBody(t, "b1", "c7", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"c2", "carol"}, [2]string{"d1", "dave"}), []byte("b1-add-d1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", b1AddsD1); code != http.StatusCreated {
		t.Fatalf("second founder adds new actor: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND actor = 'dave'`); n != 1 {
		t.Fatalf("dave not seated by bob: %d", n)
	}

	// A commit from a non-founder that adds two new actors at once is refused
	// as a whole (no partial seating).
	c2AddsE1 := postCommitBody(t, "c2", "c8", 4, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"c2", "carol"}, [2]string{"d1", "dave"}, [2]string{"e1", "erin"}), []byte("c2-add-e1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", c2AddsE1); code != http.StatusForbidden || errField(t, raw) != "commit_actor_not_in_roster" {
		t.Fatalf("later-admitted device adds new actor: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r'`); n != 5 {
		t.Fatalf("roster size = %d, want 5 (a1,b1,c1,c2,d1)", n)
	}
}

// TestFoundingActorsDerivedForLegacyRoom: a room founded before the column
// existed has NULL founding_actors. The set is derived from the members
// sharing the lowest added_seq, a founding actor can admit a new actor, and
// the derivation backfills the column.
func TestFoundingActorsDerivedForLegacyRoom(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	enrollDevice(t, st, first, "d1", "dave")

	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	// Founder admits carol normally, so a later-seated (higher added_seq)
	// member exists that the derivation must NOT count as founding.
	addC1 := postCommitBody(t, "a1", "c2", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}), []byte("add-c1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", addC1); code != http.StatusCreated {
		t.Fatalf("add c1: status=%d body=%s", code, raw)
	}
	// Simulate the pre-column room.
	if _, err := r.db.Exec(`UPDATE mls_rooms SET founding_actors = NULL WHERE room = 'r'`); err != nil {
		t.Fatal(err)
	}

	// carol (added_seq above the founding seq) is not derived as founding.
	c1AddsD1 := postCommitBody(t, "c1", "c3", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"d1", "dave"}), []byte("c1-add-d1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", c1AddsD1); code != http.StatusForbidden || errField(t, raw) != "commit_actor_not_in_roster" {
		t.Fatalf("legacy: non-founder adds new actor: status=%d body=%s", code, raw)
	}
	// bob (founding seq) is, and the derivation backfills the column.
	b1AddsD1 := postCommitBody(t, "b1", "c4", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}, [2]string{"d1", "dave"}), []byte("b1-add-d1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", b1AddsD1); code != http.StatusCreated {
		t.Fatalf("legacy: founder adds new actor: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND device = 'd1' AND actor = 'dave'`); n != 1 {
		t.Fatalf("legacy: d1 not seated: %d", n)
	}
	if got := foundingActorsColumn(t, r, "r"); !got.Valid || got.String != `["alice","bob"]` {
		t.Fatalf("legacy founding_actors backfill = %+v, want [\"alice\",\"bob\"]", got)
	}
}
