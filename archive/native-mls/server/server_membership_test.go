// M3b relay membership enforcement tests (#177 §3.3). Every test drives the
// real routes() mux over httptest with a throwaway SQLite file and a freshly
// initialized v4 device-policy chain. Pinned here: unknown and revoked
// devices get 403 on every POST while GET stays open (the deny is POST-only
// — history stays readable, MLS epochs make it undecryptable), a corrupt
// policy chain fails closed with 500 and no write, the commit member-list
// contract (required, sender listed, no duplicates), bootstrap seeding of the
// founding membership, add/remove diffs gated on policy-active devices and
// the actor roster, removed-device cursor cleanup, K4 replay after a
// membership change, and pruning that no longer waits on revoked devices'
// cursors. A relay without a device store keeps the legacy contract, pinned
// first so the enforcement can never silently turn on.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

// newEnforcedRelay wires a relay to a freshly initialized device-policy
// chain. Returned map tracks each actor's first (approver) device.
func newEnforcedRelay(t *testing.T, pol policy) (*relay, *httptest.Server, *devicepolicy.DevicePolicyStore, string, map[string]string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	st, err := devicepolicy.OpenDevicePolicyStore(dir)
	if err != nil {
		t.Fatalf("open device policy: %v", err)
	}
	if _, err := st.Init(); err != nil {
		t.Fatalf("init device policy: %v", err)
	}
	first := map[string]string{}
	r, srv, _ := newTestRelayAt(t, pol, t.TempDir())
	r.devices = st
	return r, srv, st, dir, first
}

// enrollDevice appends one active device to the chain: E1 shape for the
// actor's first device, E2 shape (trusted + approved_by bound to the new
// revision) for later ones. The store verifies structure and transitions;
// cryptographic approval evidence stays a CLI-layer concern.
func enrollDevice(t *testing.T, st *devicepolicy.DevicePolicyStore, first map[string]string, id, actor string) {
	t.Helper()
	info, wire, err := st.Read()
	if err != nil {
		t.Fatalf("read policy chain: %v", err)
	}
	key := sha256.Sum256([]byte("native-mls-m3b synthetic key: " + id))
	sum := sha256.Sum256(key[:])
	dev := devicepolicy.DeviceV4{
		ID:          id,
		Actor:       actor,
		Subject:     "subject-" + actor,
		SigningKey:  hex.EncodeToString(key[:]),
		Fingerprint: hex.EncodeToString(sum[:]),
		Status:      devicepolicy.StatusActive,
		Revision:    1,
		Acceptance:  devicepolicy.AcceptanceOutOfBand,
	}
	if approver := first[actor]; approver != "" {
		dev.Acceptance = devicepolicy.AcceptanceTrusted
		dev.ApprovedBy = &devicepolicy.DeviceApproval{DeviceID: approver, Revision: info.Revision + 1}
	}
	wire.Devices = append(wire.Devices, dev)
	if _, err := st.Commit(info.Revision, wire); err != nil {
		t.Fatalf("enroll %s (%s): %v", id, actor, err)
	}
	if first[actor] == "" {
		first[actor] = id
	}
}

// revokeDevice tombstones an active device (E3 shape, no evidence).
func revokeDevice(t *testing.T, st *devicepolicy.DevicePolicyStore, id string) {
	t.Helper()
	info, wire, err := st.Read()
	if err != nil {
		t.Fatalf("read policy chain: %v", err)
	}
	found := false
	for i := range wire.Devices {
		if wire.Devices[i].ID == id {
			d := wire.Devices[i]
			d.Status = devicepolicy.StatusRevoked
			d.Revision = 2
			wire.Devices[i] = d
			found = true
		}
	}
	if !found {
		t.Fatalf("revoke %s: not in policy", id)
	}
	if _, err := st.Commit(info.Revision, wire); err != nil {
		t.Fatalf("revoke %s: %v", id, err)
	}
}

// postCommitBody marshals one POST /events commit body with the replicated
// post-commit member list.
func postCommitBody(t *testing.T, device, clientID string, epoch int64, revision *int64, list []memberWire, payload []byte) []byte {
	t.Helper()
	body := struct {
		Device   string       `json:"device"`
		ClientID string       `json:"client_id"`
		Kind     string       `json:"kind"`
		Epoch    int64        `json:"epoch"`
		Revision *int64       `json:"revision,omitempty"`
		Members  []memberWire `json:"members,omitempty"`
		Bytes    []byte       `json:"bytes"`
	}{
		Device:   device,
		ClientID: clientID,
		Kind:     "commit",
		Epoch:    epoch,
		Revision: revision,
		Members:  list,
		Bytes:    payload,
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal commit body: %v", err)
	}
	return raw
}

