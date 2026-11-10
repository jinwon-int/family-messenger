// #616 durable room exclusions. A device removed from a room by commit is
// recorded in mls_room_exclusions and listed in GET /v2/lobby/status
// excluded_rooms, so a sibling device's periodic "rooms my other device is
// missing" rescan never re-invites a device someone deliberately removed.
// Pinned here: the field is always a list (never null, so clients can tell
// a new relay from an old one), the record survives the removed-cursor
// prune, a later add lifts it, closed rooms drop out, and -reset-room
// deletes it with the rest of the room.
package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

func excludedOf(t *testing.T, raw []byte) []string {
	t.Helper()
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatalf("lobby status not JSON: %v (%s)", err, raw)
	}
	field, ok := probe["excluded_rooms"]
	if !ok || string(field) == "null" {
		t.Fatalf("excluded_rooms missing or null: %s", raw)
	}
	return decodeLobbyStatus(t, raw).ExcludedRooms
}

func TestRoomExclusionLifecycle(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")

	status := func(device string) []string {
		t.Helper()
		code, raw := doJSON(t, srv, "GET", "/v2/lobby/status?device="+device, nil)
		if code != http.StatusOK {
			t.Fatalf("lobby status %s: status=%d body=%s", device, code, raw)
		}
		return excludedOf(t, raw)
	}
	post := func(room string, body []byte) eventResponse {
		t.Helper()
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/"+room+"/events", body)
		if code != http.StatusCreated {
			t.Fatalf("post %s: status=%d body=%s", room, code, raw)
		}
		return decodeEventResponse(t, raw)
	}

	// Bootstrap r (a1, a2, b1) and q (a1, a2).
	post("r", postCommitBody(t, "a1", "r0", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("boot-r")))
	post("q", postCommitBody(t, "a1", "q0", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}), []byte("boot-q")))
	if got := status("a2"); len(got) != 0 {
		t.Fatalf("fresh member excluded from %v", got)
	}

	// a2 needs a cursor so the removed-cursor mark exists to be pruned.
	post("r", postEventBody(t, "a2", "r1", "application", 1, nil, nil, []byte("from-a2")))

	// a1 removes a2 from r: recorded with the removal seq and the committer.
	removal := post("r", postCommitBody(t, "a1", "r2", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("remove-a2")))
	if got := status("a2"); len(got) != 1 || got[0] != "r" {
		t.Fatalf("after removal excluded_rooms = %v, want [r]", got)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_room_exclusions WHERE room = 'r' AND device = 'a2' AND removed_seq = ? AND by_device = 'a1'`, removal.Seq); n != 1 {
		t.Fatalf("exclusion row for a2 at seq %d by a1: %d rows", removal.Seq, n)
	}
	if got := status("b1"); len(got) != 0 {
		t.Fatalf("b1 (still a member) excluded from %v", got)
	}

	// The removed-cursor mark is pruned once the device reads its removal or
	// the grace elapses; the exclusion must outlive it.
	if _, err := r.db.Exec(`DELETE FROM mls_cursors WHERE room = 'r' AND device = 'a2'`); err != nil {
		t.Fatal(err)
	}
	if got := status("a2"); len(got) != 1 || got[0] != "r" {
		t.Fatalf("after cursor prune excluded_rooms = %v, want [r]", got)
	}

	// Adding a2 back lifts the exclusion.
	post("r", postCommitBody(t, "a1", "r3", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("add-a2")))
	if got := status("a2"); len(got) != 0 {
		t.Fatalf("after re-add excluded_rooms = %v, want []", got)
	}

	// Removed again, then the room closes: closed rooms are not listed.
	post("r", postCommitBody(t, "a1", "r4", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("remove-a2-again")))
	if got := status("a2"); len(got) != 1 {
		t.Fatalf("second removal excluded_rooms = %v, want [r]", got)
	}
	if _, err := r.db.Exec(`UPDATE mls_rooms SET closed_at = 1 WHERE room = 'r'`); err != nil {
		t.Fatal(err)
	}
	if got := status("a2"); len(got) != 0 {
		t.Fatalf("closed room still listed: %v", got)
	}
}

func TestResetRoomDeletesExclusions(t *testing.T) {
	policyDir := t.TempDir()
	if err := os.Chmod(policyDir, 0700); err != nil {
		t.Fatal(err)
	}
	st, err := devicepolicy.OpenDevicePolicyStore(policyDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Init(); err != nil {
		t.Fatal(err)
	}
	first := map[string]string{}
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")

	dir := t.TempDir()
	r, srv, _ := newTestRelayAt(t, testPolicy(), dir)
	r.devices = st
	for _, step := range []struct {
		id   string
		list []memberWire
	}{
		{"x0", membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"})},
		{"x1", membersOf([2]string{"a1", "alice"})},
	} {
		epoch := int64(0)
		if step.id == "x1" {
			epoch = 1
		}
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/gone/events", postCommitBody(t, "a1", step.id, epoch, nil, step.list, []byte(step.id))); code != http.StatusCreated {
			t.Fatalf("%s: status=%d body=%s", step.id, code, raw)
		}
	}
	srv.Close()
	if err := r.db.Close(); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if code := runResetRoom(&out, dir, "gone", false); code != 2 || !strings.Contains(out.String(), "exclusions=1") {
		t.Fatalf("dry run exit=%d out=%q, want 2 with exclusions=1", code, out.String())
	}
	out.Reset()
	if code := runResetRoom(&out, dir, "gone", true); code != 0 {
		t.Fatalf("reset exit=%d out=%q", code, out.String())
	}
	if c, err := resetRoom(dir, "gone", false); err != nil || c.total() != 0 {
		t.Fatalf("after reset counts=%+v err=%v, want zero", c, err)
	}
}
