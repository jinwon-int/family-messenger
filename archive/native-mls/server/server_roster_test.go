package main

import (
	"encoding/json"
	"net/http"
	"testing"
)

// TestGetEventsCarriesTrackedRoster pins #261: every GET events page carries
// the relay's tracked (outer) membership as of the same transaction, so a
// client that staged the page's last commit can compare the MLS inner roster
// delta against what the relay enforced before merging. The list is empty
// until a bootstrap commit seeds the room and follows every add/remove.
func TestGetEventsCarriesTrackedRoster(t *testing.T) {
	_, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")

	get := func(query string) eventsResponse {
		t.Helper()
		code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?"+query, nil)
		if code != http.StatusOK {
			t.Fatalf("get %s: status=%d body=%s", query, code, raw)
		}
		return decodeEventsResponse(t, raw)
	}
	roster := func(r eventsResponse) string {
		out := ""
		for _, m := range r.Members {
			out += m.Device + ":" + m.Actor + " "
		}
		return out
	}

	// A key package founds the room without a membership: the roster is an
	// empty list (never null — JSON clients index it without a guard).
	kp, err := json.Marshal(keyPackagePost{Device: "a1", Packages: []keyPackageInput{{Ref: "ref-a1", Bytes: []byte("kp-a1")}}})
	if err != nil {
		t.Fatalf("marshal keypackages: %v", err)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", kp); code != http.StatusCreated {
		t.Fatalf("keypackage: status=%d body=%s", code, raw)
	}
	if page := get("device=a1"); page.Members == nil || len(page.Members) != 0 {
		t.Fatalf("unseeded room roster = %#v, want empty list", page.Members)
	}

	// Bootstrap seeds the roster from the replicated list.
	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	page := get("device=a1")
	if page.Epoch != 1 || roster(page) != "a1:alice b1:bob " {
		t.Fatalf("after bootstrap: epoch %d roster %q", page.Epoch, roster(page))
	}
	// The roster is the same for every reader, including a policy-active
	// device that is not (yet) a member: it is the outer truth, not a view.
	if other := get("device=a2"); roster(other) != roster(page) {
		t.Fatalf("roster differs by reader: %q vs %q", roster(other), roster(page))
	}

	// An add is visible in the page that carries the commit, in the same
	// transaction — a reader never sees the commit row with a stale roster.
	add := postCommitBody(t, "a1", "c2", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("add-a2"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", add); code != http.StatusCreated {
		t.Fatalf("add a2: status=%d body=%s", code, raw)
	}
	page = get("device=b1&after=1")
	if len(page.Events) != 1 || page.Events[0].Kind != "commit" || page.Epoch != 2 {
		t.Fatalf("add page = %+v epoch %d", page.Events, page.Epoch)
	}
	if roster(page) != "a1:alice b1:bob a2:alice " {
		t.Fatalf("after add: roster %q", roster(page))
	}

	// A removal drops the device from the roster the same way.
	remove := postCommitBody(t, "a1", "c3", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}), []byte("remove-b1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", remove); code != http.StatusCreated {
		t.Fatalf("remove b1: status=%d body=%s", code, raw)
	}
	if page = get("device=a1&after=2"); roster(page) != "a1:alice a2:alice " || page.Epoch != 3 {
		t.Fatalf("after remove: epoch %d roster %q", page.Epoch, roster(page))
	}
	// A page with no new rows still reports the current roster.
	if page = get("device=a1&after=3"); len(page.Events) != 0 || roster(page) != "a1:alice a2:alice " {
		t.Fatalf("empty page roster %q (%d rows)", roster(page), len(page.Events))
	}
}