func membersOf(pairs ...[2]string) []memberWire {
	out := make([]memberWire, 0, len(pairs))
	for _, p := range pairs {
		out = append(out, memberWire{Device: p[0], Actor: p[1]})
	}
	return out
}

// tableCount returns the row count of one scalar query, for membership and
// cursor assertions straight against the store.
func tableCount(t *testing.T, r *relay, query string, args ...any) int {
	t.Helper()
	var n int
	if err := r.db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func TestRelayWithoutDeviceStoreKeepsLegacyContract(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	if r.devices != nil {
		t.Fatal("relay without -device-state must have a nil device store")
	}
	// A commit without a member list from a never-enrolled device stays
	// accepted: enforcement is opt-in via -device-state.
	st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "commit", 0, nil, nil, []byte("legacy-commit")))
	if st != http.StatusCreated {
		t.Fatalf("legacy commit: status=%d body=%s", st, raw)
	}
	st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "c2", "application", 1, nil, nil, []byte("legacy-app")))
	if st != http.StatusCreated {
		t.Fatalf("legacy app: status=%d body=%s", st, raw)
	}
	// Key packages too — a nil device store must never 403 a poster (this
	// exact gap broke the v2 relay smoke once; it stays pinned).
	kp, err := json.Marshal(keyPackagePost{Device: "b1", Packages: []keyPackageInput{{Ref: "k1", Bytes: []byte("pkg")}}})
	if err != nil {
		t.Fatalf("marshal keypackages: %v", err)
	}
	if st, raw = doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", kp); st != http.StatusCreated {
		t.Fatalf("legacy keypackages: status=%d body=%s", st, raw)
	}
}

func TestUnknownAndRevokedDevicesGet403(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")

	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); st != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", st, raw)
	}
	// a2 is policy-active and a member: app accepted.
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "c2", "application", 1, nil, nil, []byte("from-a2"))); st != http.StatusCreated {
		t.Fatalf("a2 app: status=%d body=%s", st, raw)
	}
	// Unknown device: 403 on events and key packages alike. The ghost's own
	// commit lists itself (structurally valid) so the 403 comes from the
	// policy gate, not the sender-listed check.
	for _, body := range [][]byte{
		postEventBody(t, "ghost", "g1", "application", 1, nil, nil, []byte("nope")),
		postCommitBody(t, "ghost", "g2", 1, nil, membersOf([2]string{"ghost", "bob"}, [2]string{"a1", "alice"}), []byte("nope-commit")),
	} {
		code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", body)
		if code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
			t.Fatalf("ghost post: status=%d body=%s", code, raw)
		}
	}
	kp, _ := json.Marshal(keyPackagePost{Device: "ghost", Packages: []keyPackageInput{{Ref: "r1", Bytes: []byte("pkg")}}})
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", kp); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("ghost keypackages: status=%d body=%s", code, raw)
	}
	// A denied device must not materialize room state.
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_rooms WHERE room = 'g'`); n != 0 {
		t.Fatalf("denied keypackage created room rows: %d", n)
	}

	// E3 revoke of a2: every POST becomes 403, GET stays open.
	revokeDevice(t, st, "a2")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "c3", "application", 1, nil, nil, []byte("revoked-post"))); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("revoked a2 app: status=%d body=%s", code, raw)
	}
	kpA2, _ := json.Marshal(keyPackagePost{Device: "a2", Packages: []keyPackageInput{{Ref: "r2", Bytes: []byte("pkg")}}})
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/keypackages", kpA2); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("revoked a2 keypackages: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a2", nil); code != http.StatusOK {
		t.Fatalf("revoked a2 GET must stay open (deny is POST-only): status=%d body=%s", code, raw)
	}
	// a1 untouched: still active, still posting.
	if st, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c4", "application", 1, nil, nil, []byte("still-here"))); st != http.StatusCreated {
		t.Fatalf("a1 app after revoke: status=%d body=%s", st, raw)
	}
}

func TestCorruptDevicePolicyFailsClosed(t *testing.T) {
	_, srv, st, dir, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}), []byte("bootstrap"))); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	genesis := filepath.Join(dir, "policy-000001.json")
	original, err := os.ReadFile(genesis)
	if err != nil {
		t.Fatalf("read genesis: %v", err)
	}
	// A tampered policy file must fail the whole relay closed: 500 on every
	// write, and nothing stored.
	if err := os.WriteFile(genesis, []byte(`{"revision":1,"tampered":true}`), 0600); err != nil {
		t.Fatalf("tamper genesis: %v", err)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c2", "application", 1, nil, nil, []byte("while-corrupt"))); code != http.StatusInternalServerError || errField(t, raw) != "device_policy_unavailable" {
		t.Fatalf("post while corrupt: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil); code != http.StatusOK {
		t.Fatalf("read while corrupt: status=%d body=%s", code, raw)
	}
	// Restoring the exact bytes reopens the relay.
	if err := os.WriteFile(genesis, original, 0600); err != nil {
		t.Fatalf("restore genesis: %v", err)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c2", "application", 1, nil, nil, []byte("while-corrupt"))); code != http.StatusCreated {
		t.Fatalf("post after restore: status=%d body=%s", code, raw)
	}
}

func TestCommitMembershipLifecycle(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")

	// Structural faults are 400 before any policy or store work.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a1", "c1", "commit", 0, nil, nil, []byte("no-members"))); code != http.StatusBadRequest || errField(t, raw) != "commit_members_required" {
		t.Fatalf("commit without members: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c2", 0, nil, membersOf([2]string{"b1", "bob"}), []byte("sender-missing"))); code != http.StatusBadRequest || errField(t, raw) != "commit_sender_not_listed" {
		t.Fatalf("commit without sender listed: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c3", 0, nil, []memberWire{{Device: "a1", Actor: "alice"}, {Device: "a1", Actor: "alice"}}, []byte("dup"))); code != http.StatusBadRequest || errField(t, raw) != "duplicate_member" {
		t.Fatalf("commit with duplicate member: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_events WHERE room = 'r'`); n != 0 {
		t.Fatalf("rejected commits wrote events: %d", n)
	}

	// Bootstrap seeds the founding membership from the replicated list.
	boot := postCommitBody(t, "a1", "c4", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r'`); n != 2 {
		t.Fatalf("bootstrap seeded %d members, want 2", n)
	}

	// b1 needs a cursor before its removal so the cleanup is observable.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "c5", "application", 1, nil, nil, []byte("from-b1"))); code != http.StatusCreated {
		t.Fatalf("b1 app: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1'`); n != 1 {
		t.Fatalf("b1 cursor missing before removal: %d", n)
	}

	// a2 is policy-active but not a tracked member: app passes, commit 403.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "c6", "application", 1, nil, nil, []byte("from-a2"))); code != http.StatusCreated {
		t.Fatalf("a2 app pre-membership: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a2", "c7", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("a2-commit"))); code != http.StatusForbidden || errField(t, raw) != "commit_sender_not_member" {
		t.Fatalf("a2 commit pre-membership: status=%d body=%s", code, raw)
	}

	// Add a2 (same actor, on the roster): allowed.
	addA2 := postCommitBody(t, "a1", "c8", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("add-a2"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", addA2); code != http.StatusCreated {
		t.Fatalf("add a2: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a2", "c9", 2, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("a2-now-member"))); code != http.StatusCreated {
		t.Fatalf("a2 commit post-membership: status=%d body=%s", code, raw)
	}

	// Adding a device of an actor off the roster is rejected even though the
	// device is policy-active; same for an unknown device. (Epoch is 3: c9
	// was itself a commit.)
	addC1 := postCommitBody(t, "a1", "d1", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}, [2]string{"c1", "carol"}), []byte("add-c1"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", addC1); code != http.StatusForbidden || errField(t, raw) != "commit_actor_not_in_roster" {
		t.Fatalf("add c1: status=%d body=%s", code, raw)
	}
	addGhost := postCommitBody(t, "a1", "d2", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}, [2]string{"ghost", "bob"}), []byte("add-ghost"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", addGhost); code != http.StatusForbidden || errField(t, raw) != "commit_member_not_active" {
		t.Fatalf("add ghost: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND device IN ('c1','ghost')`); n != 0 {
		t.Fatalf("rejected adds wrote membership: %d", n)
	}

	// Removing b1 drops its membership in the same transaction as the
	// commit; its reader cursor is not deleted but marked removed at the
	// removal commit's seq (H3a grace: it keeps gating pruning until b1
	// reads its removal or the grace elapses).
	removeB1 := postCommitBody(t, "a1", "d3", 3, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}), []byte("remove-b1"))
	code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", removeB1)
	if code != http.StatusCreated {
		t.Fatalf("remove b1: status=%d body=%s", code, raw)
	}
	removal := decodeEventResponse(t, raw)
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r' AND device = 'b1'`); n != 0 {
		t.Fatalf("b1 membership survived removal: %d", n)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'b1' AND removed_at IS NOT NULL AND removed_seq = ?`, removal.Seq); n != 1 {
		t.Fatalf("b1 cursor not marked removed at seq %d: %d rows", removal.Seq, n)
	}

	// b1 is still policy-active, so application posts stay possible — the
	// membership gate is commit-only — but its commit is now 403. (Epoch is
	// 4 after the removal commit.)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "b1", "d4", "application", 4, nil, nil, []byte("b1-app-after-removal"))); code != http.StatusCreated {
		t.Fatalf("b1 app after removal: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "b1", "d5", 4, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("b1-commit-after-removal"))); code != http.StatusForbidden || errField(t, raw) != "commit_sender_not_member" {
		t.Fatalf("b1 commit after removal: status=%d body=%s", code, raw)
	}

	// K4: the byte-equal retry of the removal commit replays as 200 duplicate
	// even though the chain moved (epoch is now 3).
	code, raw = doJSON(t, srv, "POST", "/v2/rooms/r/events", removeB1)
	if code != http.StatusOK {
		t.Fatalf("K4 replay of removal commit: status=%d body=%s", code, raw)
	}
	var resp eventResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("decode replay: %v", err)
	}
	if !resp.Duplicate {
		t.Fatalf("K4 replay not marked duplicate: %+v", resp)
	}
	// L1: the replayed commit answers the epoch it produced, as its 201 did.
	if resp.Epoch != removal.Epoch || resp.Seq != removal.Seq {
		t.Fatalf("K4 replay of commit = epoch %d seq %d, want the 201's epoch %d seq %d", resp.Epoch, resp.Seq, removal.Epoch, removal.Seq)
	}
}

func TestBootstrapRejectsInactiveMember(t *testing.T) {
	r, srv, st, _, first := newEnforcedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"ghost", "bob"}), []byte("bad-bootstrap"))); code != http.StatusForbidden || errField(t, raw) != "commit_member_not_active" {
		t.Fatalf("bootstrap with inactive member: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_members WHERE room = 'r'`); n != 0 {
		t.Fatalf("failed bootstrap seeded membership: %d", n)
	}
	// The room is still bootstrapable with a clean list.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c2", 0, nil, membersOf([2]string{"a1", "alice"}), []byte("bootstrap"))); code != http.StatusCreated {
		t.Fatalf("clean bootstrap after rejection: status=%d body=%s", code, raw)
	}
}

func TestPruneSkipsRevokedDeviceCursor(t *testing.T) {
	pol := testPolicy()
	pol.AppEventTTLSeconds = -1 // application events stale immediately
	r, srv, st, _, first := newEnforcedRelay(t, pol)
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")

	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	// a2 posts and never reads; its cursor would pin both events forever.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postEventBody(t, "a2", "c2", "application", 1, nil, nil, []byte("a2-never-reads"))); code != http.StatusCreated {
		t.Fatalf("a2 app: status=%d body=%s", code, raw)
	}
	for _, d := range []string{"a1", "b1"} {
		if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device="+d, nil); code != http.StatusOK {
			t.Fatalf("%s get: status=%d body=%s", d, code, raw)
		}
	}
	// Sanity: with a2 active, its unread cursor gates pruning of its app
	// event. GET shows the bootstrap commit (never TTL-pruned) plus the app.
	var before eventsResponse
	if err := json.Unmarshal(rawRead(t, srv, "a1"), &before); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(before.Events) != 2 {
		t.Fatalf("expected commit + a2's gated app event, got %d", len(before.Events))
	}

	revokeDevice(t, st, "a2")
	// Any commit triggers the prune; a2's stale cursor must be dropped first.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c3", 1, nil, membersOf([2]string{"a1", "alice"}, [2]string{"a2", "alice"}, [2]string{"b1", "bob"}), []byte("trigger-prune"))); code != http.StatusCreated {
		t.Fatalf("prune trigger commit: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_cursors WHERE room = 'r' AND device = 'a2'`); n != 0 {
		t.Fatalf("revoked a2 cursor survived: %d", n)
	}
	var after eventsResponse
	if err := json.Unmarshal(rawRead(t, srv, "a1"), &after); err != nil {
		t.Fatalf("decode after: %v", err)
	}
	// Only commits remain — a2's unread application event went, the
	// trigger-prune commit itself stays (commit retention is epoch-based).
	var kinds []string
	for _, e := range after.Events {
		kinds = append(kinds, e.Kind)
	}
	if len(after.Events) != 2 || kinds[0] != "commit" || kinds[1] != "commit" {
		t.Fatalf("prune skipped revoked a2's cursor, events left: %+v", after.Events)
	}
}

func rawRead(t *testing.T, srv *httptest.Server, device string) []byte {
	t.Helper()
	_, raw := doJSON(t, srv, "GET", "/v2/rooms/r/events?device="+device, nil)
	return raw
}
